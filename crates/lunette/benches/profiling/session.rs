//! Linux-only: coordinates Luau sampling and acknowledged perf FIFO gates at callback boundaries.

use std::{
    cell::RefCell,
    error::Error,
    fmt,
    fs::{File, OpenOptions},
    io::{self, Read, Write},
    os::{
        fd::AsRawFd,
        unix::fs::{FileTypeExt, MetadataExt, OpenOptionsExt},
    },
    path::{Path, PathBuf},
    rc::Rc,
    time::{Duration, Instant},
};

use mlua::{ErrorContext, Function, Lua};
use serde_json::{Value, json};

use crate::profiling::{luau_sampler::Sampler, perf_ack::Acknowledgement};

pub struct Session {
    sampler: Option<Sampler>,
    state: Rc<RefCell<BoundaryState>>,
    hz: u32,
}

impl Session {
    pub fn start(
        lua: &Lua,
        hz: u32,
        perf_control: Option<PathBuf>,
        perf_ack: Option<PathBuf>,
        sample_luau: bool,
    ) -> Result<Self, Box<dyn Error>> {
        if hz == 0 {
            return Err(ProfileError::state("sampling frequency must be greater than zero").into());
        }
        let perf = match (perf_control, perf_ack) {
            (None, None) => None,
            (Some(control), Some(ack)) => Some(PerfGate::open(&control, &ack)?),
            _ => {
                return Err(ProfileError::state(
                    "perf control and acknowledgement paths must be supplied together",
                )
                .into());
            }
        };
        if !sample_luau && perf.is_none() {
            return Err(
                ProfileError::state("native-only profiling requires perf control paths").into(),
            );
        }
        let sampler = if sample_luau {
            Some(Sampler::install(lua, hz)?)
        } else {
            None
        };
        Ok(Self {
            sampler,
            state: Rc::new(RefCell::new(BoundaryState {
                lifecycle: Lifecycle::Idle,
                perf,
                update_callbacks: 0,
                draw_callbacks: 0,
            })),
            hz,
        })
    }

    /// Returns a callback accepting ("update" | "draw", entering).
    pub fn boundary(&self, lua: &Lua) -> mlua::Result<Function> {
        let sample_boundary = self
            .sampler
            .as_ref()
            .map(|sampler| sampler.boundary(lua))
            .transpose()?;
        let state = Rc::clone(&self.state);
        lua.create_function(move |_, (name, entering): (String, bool)| {
            let mut state = state.try_borrow_mut().map_err(|error| {
                mlua::Error::runtime(format!(
                    "desktop profile: recursive boundary callback: {error}"
                ))
            })?;
            let phase = match Phase::parse(&name) {
                Ok(phase) => phase,
                Err(error) => {
                    let cleanup = state.abort();
                    return Err(mlua::Error::external(with_cleanup(error, cleanup)));
                }
            };
            if let Err(error) = state.validate(phase, entering) {
                let cleanup = state.abort();
                return Err(mlua::Error::external(with_cleanup(error, cleanup)));
            }
            if entering {
                state.begin(phase).map_err(mlua::Error::external)?;
                if let Some(sample_boundary) = &sample_boundary
                    && let Err(error) = sample_boundary.call::<()>((name, true))
                {
                    let cleanup = state.abort();
                    return Err(callback_failure(error, cleanup));
                }
                return Ok(());
            }
            let sample_result = match &sample_boundary {
                Some(sample_boundary) => sample_boundary.call::<()>((name, false)),
                None => Ok(()),
            };
            let gate_result = state.end(phase);
            match (sample_result, gate_result) {
                (Ok(()), Ok(())) => Ok(()),
                (Err(error), cleanup) => {
                    state.lifecycle = Lifecycle::Failed;
                    Err(callback_failure(error, cleanup))
                }
                (Ok(()), Err(error)) => Err(mlua::Error::external(error)),
            }
        })
    }

    pub fn finish(mut self) -> Result<Value, Box<dyn Error>> {
        let (counts, perf_enabled, gate_result) = {
            let mut state = self.state.try_borrow_mut().map_err(|error| {
                ProfileError::state(format!("cannot finish inside a boundary callback: {error}"))
            })?;
            let counts = (state.update_callbacks, state.draw_callbacks);
            let perf_enabled = state.perf.is_some();
            let gate_result = state.finish();
            (counts, perf_enabled, gate_result)
        };
        // The interrupt hook must be removed even if disabling perf fails.
        let sampler_result = match self.sampler.take() {
            Some(sampler) => sampler
                .finish()
                .map_err(|error| -> Box<dyn Error> { error.into() }),
            None => Ok(Value::Null),
        };
        let luau = match (sampler_result, gate_result) {
            (Ok(value), Ok(())) => value,
            (Err(error), Ok(())) => return Err(error),
            (Ok(_), Err(error)) => return Err(error.into()),
            (Err(error), Err(cleanup)) => {
                return Err(ProfileError::cleanup(error, cleanup).into());
            }
        };
        if counts.0 == 0 || counts.0 != counts.1 {
            return Err(ProfileError::state(format!(
                "completed callback counts differ or are empty: update={}, draw={}",
                counts.0, counts.1
            ))
            .into());
        }
        Ok(json!({
            "schema_version": 1,
            "kind": "desktop_callback_profile",
            "timings_are_benchmark_results": false,
            "requested_hz": self.hz,
            "scope": {
                "phases": ["update", "draw"],
                "setup": false,
                "warmup": false,
                "submit": false,
                "wait": false,
                "microbenchmarks": false,
                "reloads": false,
            },
            "completed_callbacks": {
                "update": counts.0,
                "draw": counts.1,
            },
            "native_perf": {
                "enabled": perf_enabled,
                "gate": if perf_enabled { Some("acknowledged_fifo_per_callback") } else { None },
                "includes_boundary_overhead": perf_enabled,
                "thread_scope": "configured_by_perf_record",
            },
            "luau": luau,
        }))
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        match self.state.try_borrow_mut() {
            Ok(mut state) => {
                if let Err(error) = state.abort() {
                    tracing::error!(%error, "desktop profile cleanup failed");
                }
            }
            Err(error) => {
                tracing::error!(%error, "desktop profile cleanup cannot borrow boundary state");
            }
        }
        // Sampler's guard restores the interrupt hook before scene or Lua teardown.
        drop(self.sampler.take());
    }
}

fn callback_failure(error: mlua::Error, cleanup: Result<(), ProfileError>) -> mlua::Error {
    match cleanup {
        Ok(()) => error,
        Err(cleanup) => error.context(format!("desktop profile cleanup: {cleanup}")),
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Phase {
    Update,
    Draw,
}

impl Phase {
    fn parse(name: &str) -> Result<Self, ProfileError> {
        match name {
            "update" => Ok(Self::Update),
            "draw" => Ok(Self::Draw),
            _ => Err(ProfileError::state(format!(
                "unknown callback phase {name:?}"
            ))),
        }
    }
}

#[derive(Clone, Copy, Debug)]
enum Lifecycle {
    Idle,
    Active(Phase),
    Failed,
    Finished,
}

struct BoundaryState {
    lifecycle: Lifecycle,
    perf: Option<PerfGate>,
    update_callbacks: u64,
    draw_callbacks: u64,
}

impl BoundaryState {
    fn validate(&self, phase: Phase, entering: bool) -> Result<(), ProfileError> {
        match (self.lifecycle, entering) {
            (Lifecycle::Idle, true) => Ok(()),
            (Lifecycle::Active(active), false) if phase == active => Ok(()),
            _ => Err(ProfileError::state(format!(
                "invalid callback transition: {:?}, {phase:?}, entering={entering}",
                self.lifecycle
            ))),
        }
    }

    fn begin(&mut self, phase: Phase) -> Result<(), ProfileError> {
        self.lifecycle = Lifecycle::Active(phase);
        if let Some(perf) = &mut self.perf
            && let Err(error) = perf.enable()
        {
            let cleanup = self.abort();
            return Err(with_cleanup(error, cleanup));
        }
        Ok(())
    }

    fn end(&mut self, phase: Phase) -> Result<(), ProfileError> {
        if let Some(perf) = &mut self.perf
            && let Err(error) = perf.disable()
        {
            self.lifecycle = Lifecycle::Failed;
            return Err(error);
        }
        let count = match phase {
            Phase::Update => self.update_callbacks,
            Phase::Draw => self.draw_callbacks,
        };
        let Some(next) = count.checked_add(1) else {
            self.lifecycle = Lifecycle::Failed;
            return Err(ProfileError::state("completed callback count overflows"));
        };
        match phase {
            Phase::Update => self.update_callbacks = next,
            Phase::Draw => self.draw_callbacks = next,
        }
        self.lifecycle = Lifecycle::Idle;
        Ok(())
    }

    fn finish(&mut self) -> Result<(), ProfileError> {
        let previous = self.lifecycle;
        let cleanup = self.abort();
        self.lifecycle = Lifecycle::Finished;
        match previous {
            Lifecycle::Idle => cleanup,
            _ => Err(with_cleanup(
                ProfileError::state(format!("session finishes with callback state {previous:?}")),
                cleanup,
            )),
        }
    }

    fn abort(&mut self) -> Result<(), ProfileError> {
        self.lifecycle = Lifecycle::Finished;
        match &mut self.perf {
            Some(perf) => perf.disable(),
            None => Ok(()),
        }
    }
}

fn with_cleanup(error: ProfileError, cleanup: Result<(), ProfileError>) -> ProfileError {
    match cleanup {
        Ok(()) => error,
        Err(cleanup) => ProfileError::cleanup(Box::new(error), cleanup),
    }
}

struct PerfGate {
    control: File,
    ack: File,
    control_path: PathBuf,
    ack_path: PathBuf,
    acknowledgement: Acknowledgement,
    state: GateState,
}

#[derive(Clone, Copy)]
enum GateState {
    Disabled,
    PossiblyEnabled,
}

impl PerfGate {
    fn open(control: &Path, ack: &Path) -> Result<Self, ProfileError> {
        if control == ack {
            return Err(ProfileError::state(
                "perf control and acknowledgement paths are the same",
            ));
        }
        let control_file = open_fifo(control)?;
        let ack_file = open_fifo(ack)?;
        let control_metadata = control_file
            .metadata()
            .map_err(|error| ProfileError::io("inspect perf control", control, error))?;
        let ack_metadata = ack_file
            .metadata()
            .map_err(|error| ProfileError::io("inspect perf acknowledgement", ack, error))?;
        if control_metadata.dev() == ack_metadata.dev()
            && control_metadata.ino() == ack_metadata.ino()
        {
            return Err(ProfileError::state(
                "perf control and acknowledgement paths identify the same FIFO",
            ));
        }
        let mut gate = Self {
            control: control_file,
            ack: ack_file,
            control_path: control.to_owned(),
            ack_path: ack.to_owned(),
            acknowledgement: Acknowledgement::default(),
            state: GateState::PossiblyEnabled,
        };
        gate.disable()?;
        Ok(gate)
    }

    fn enable(&mut self) -> Result<(), ProfileError> {
        // An unacknowledged enable may already have reached perf and must be undone.
        self.state = GateState::PossiblyEnabled;
        self.command(b"enable\n")
    }

    fn disable(&mut self) -> Result<(), ProfileError> {
        if matches!(self.state, GateState::Disabled) {
            return Ok(());
        }
        self.command(b"disable\n")?;
        self.state = GateState::Disabled;
        Ok(())
    }

    fn command(&mut self, command: &[u8]) -> Result<(), ProfileError> {
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            ensure_deadline(deadline, &self.control_path)?;
            match self.control.write(command) {
                Ok(written) if written == command.len() => break,
                Ok(written) => {
                    return Err(ProfileError::state(format!(
                        "perf control {} writes {written} of {} command bytes",
                        self.control_path.display(),
                        command.len()
                    )));
                }
                Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                    wait_fifo(&self.control, libc::POLLOUT, deadline, &self.control_path)?;
                }
                Err(error) => {
                    return Err(ProfileError::io(
                        "write perf control",
                        &self.control_path,
                        error,
                    ));
                }
            }
        }
        loop {
            ensure_deadline(deadline, &self.ack_path)?;
            let mut byte = [0];
            match self.ack.read(&mut byte) {
                Ok(0) => return Err(ProfileError::state("perf acknowledgement pipe closes")),
                Ok(_) => match self.acknowledgement.push(byte[0]) {
                    Ok(true) => return Ok(()),
                    Ok(false) => {}
                    Err(error) => {
                        return Err(ProfileError::io(
                            "parse perf acknowledgement",
                            &self.ack_path,
                            error,
                        ));
                    }
                },
                Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                    wait_fifo(&self.ack, libc::POLLIN, deadline, &self.ack_path)?;
                }
                Err(error) => {
                    return Err(ProfileError::io(
                        "read perf acknowledgement",
                        &self.ack_path,
                        error,
                    ));
                }
            }
        }
    }
}

impl Drop for PerfGate {
    fn drop(&mut self) {
        if let Err(error) = self.disable() {
            tracing::error!(%error, "desktop profile perf cleanup failed");
        }
    }
}

fn open_fifo(path: &Path) -> Result<File, ProfileError> {
    // Opening both ends avoids FIFO open-order deadlocks; poll still bounds every transaction.
    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .custom_flags(libc::O_NONBLOCK | libc::O_CLOEXEC | libc::O_NOFOLLOW)
        .open(path)
        .map_err(|error| ProfileError::io("open perf FIFO", path, error))?;
    let metadata = file
        .metadata()
        .map_err(|error| ProfileError::io("inspect perf FIFO", path, error))?;
    if !metadata.file_type().is_fifo() {
        return Err(ProfileError::state(format!(
            "perf control path {} is not a FIFO",
            path.display()
        )));
    }
    Ok(file)
}

fn wait_fifo(
    file: &File,
    events: libc::c_short,
    deadline: Instant,
    path: &Path,
) -> Result<(), ProfileError> {
    loop {
        let remaining = ensure_deadline(deadline, path)?;
        let timeout = remaining
            .as_millis()
            .saturating_add(1)
            .min(i32::MAX as u128) as i32;
        let mut descriptor = libc::pollfd {
            fd: file.as_raw_fd(),
            events,
            revents: 0,
        };
        // SAFETY: the descriptor is initialized, valid for one element, and borrows a live file.
        let ready = unsafe { libc::poll(&mut descriptor, 1, timeout) };
        if ready < 0 {
            let error = io::Error::last_os_error();
            if error.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            return Err(ProfileError::io("poll perf FIFO", path, error));
        }
        if ready == 0 {
            continue;
        }
        if descriptor.revents & (libc::POLLERR | libc::POLLHUP | libc::POLLNVAL) != 0 {
            return Err(ProfileError::state(format!(
                "perf FIFO {} is unavailable (poll events {:#x})",
                path.display(),
                descriptor.revents
            )));
        }
        if descriptor.revents & events != 0 {
            return Ok(());
        }
    }
}

fn ensure_deadline(deadline: Instant, path: &Path) -> Result<Duration, ProfileError> {
    let remaining = deadline.saturating_duration_since(Instant::now());
    if remaining.is_zero() {
        return Err(ProfileError::state(format!(
            "perf FIFO {} does not respond within 5 seconds",
            path.display()
        )));
    }
    Ok(remaining)
}

#[derive(Debug)]
struct ProfileError {
    operation: String,
    source: Option<Box<dyn Error>>,
}

impl ProfileError {
    fn state(message: impl Into<String>) -> Self {
        Self {
            operation: message.into(),
            source: None,
        }
    }

    fn io(operation: &str, path: &Path, source: io::Error) -> Self {
        Self {
            operation: format!("{operation} {}", path.display()),
            source: Some(Box::new(source)),
        }
    }

    fn cleanup(source: Box<dyn Error>, cleanup: ProfileError) -> Self {
        Self {
            operation: format!("cleanup: {cleanup}; original error"),
            source: Some(source),
        }
    }
}

impl fmt::Display for ProfileError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "desktop profile: {}", self.operation)?;
        if let Some(source) = &self.source {
            write!(formatter, ": {source}")?;
        }
        Ok(())
    }
}

impl Error for ProfileError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        self.source.as_deref()
    }
}
