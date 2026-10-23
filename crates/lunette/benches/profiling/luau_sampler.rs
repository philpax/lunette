use std::{
    cell::{Cell, RefCell},
    collections::BTreeMap,
    ffi::{CStr, c_char, c_int},
    io,
    mem::MaybeUninit,
    panic::{AssertUnwindSafe, catch_unwind},
    ptr,
    rc::Rc,
    sync::{
        Arc,
        atomic::{AtomicBool, AtomicU64, Ordering},
    },
    thread::{self, JoinHandle},
    time::Duration,
};

use mlua::{Function, Lua, Result, ffi};
use serde::{Serialize, Serializer};
use serde_json::{Value, json};

/// Owns the benchmark's interrupt until `finish` or drop, on the installing thread.
///
/// The LÖVR owner must remain alive until this guard is dropped. A cloned `Lua`
/// handle keeps an mlua-owned VM alive, but cannot extend an externally owned VM.
/// No other code may replace the interrupt while this guard exists.
pub(crate) struct Sampler {
    lua: Lua,
    context: Rc<RefCell<Context>>,
    timer: Option<JoinHandle<io::Result<()>>>,
    closed: Rc<Cell<bool>>,
    installed: bool,
    frequency_hz: u32,
}

impl Sampler {
    /// Installs a sampler on a VM with no existing interrupt, initially outside a phase.
    pub(crate) fn install(lua: &Lua, frequency_hz: u32) -> Result<Self> {
        if frequency_hz == 0 || frequency_hz > 1_000_000_000 {
            return Err(error("frequency must be between 1 and 1000000000 Hz"));
        }
        let clock = CpuClock::for_current_thread().map_err(clock_error)?;
        let mut sampler = Self::install_hook(lua, frequency_hz, Rc::new(clock))?;
        let (period_ns, shared) = {
            let context = sampler
                .context
                .try_borrow()
                .map_err(|_| error("the sampler context is already borrowed"))?;
            (context.period_ns, Arc::clone(&context.shared))
        };
        sampler.timer = Some(
            thread::Builder::new()
                .name("luau-cpu-sampler".into())
                .spawn(move || run_timer(clock, period_ns, shared))
                .map_err(|cause| error(format!("timer thread: {cause}")))?,
        );
        Ok(sampler)
    }

    fn install_hook(lua: &Lua, frequency_hz: u32, clock: Rc<dyn Clock>) -> Result<Self> {
        if frequency_hz == 0 || frequency_hz > 1_000_000_000 {
            return Err(error("frequency must be between 1 and 1000000000 Hz"));
        }
        let period_ns = 1_000_000_000 / u64::from(frequency_hz);
        CONTEXT.with(|slot| {
            let slot = slot
                .try_borrow()
                .map_err(|_| error("the sampler context is already borrowed"))?;
            if slot.is_some() {
                return Err(error("only one sampler may run on the VM-owning thread"));
            }
            Ok(())
        })?;

        let now = clock.now().map_err(clock_error)?;
        let shared = Arc::new(TimerState::default());
        let context = Rc::new(RefCell::new(Context {
            callbacks: ptr::null_mut(),
            clock,
            shared: Arc::clone(&shared),
            period_ns,
            generation: 0,
            active: None,
            update: PhaseProfile::default(),
            draw: PhaseProfile::default(),
            last_cpu_ns: now,
            outside_cpu_ns: 0,
            sampler_cpu_ns: 0,
            failure: None,
        }));
        let mut sampler = Self {
            lua: lua.clone(),
            context,
            timer: None,
            closed: Rc::new(Cell::new(false)),
            installed: false,
            frequency_hz,
        };

        let mut install_result = Ok(());
        // SAFETY: exec_raw locks the live VM, protects the operation, and restores its stack.
        // Only the owning thread touches the callbacks, and userdata remains mlua's property.
        unsafe {
            lua.exec_raw::<()>((), |state| {
                let callbacks = ffi::lua_callbacks(state);
                if (*callbacks).interrupt.is_some() {
                    install_result = Err(error("the VM already has an interrupt callback"));
                    return;
                }
                install_result = CONTEXT.with(|slot| {
                    let mut slot = slot
                        .try_borrow_mut()
                        .map_err(|_| error("the sampler context is already borrowed"))?;
                    let mut context = sampler
                        .context
                        .try_borrow_mut()
                        .map_err(|_| error("the sampler context is already borrowed"))?;
                    context.callbacks = callbacks;
                    *slot = Some(Rc::clone(&sampler.context));
                    CALLBACK_FAILURES.with(|count| count.set(0));
                    (*callbacks).interrupt = Some(on_interrupt);
                    sampler.installed = true;
                    Ok(())
                });
            })?;
        }
        install_result?;
        Ok(sampler)
    }

    /// Creates a callback taking `(phase, enter)` for `update` and `draw` boundaries.
    ///
    /// Calls must be balanced and non-nested. A boundary after `finish` returns an error.
    pub(crate) fn boundary(&self, lua: &Lua) -> Result<Function> {
        let mut same_vm = false;
        // SAFETY: this only compares the callback table identity while exec_raw locks the VM.
        unsafe {
            lua.exec_raw::<()>((), |state| {
                if let Ok(context) = self.context.try_borrow() {
                    same_vm = context.callbacks == ffi::lua_callbacks(state);
                }
            })?;
        }
        if !same_vm {
            return Err(error("the phase callback belongs to a different VM"));
        }
        let weak = Rc::downgrade(&self.context);
        let closed = Rc::clone(&self.closed);
        lua.create_function(move |_, (phase, enter): (String, bool)| {
            if closed.get() {
                return Err(error("the sampler is stopped"));
            }
            let phase = Phase::parse(&phase)?;
            let context = weak
                .upgrade()
                .ok_or_else(|| error("the phase callback outlived its sampler"))?;
            let mut context = context
                .try_borrow_mut()
                .map_err(|_| error("the sampler context is already borrowed"))?;
            context.boundary(phase, enter).map_err(clock_error)
        })
    }

    /// Removes the interrupt, joins the timer, and returns the complete raw profile.
    pub(crate) fn finish(mut self) -> Result<Value> {
        self.shutdown()?;
        let mut context = self
            .context
            .try_borrow_mut()
            .map_err(|_| error("the sampler context is already borrowed"))?;
        if let Some(cause) = context.failure.take() {
            return Err(clock_error(cause));
        }
        let callback_failures = CALLBACK_FAILURES.with(Cell::get);
        if callback_failures != 0 {
            return Err(error(format!(
                "{callback_failures} interrupt callbacks could not safely collect a stack"
            )));
        }
        if context.active.is_some() {
            return Err(error("a phase has no matching exit boundary"));
        }
        let now = context.clock.now().map_err(clock_error)?;
        context.outside_cpu_ns = context
            .outside_cpu_ns
            .saturating_add(now.saturating_sub(context.last_cpu_ns));
        Ok(json!({
            "format_version": 1,
            "algorithm": "owning-thread-cpu-clock-luau-safepoint",
            "frequency_hz": self.frequency_hz,
            "period_ns": context.period_ns,
            "timer_poll_ns": context.period_ns.min(TIMER_POLL_NS),
            "maximum_stack_depth": MAX_STACK_DEPTH,
            "outside_phase_cpu_ns": context.outside_cpu_ns,
            "stack_capture_cpu_ns": context.sampler_cpu_ns,
            "timer_requests": context.shared.requests.load(Ordering::Acquire),
            "stale_timer_requests": context.shared.stale_requests.load(Ordering::Acquire),
            "uncollected_timer_requests": context.shared.requests.load(Ordering::Acquire)
                .saturating_sub(context.update.samples.saturating_add(context.draw.samples)),
            "phases": {
                "update": context.update.to_json(),
                "draw": context.draw.to_json(),
            },
            "limitations": [
                "This is CPU-budget sampling delivered at Luau safepoints, not an asynchronous on-CPU oracle.",
                "The timer polls the owning pthread CPU clock; scheduler delays can defer requests.",
                "Long C calls and native work without safepoints cannot be sampled in place; their CPU budget can reach a later safepoint or be counted as missed at phase exit.",
                "C frames and Luau native-execution flags describe only frames visible to lua_getinfo, not native machine stacks; use perf for the native complement.",
                "CPU outside update and draw is excluded, and blocked time does not advance the thread CPU clock.",
                "Each phase carries its fractional CPU budget across entries; missed intervals are not assigned to the next observed stack.",
                "Rust stack copying and aggregation allocate at safepoints; their measured CPU cost is excluded from the next sampling budget, but other profiler overhead remains.",
                "Stacks are root-first and truncated at 128 frames from the leaf; missing debug names and lines remain null or negative.",
                "Invalid UTF-8 debug text is retained as a bytes object; collapsed labels escape bytes and separators.",
            ],
        }))
    }

    fn shutdown(&mut self) -> Result<()> {
        if self.closed.get() && !self.installed && self.timer.is_none() {
            return Ok(());
        }
        self.closed.set(true);
        let shared = self
            .context
            .try_borrow()
            .map(|context| Arc::clone(&context.shared))
            .map_err(|_| error("the sampler context is already borrowed"))?;
        shared.stop.store(true, Ordering::Release);
        shared.epoch.store(0, Ordering::Release);
        shared.due.store(false, Ordering::Release);
        let mut restore_error = None;
        if self.installed {
            // SAFETY: the guard is !Send through Rc and the live owner outlives it. No timer
            // ever accesses the VM. The original interrupt is null because install rejects it.
            let restored = unsafe {
                self.lua.exec_raw::<()>((), |state| {
                    let callbacks = ffi::lua_callbacks(state);
                    match (*callbacks).interrupt {
                        Some(callback) if ptr::fn_addr_eq(callback, on_interrupt as Interrupt) => {
                            (*callbacks).interrupt = None;
                        }
                        _ => {
                            restore_error = Some(error("the VM interrupt changed during sampling"));
                        }
                    }
                })
            };
            match restored {
                Ok(()) => self.installed = false,
                Err(cause) => restore_error = Some(cause),
            }
        }
        if !self.installed {
            CONTEXT.with(|slot| {
                if let Ok(mut slot) = slot.try_borrow_mut() {
                    if slot
                        .as_ref()
                        .is_some_and(|context| Rc::ptr_eq(context, &self.context))
                    {
                        *slot = None;
                    }
                } else {
                    restore_error = Some(error("the sampler context is borrowed during shutdown"));
                }
            });
        }
        let timer_result = match self.timer.take() {
            Some(timer) => {
                timer.thread().unpark();
                timer
                    .join()
                    .map_err(|_| error("the timer thread panicked"))?
                    .map_err(clock_error)
            }
            None => Ok(()),
        };
        if let Some(cause) = restore_error {
            return Err(cause);
        }
        timer_result
    }
}

impl Drop for Sampler {
    fn drop(&mut self) {
        if let Err(cause) = self.shutdown() {
            tracing::error!(error = %cause, "Luau benchmark sampler cleanup");
        }
    }
}

const MAX_STACK_DEPTH: usize = 128;
const TIMER_POLL_NS: u64 = 1_000_000;
type Interrupt = unsafe extern "C-unwind" fn(*mut ffi::lua_State, c_int);

thread_local! {
    static CONTEXT: RefCell<Option<Rc<RefCell<Context>>>> = const { RefCell::new(None) };
    static CALLBACK_FAILURES: Cell<u64> = const { Cell::new(0) };
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Phase {
    Update,
    Draw,
}

impl Phase {
    fn parse(value: &str) -> Result<Self> {
        match value {
            "update" => Ok(Self::Update),
            "draw" => Ok(Self::Draw),
            _ => Err(error(format!("unknown phase {value:?}"))),
        }
    }
}

struct Context {
    callbacks: *mut ffi::lua_Callbacks,
    clock: Rc<dyn Clock>,
    shared: Arc<TimerState>,
    period_ns: u64,
    generation: u64,
    active: Option<ActivePhase>,
    update: PhaseProfile,
    draw: PhaseProfile,
    last_cpu_ns: u64,
    outside_cpu_ns: u64,
    sampler_cpu_ns: u64,
    failure: Option<io::Error>,
}

impl Context {
    fn boundary(&mut self, phase: Phase, enter: bool) -> io::Result<()> {
        match (self.active, enter) {
            (None, true) => {
                let generation = self
                    .generation
                    .checked_add(1)
                    .ok_or_else(|| io::Error::other("phase generation overflow"))?;
                let now = self.clock.now()?;
                self.outside_cpu_ns = self
                    .outside_cpu_ns
                    .saturating_add(now.saturating_sub(self.last_cpu_ns));
                self.shared.due.store(false, Ordering::Release);
                self.generation = generation;
                self.active = Some(ActivePhase {
                    phase,
                    epoch: generation,
                    start_cpu_ns: now,
                });
                self.publish_deadline(phase, now);
                self.shared.epoch.store(generation, Ordering::Release);
                Ok(())
            }
            (Some(active), false) if active.phase == phase => {
                self.shared.epoch.store(0, Ordering::Release);
                self.shared.due.store(false, Ordering::Release);
                let now = self.clock.now()?;
                let period_ns = self.period_ns;
                let profile = self.profile(phase);
                let missed =
                    profile.account_cpu(now.saturating_sub(active.start_cpu_ns), period_ns);
                profile.missed_samples = profile.missed_samples.saturating_add(missed);
                self.last_cpu_ns = now;
                self.active = None;
                Ok(())
            }
            _ => Err(io::Error::other(
                "phase boundaries are nested or unbalanced",
            )),
        }
    }

    fn profile(&mut self, phase: Phase) -> &mut PhaseProfile {
        match phase {
            Phase::Update => &mut self.update,
            Phase::Draw => &mut self.draw,
        }
    }

    fn publish_deadline(&self, phase: Phase, now: u64) {
        let profile = match phase {
            Phase::Update => &self.update,
            Phase::Draw => &self.draw,
        };
        self.shared.deadline_ns.store(
            now.saturating_add(self.period_ns - profile.remainder_ns),
            Ordering::Release,
        );
    }

    unsafe fn sample(&mut self, state: *mut ffi::lua_State, gc: c_int) -> io::Result<()> {
        let Some(active) = self.active else {
            return Ok(());
        };
        if !self.shared.due.swap(false, Ordering::AcqRel) {
            return Ok(());
        }
        if self.shared.request_epoch.load(Ordering::Acquire) != active.epoch {
            self.shared.stale_requests.fetch_add(1, Ordering::Relaxed);
            return Ok(());
        }
        let now = self.clock.now()?;
        // A timer can finish publishing an old request after the previous sample resets the budget.
        if now < self.shared.deadline_ns.load(Ordering::Acquire) {
            self.shared.stale_requests.fetch_add(1, Ordering::Relaxed);
            return Ok(());
        }
        let period_ns = self.period_ns;
        let profile = self.profile(active.phase);
        let intervals = profile.account_cpu(now.saturating_sub(active.start_cpu_ns), period_ns);
        // SAFETY: the interrupt runs on this live VM's owning thread. The debug options
        // only read existing metadata; no Lua allocation, push, call, or error occurs.
        let stack = unsafe { capture_stack(state) };
        profile.samples = profile.samples.saturating_add(1);
        profile.missed_samples = profile
            .missed_samples
            .saturating_add(intervals.saturating_sub(1));
        if gc >= 0 {
            profile.gc_samples = profile.gc_samples.saturating_add(1);
        }
        if stack.truncated {
            profile.truncated_samples = profile.truncated_samples.saturating_add(1);
        }
        if stack.frames.is_empty() {
            profile.empty_samples = profile.empty_samples.saturating_add(1);
        }
        let count = profile.stacks.entry(stack).or_default();
        *count = count.saturating_add(1);
        let after = self.clock.now()?;
        self.sampler_cpu_ns = self
            .sampler_cpu_ns
            .saturating_add(after.saturating_sub(now));
        self.active = Some(ActivePhase {
            start_cpu_ns: after,
            ..active
        });
        self.publish_deadline(active.phase, after);
        Ok(())
    }
}

#[derive(Clone, Copy)]
struct ActivePhase {
    phase: Phase,
    epoch: u64,
    start_cpu_ns: u64,
}

#[derive(Default)]
struct TimerState {
    stop: AtomicBool,
    epoch: AtomicU64,
    deadline_ns: AtomicU64,
    due: AtomicBool,
    request_epoch: AtomicU64,
    requests: AtomicU64,
    stale_requests: AtomicU64,
}

fn run_timer(clock: CpuClock, period_ns: u64, shared: Arc<TimerState>) -> io::Result<()> {
    let poll = Duration::from_nanos(period_ns.min(TIMER_POLL_NS));
    while !shared.stop.load(Ordering::Acquire) {
        let epoch = shared.epoch.load(Ordering::Acquire);
        if epoch != 0 {
            let now = clock.now()?;
            let deadline = shared.deadline_ns.load(Ordering::Acquire);
            if now >= deadline && shared.epoch.load(Ordering::Acquire) == epoch {
                shared.request_epoch.store(epoch, Ordering::Release);
                if !shared.due.swap(true, Ordering::AcqRel) {
                    shared.requests.fetch_add(1, Ordering::Relaxed);
                }
            }
        }
        thread::park_timeout(poll);
    }
    Ok(())
}

unsafe extern "C-unwind" fn on_interrupt(state: *mut ffi::lua_State, gc: c_int) {
    // No borrow failure or Rust panic may escape into Luau, including a reentrant GC callback.
    let outcome = catch_unwind(AssertUnwindSafe(|| {
        CONTEXT.try_with(|slot| -> std::result::Result<(), ()> {
            let slot = slot.try_borrow().map_err(|_| ())?;
            let Some(context) = slot.as_ref() else {
                return Ok(());
            };
            let mut context = context.try_borrow_mut().map_err(|_| ())?;
            // SAFETY: callback tables are shared by coroutines, but not by unrelated VMs.
            if context.callbacks != unsafe { ffi::lua_callbacks(state) } {
                return Ok(());
            }
            // SAFETY: Luau invokes this callback on the state-owning thread at a safepoint.
            if let Err(cause) = unsafe { context.sample(state, gc) } {
                context.failure = Some(cause);
                context.shared.stop.store(true, Ordering::Release);
                context.shared.epoch.store(0, Ordering::Release);
            }
            Ok(())
        })
    }));
    if !matches!(outcome, Ok(Ok(Ok(())))) {
        let _ = CALLBACK_FAILURES.try_with(|count| count.set(count.get().saturating_add(1)));
    }
}

trait Clock {
    fn now(&self) -> io::Result<u64>;
}

#[derive(Clone, Copy)]
struct CpuClock(libc::clockid_t);

impl CpuClock {
    fn for_current_thread() -> io::Result<Self> {
        let mut id = MaybeUninit::uninit();
        // SAFETY: pthread_self identifies this live caller; the output points to writable storage.
        let status = unsafe { libc::pthread_getcpuclockid(libc::pthread_self(), id.as_mut_ptr()) };
        if status != 0 {
            return Err(io::Error::from_raw_os_error(status));
        }
        // SAFETY: pthread_getcpuclockid initializes the output on success.
        Ok(Self(unsafe { id.assume_init() }))
    }
}

impl Clock for CpuClock {
    fn now(&self) -> io::Result<u64> {
        let mut time = MaybeUninit::uninit();
        // SAFETY: the installing pthread remains alive until the timer is joined.
        if unsafe { libc::clock_gettime(self.0, time.as_mut_ptr()) } != 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: clock_gettime initializes the output on success.
        let time = unsafe { time.assume_init() };
        let seconds = u64::try_from(time.tv_sec)
            .map_err(|_| io::Error::other("the CPU clock returned negative seconds"))?;
        let nanos = u64::try_from(time.tv_nsec)
            .map_err(|_| io::Error::other("the CPU clock returned negative nanoseconds"))?;
        seconds
            .checked_mul(1_000_000_000)
            .and_then(|seconds| seconds.checked_add(nanos))
            .ok_or_else(|| io::Error::other("the CPU clock overflowed nanoseconds"))
    }
}

#[derive(Default)]
struct PhaseProfile {
    cpu_ns: u64,
    remainder_ns: u64,
    budget_intervals: u64,
    samples: u64,
    missed_samples: u64,
    gc_samples: u64,
    truncated_samples: u64,
    empty_samples: u64,
    stacks: BTreeMap<Stack, u64>,
}

impl PhaseProfile {
    fn account_cpu(&mut self, elapsed_ns: u64, period_ns: u64) -> u64 {
        self.cpu_ns = self.cpu_ns.saturating_add(elapsed_ns);
        let elapsed = u128::from(self.remainder_ns) + u128::from(elapsed_ns);
        let intervals = (elapsed / u128::from(period_ns)).min(u128::from(u64::MAX)) as u64;
        self.remainder_ns = (elapsed % u128::from(period_ns)) as u64;
        self.budget_intervals = self.budget_intervals.saturating_add(intervals);
        intervals
    }

    fn to_json(&self) -> Value {
        let stacks: Vec<_> = self
            .stacks
            .iter()
            .map(|(stack, count)| {
                json!({
                    "frames": stack.frames,
                    "truncated": stack.truncated,
                    "count": count,
                    "collapsed": stack.collapsed(),
                })
            })
            .collect();
        let collapsed = self
            .stacks
            .iter()
            .map(|(stack, count)| format!("{} {count}\n", stack.collapsed()))
            .collect::<String>();
        json!({
            "cpu_ns": self.cpu_ns,
            "budget_intervals": self.budget_intervals,
            "samples": self.samples,
            "missed_samples": self.missed_samples,
            "gc_samples": self.gc_samples,
            "truncated_samples": self.truncated_samples,
            "empty_samples": self.empty_samples,
            "stacks": stacks,
            "collapsed": collapsed,
        })
    }
}

#[derive(PartialEq, Eq, PartialOrd, Ord)]
struct Stack {
    frames: Vec<Frame>,
    truncated: bool,
}

impl Stack {
    fn collapsed(&self) -> String {
        let mut labels: Vec<_> = self.frames.iter().map(Frame::label).collect();
        if self.truncated {
            labels.insert(0, "[truncated]".into());
        }
        if labels.is_empty() {
            labels.push("[empty]".into());
        }
        labels.join(";")
    }
}

#[derive(Serialize, PartialEq, Eq, PartialOrd, Ord)]
struct Frame {
    source: Option<DebugText>,
    name: Option<DebugText>,
    what: Option<DebugText>,
    line_defined: c_int,
    current_line: c_int,
    native: bool,
}

impl Frame {
    fn label(&self) -> String {
        let source = self
            .source
            .as_ref()
            .map(DebugText::label)
            .unwrap_or_else(|| "[unknown source]".into());
        let name = self
            .name
            .as_ref()
            .map(DebugText::label)
            .unwrap_or_else(|| "[anonymous]".into());
        let kind = match self.what.as_ref().map(|what| what.0.as_slice()) {
            Some(b"C") => "C",
            _ if self.native => "native",
            _ => "Luau",
        };
        format!(
            "{source}:{}:{name} [defined:{} {kind}]",
            self.current_line, self.line_defined
        )
    }
}

unsafe fn capture_stack(state: *mut ffi::lua_State) -> Stack {
    let mut frames = Vec::with_capacity(MAX_STACK_DEPTH);
    for level in 0..MAX_STACK_DEPTH {
        // SAFETY: null pointers and zero scalars are valid lua_Debug field values.
        let mut debug: ffi::lua_Debug = unsafe { MaybeUninit::zeroed().assume_init() };
        // SAFETY: the VM is stopped at this owning-thread safepoint. Unlike `f`, `sln`
        // neither pushes a function nor allocates a Lua value in this Luau implementation.
        if unsafe { ffi::lua_getinfo(state, level as c_int, c"sln".as_ptr(), &mut debug) } == 0 {
            break;
        }
        // SAFETY: lua_getinfo returns existing, NUL-terminated debug strings. Copy them
        // while the VM is stopped, before their storage can be collected or replaced.
        frames.push(unsafe {
            Frame {
                source: DebugText::copy(debug.source),
                name: DebugText::copy(debug.name),
                what: DebugText::copy(debug.what),
                line_defined: debug.linedefined,
                current_line: debug.currentline,
                native: ffi::lua_incustomexecution(state, level as c_int) != 0,
            }
        });
    }
    // SAFETY: stackdepth only reads the current VM's call-info array.
    let truncated = unsafe { ffi::lua_stackdepth(state) } > MAX_STACK_DEPTH as c_int;
    frames.reverse();
    Stack { frames, truncated }
}

#[derive(PartialEq, Eq, PartialOrd, Ord)]
struct DebugText(Vec<u8>);

impl DebugText {
    unsafe fn copy(value: *const c_char) -> Option<Self> {
        if value.is_null() {
            return None;
        }
        // SAFETY: the caller guarantees this is a live, NUL-terminated debug string.
        Some(Self(unsafe { CStr::from_ptr(value) }.to_bytes().to_vec()))
    }

    fn label(&self) -> String {
        self.0
            .iter()
            .flat_map(|byte| match byte {
                b';' => b"\\x3b".to_vec(),
                _ => std::ascii::escape_default(*byte).collect(),
            })
            .map(char::from)
            .collect()
    }
}

impl Serialize for DebugText {
    fn serialize<S: Serializer>(&self, serializer: S) -> std::result::Result<S::Ok, S::Error> {
        match std::str::from_utf8(&self.0) {
            Ok(text) => serializer.serialize_str(text),
            Err(_) => {
                let mut object = BTreeMap::new();
                object.insert("bytes", &self.0);
                object.serialize(serializer)
            }
        }
    }
}

fn error(message: impl Into<String>) -> mlua::Error {
    mlua::Error::RuntimeError(format!("Luau benchmark sampler: {}", message.into()))
}

fn clock_error(cause: io::Error) -> mlua::Error {
    error(format!("CPU clock or phase boundary: {cause}"))
}
