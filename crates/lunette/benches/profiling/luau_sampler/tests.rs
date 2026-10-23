use proptest::{
    prelude::*,
    test_runner::{Config, RngSeed},
};

use super::*;

#[test]
fn fractional_cpu_budget_survives_empty_and_repeated_entries() {
    let mut profile = PhaseProfile::default();
    assert_eq!(profile.account_cpu(0, 10), 0);
    assert_eq!(profile.account_cpu(3, 10), 0);
    assert_eq!(profile.account_cpu(6, 10), 0);
    assert_eq!(profile.account_cpu(1, 10), 1);
    assert_eq!(profile.account_cpu(25, 10), 2);
    assert_eq!(profile.cpu_ns, 35);
    assert_eq!(profile.budget_intervals, 3);
    assert_eq!(profile.remainder_ns, 5);
}

#[test]
fn accounting_saturates_totals_without_losing_fractional_budget() {
    for period in [1, 2, 10, 1_000_000_000, u64::MAX] {
        let mut profile = PhaseProfile::default();
        profile.account_cpu(u64::MAX, period);
        profile.account_cpu(u64::MAX, period);
        let total = 2 * u128::from(u64::MAX);
        assert_eq!(profile.cpu_ns, u64::MAX);
        assert_eq!(
            profile.budget_intervals,
            (total / u128::from(period)).min(u128::from(u64::MAX)) as u64
        );
        assert_eq!(profile.remainder_ns, (total % u128::from(period)) as u64);
    }
}

proptest! {
    #![proptest_config(Config {
        cases: 256,
        failure_persistence: None,
        rng_seed: RngSeed::Fixed(0x7072_6f66_696c_6572),
        ..Config::default()
    })]

    #[test]
    fn splitting_cpu_time_preserves_budget_and_remainder(
        elapsed in prop::collection::vec(any::<u64>(), 0..64),
        period in 1_u64..=u64::MAX,
    ) {
        let mut split = PhaseProfile::default();
        let mut reverse = PhaseProfile::default();
        let total: u128 = elapsed.iter().map(|value| u128::from(*value)).sum();
        for value in &elapsed {
            split.account_cpu(*value, period);
        }
        for value in elapsed.iter().rev() {
            reverse.account_cpu(*value, period);
        }
        prop_assert_eq!(split.cpu_ns, total.min(u128::from(u64::MAX)) as u64);
        prop_assert_eq!(split.remainder_ns, (total % u128::from(period)) as u64);
        prop_assert_eq!(
            split.budget_intervals,
            (total / u128::from(period)).min(u128::from(u64::MAX)) as u64
        );
        prop_assert_eq!(split.cpu_ns, reverse.cpu_ns);
        prop_assert_eq!(split.budget_intervals, reverse.budget_intervals);
        prop_assert_eq!(split.remainder_ns, reverse.remainder_ns);
        prop_assert!(split.remainder_ns < period);
    }

    #[test]
    fn collapsed_debug_labels_preserve_arbitrary_bytes_without_stack_separators(
        bytes in prop::collection::vec(any::<u8>(), 0..256),
    ) {
        let label = DebugText(bytes.clone()).label();
        prop_assert!(label.is_ascii());
        prop_assert!(!label.contains([';', '\n', '\r', '\0']));
        prop_assert_eq!(decode_label(&label), bytes);
    }

    #[test]
    fn raw_debug_text_preserves_the_bytes_written_to_the_profile(
        bytes in prop::collection::vec(any::<u8>(), 0..256),
    ) {
        let encoded = serde_json::to_value(DebugText(bytes.clone()))
            .expect("debug text is representable in the raw profile");
        let decoded = match encoded {
            Value::String(text) => text.into_bytes(),
            Value::Object(object) => serde_json::from_value::<Vec<u8>>(object["bytes"].clone())
                .expect("the raw profile's bytes object contains bytes"),
            other => panic!("unexpected debug text representation: {other}"),
        };
        prop_assert_eq!(decoded, bytes);
    }
}

#[test]
fn raw_and_collapsed_profiles_preserve_missing_binary_and_native_metadata() {
    let missing = Frame {
        source: None,
        name: None,
        what: None,
        line_defined: -1,
        current_line: -2,
        native: false,
    };
    assert_eq!(
        missing.label(),
        "[unknown source]:-2:[anonymous] [defined:-1 Luau]"
    );
    let binary = Frame {
        source: Some(DebugText(b"@a;\n\\\xff".to_vec())),
        name: Some(DebugText(b"leaf\t".to_vec())),
        what: Some(DebugText(b"Lua".to_vec())),
        line_defined: 4,
        current_line: 7,
        native: true,
    };
    assert_eq!(
        binary.label(),
        "@a\\x3b\\n\\\\\\xff:7:leaf\\t [defined:4 native]"
    );
    let c_frame = Frame {
        source: Some(DebugText(Vec::new())),
        name: Some(DebugText(Vec::new())),
        what: Some(DebugText(b"C".to_vec())),
        line_defined: 0,
        current_line: -1,
        native: true,
    };
    assert_eq!(c_frame.label(), ":-1: [defined:0 C]");
    let stack = Stack {
        frames: vec![missing, binary, c_frame],
        truncated: true,
    };
    let collapsed = stack.collapsed();
    assert_eq!(collapsed.split(';').count(), 4);
    assert!(collapsed.starts_with("[truncated];[unknown source]"));
    let mut profile = PhaseProfile::default();
    profile.stacks.insert(stack, 2);
    let raw = profile.to_json();
    assert_eq!(raw["stacks"][0]["frames"][0]["source"], Value::Null);
    assert_eq!(raw["stacks"][0]["frames"][0]["current_line"], -2);
    assert_eq!(
        raw["stacks"][0]["frames"][1]["source"],
        json!({"bytes": b"@a;\n\\\xff".to_vec()})
    );
    assert_eq!(raw["stacks"][0]["truncated"], true);
    assert_eq!(raw["stacks"][0]["count"], 2);
    assert_eq!(raw["stacks"][0]["collapsed"], collapsed);
    assert_eq!(raw["collapsed"], format!("{collapsed} 2\n"));
    assert_eq!(
        Stack {
            frames: Vec::new(),
            truncated: false
        }
        .collapsed(),
        "[empty]"
    );
    assert_eq!(
        Stack {
            frames: Vec::new(),
            truncated: true
        }
        .collapsed(),
        "[truncated]"
    );
}

#[test]
fn invalid_frequencies_and_existing_interrupts_leave_the_vm_unchanged() -> Result<()> {
    let lua = Lua::new();
    // Both invalid values return before the production clock or timer is reached.
    for hz in [0, 1_000_000_001] {
        let result = Sampler::install(&lua, hz);
        assert!(result.is_err());
        assert_uninstalled(&lua)?;
    }
    let userdata = callback_userdata(&lua)?;
    replace_interrupt(&lua, Some(existing_interrupt))?;
    let result = install(&lua, &Rc::new(FakeClock::default()));
    assert!(result.is_err());
    assert_interrupt(&lua, Some(existing_interrupt))?;
    assert_eq!(callback_userdata(&lua)?, userdata);
    assert!(CONTEXT.with(|slot| slot.borrow().is_none()));
    replace_interrupt(&lua, None)?;
    install(&lua, &Rc::new(FakeClock::default()))?.finish()?;
    assert_uninstalled(&lua)?;
    Ok(())
}

#[test]
fn finish_and_drop_restore_the_interrupt_and_allow_tls_reuse() -> Result<()> {
    let lua = Lua::new();
    let userdata = callback_userdata(&lua)?;
    for finish in [true, false, true] {
        let sampler = install(&lua, &Rc::new(FakeClock::default()))?;
        let boundary = sampler.boundary(&lua)?;
        boundary.call::<()>(("update", true))?;
        boundary.call::<()>(("update", false))?;
        boundary.call::<()>(("draw", true))?;
        boundary.call::<()>(("draw", false))?;
        if finish {
            let raw = sampler.finish()?;
            assert_eq!(raw["format_version"], 1);
            assert_eq!(raw["timer_requests"], 0);
            assert_eq!(raw["phases"]["update"]["samples"], 0);
        } else {
            drop(sampler);
        }
        assert_uninstalled(&lua)?;
        assert_eq!(callback_userdata(&lua)?, userdata);
        assert!(boundary.call::<()>(("draw", true)).is_err());
    }
    Ok(())
}

#[test]
fn cleanup_after_lua_and_finish_errors_allows_another_sampler() -> Result<()> {
    let lua = Lua::new();
    for failure in [
        Failure::Lua,
        Failure::Unbalanced,
        Failure::Clock,
        Failure::Borrow,
    ] {
        let clock = Rc::new(FakeClock::default());
        let sampler = install(&lua, &clock)?;
        let boundary = sampler.boundary(&lua)?;
        boundary.call::<()>(("update", true))?;
        match failure {
            Failure::Lua => {
                lua.globals().set("boundary", boundary)?;
                assert!(lua.load("boundary('draw', false)").exec().is_err());
                drop(sampler);
            }
            Failure::Unbalanced => assert!(sampler.finish().is_err()),
            Failure::Clock => {
                clock.fail.set(true);
                request(&sampler.context.borrow().shared, 1);
                deliver(&lua, -1)?;
                assert!(sampler.finish().is_err());
            }
            Failure::Borrow => {
                let borrowed = sampler.context.borrow_mut();
                deliver(&lua, -1)?;
                drop(borrowed);
                assert!(sampler.finish().is_err());
            }
        }
        assert_uninstalled(&lua)?;
        install(&lua, &Rc::new(FakeClock::default()))?.finish()?;
        assert_uninstalled(&lua)?;
    }
    Ok(())
}

#[test]
fn cleanup_reports_a_replaced_interrupt_without_overwriting_it() -> Result<()> {
    let lua = Lua::new();
    let sampler = install(&lua, &Rc::new(FakeClock::default()))?;
    replace_interrupt(&lua, Some(existing_interrupt))?;
    let result = sampler.finish();
    assert!(result.is_err());
    assert_interrupt(&lua, Some(existing_interrupt))?;
    assert!(CONTEXT.with(|slot| slot.borrow().is_none()));
    replace_interrupt(&lua, None)?;
    install(&lua, &Rc::new(FakeClock::default()))?.finish()?;
    Ok(())
}

#[test]
fn boundary_rejects_other_vms_and_concurrent_samplers_on_the_same_thread() -> Result<()> {
    let lua = Lua::new();
    let other = Lua::new();
    let clock = Rc::new(FakeClock::default());
    let sampler = install(&lua, &clock)?;
    assert!(sampler.boundary(&other).is_err());
    assert!(install(&other, &clock).is_err());
    sampler.finish()?;
    install(&other, &clock)?.finish()?;
    assert_uninstalled(&lua)?;
    assert_uninstalled(&other)?;
    Ok(())
}

#[test]
fn stale_requests_cannot_cross_phases_or_spend_the_next_sampling_budget() -> Result<()> {
    let lua = Lua::new();
    let clock = Rc::new(FakeClock::default());
    let sampler = install(&lua, &clock)?;
    let boundary = sampler.boundary(&lua)?;
    let shared = Arc::clone(&sampler.context.borrow().shared);

    clock.set(2);
    boundary.call::<()>(("update", true))?;
    let update_epoch = shared.epoch.load(Ordering::Acquire);
    clock.set(8);
    boundary.call::<()>(("update", false))?;
    clock.set(11);
    boundary.call::<()>(("draw", true))?;
    let draw_epoch = shared.epoch.load(Ordering::Acquire);
    assert_ne!(draw_epoch, update_epoch);
    clock.set(25);
    // The old timer publishes after the next phase has already cleared its due flag.
    request(&shared, update_epoch);
    deliver(&lua, -1)?;
    assert_eq!(sampler.context.borrow().draw.samples, 0);
    request(&shared, draw_epoch);
    clock.step.set(3);
    deliver(&lua, 0)?;
    clock.step.set(0);
    // A duplicate publication from before capture finishes arrives before the new deadline.
    clock.set(30);
    request(&shared, draw_epoch);
    deliver(&lua, -1)?;
    clock.set(34);
    boundary.call::<()>(("draw", false))?;

    clock.set(40);
    boundary.call::<()>(("update", true))?;
    assert_eq!(shared.deadline_ns.load(Ordering::Acquire), 44);
    clock.set(44);
    request(&shared, shared.epoch.load(Ordering::Acquire));
    deliver(&lua, -1)?;
    clock.set(49);
    boundary.call::<()>(("update", false))?;
    clock.set(55);
    let raw = sampler.finish()?;

    assert_eq!(raw["outside_phase_cpu_ns"], 17);
    assert_eq!(raw["stack_capture_cpu_ns"], 3);
    assert_eq!(raw["timer_requests"], 4);
    assert_eq!(raw["stale_timer_requests"], 2);
    assert_eq!(raw["uncollected_timer_requests"], 2);
    assert_eq!(raw["phases"]["update"]["cpu_ns"], 15);
    assert_eq!(raw["phases"]["draw"]["cpu_ns"], 20);
    assert_eq!(raw["phases"]["draw"]["gc_samples"], 1);
    for phase in ["update", "draw"] {
        let profile = &raw["phases"][phase];
        assert_eq!(
            profile["budget_intervals"].as_u64(),
            Some(
                profile["samples"].as_u64().expect("sample count")
                    + profile["missed_samples"].as_u64().expect("missed count")
            )
        );
        let stack_count: u64 = profile["stacks"]
            .as_array()
            .expect("raw stacks")
            .iter()
            .map(|stack| stack["count"].as_u64().expect("stack count"))
            .sum();
        assert_eq!(stack_count, profile["samples"].as_u64().expect("samples"));
    }
    assert_eq!(raw["phases"]["update"]["samples"], 1);
    assert_eq!(raw["phases"]["draw"]["samples"], 1);
    assert_eq!(raw["phases"]["draw"]["missed_samples"], 1);
    assert_uninstalled(&lua)?;
    Ok(())
}

#[test]
fn a_real_luau_safepoint_collects_root_first_frames_without_a_timer() -> Result<()> {
    let lua = Lua::new();
    let clock = Rc::new(FakeClock::default());
    let sampler = install(&lua, &clock)?;
    let boundary = sampler.boundary(&lua)?;
    let shared = Arc::clone(&sampler.context.borrow().shared);
    let sample_clock = Rc::clone(&clock);
    lua.globals().set("boundary", boundary)?;
    lua.globals().set(
        "request_sample",
        lua.create_function(move |_, ()| {
            sample_clock.set(35);
            request(&shared, shared.epoch.load(Ordering::Acquire));
            Ok(())
        })?,
    )?;
    lua.load(
        r#"
        local function leaf()
            request_sample()
            local total = 0
            for i = 1, 8 do total += i end
            return total
        end
        local function root()
            boundary('update', true)
            local result = leaf()
            boundary('update', false)
            return result
        end
        return root()
    "#,
    )
    .set_name("@profile-fixture.luau")
    .exec()?;
    let raw = sampler.finish()?;
    let profile = &raw["phases"]["update"];
    assert_eq!(profile["samples"], 1);
    assert_eq!(profile["budget_intervals"], 3);
    assert_eq!(profile["missed_samples"], 2);
    assert_eq!(profile["empty_samples"], 0);
    let frames = profile["stacks"][0]["frames"]
        .as_array()
        .expect("captured stack frames");
    let names: Vec<_> = frames
        .iter()
        .filter_map(|frame| frame["name"].as_str())
        .collect();
    let root = names
        .iter()
        .position(|name| *name == "root")
        .expect("root frame");
    let leaf = names
        .iter()
        .position(|name| *name == "leaf")
        .expect("leaf frame");
    assert!(root < leaf, "frames are root-first: {names:?}");
    assert!(
        frames
            .iter()
            .any(|frame| frame["source"] == "@profile-fixture.luau")
    );
    assert_uninstalled(&lua)?;
    Ok(())
}

#[derive(Default)]
struct FakeClock {
    now: Cell<u64>,
    step: Cell<u64>,
    fail: Cell<bool>,
}

impl FakeClock {
    fn set(&self, now: u64) {
        self.now.set(now);
    }
}

impl Clock for FakeClock {
    fn now(&self) -> io::Result<u64> {
        if self.fail.get() {
            return Err(io::Error::other("injected CPU clock failure"));
        }
        let now = self.now.get();
        self.now.set(now.saturating_add(self.step.get()));
        Ok(now)
    }
}

enum Failure {
    Lua,
    Unbalanced,
    Clock,
    Borrow,
}

fn install(lua: &Lua, clock: &Rc<FakeClock>) -> Result<Sampler> {
    Sampler::install_hook(lua, 100_000_000, Rc::clone(clock) as Rc<dyn Clock>)
}

fn request(shared: &TimerState, epoch: u64) {
    shared.request_epoch.store(epoch, Ordering::Release);
    if !shared.due.swap(true, Ordering::AcqRel) {
        shared.requests.fetch_add(1, Ordering::Relaxed);
    }
}

fn deliver(lua: &Lua, gc: c_int) -> Result<()> {
    // SAFETY: the real VM is locked on its owning thread, and no Lua code is executing.
    // This drives the installed hook at a chosen clock value instead of starting a timer.
    unsafe {
        lua.exec_raw::<()>((), |state| {
            let callback = (*ffi::lua_callbacks(state))
                .interrupt
                .expect("installed interrupt");
            callback(state, gc);
        })
    }
}

fn replace_interrupt(lua: &Lua, interrupt: Option<Interrupt>) -> Result<()> {
    // SAFETY: only this owning thread accesses the locked VM's interrupt slot.
    unsafe {
        lua.exec_raw::<()>((), |state| {
            (*ffi::lua_callbacks(state)).interrupt = interrupt
        })
    }
}

fn callback_userdata(lua: &Lua) -> Result<*mut std::ffi::c_void> {
    let mut userdata = ptr::null_mut();
    // SAFETY: the pointer is copied without dereferencing or changing mlua's userdata.
    unsafe { lua.exec_raw::<()>((), |state| userdata = (*ffi::lua_callbacks(state)).userdata)? };
    Ok(userdata)
}

fn assert_interrupt(lua: &Lua, expected: Option<Interrupt>) -> Result<()> {
    // SAFETY: the locked VM is live, and comparing callback addresses invokes neither one.
    unsafe {
        lua.exec_raw::<()>((), |state| {
            let actual = (*ffi::lua_callbacks(state)).interrupt;
            assert!(match (actual, expected) {
                (None, None) => true,
                (Some(actual), Some(expected)) => ptr::fn_addr_eq(actual, expected),
                _ => false,
            });
        })
    }
}

fn assert_uninstalled(lua: &Lua) -> Result<()> {
    assert_interrupt(lua, None)?;
    assert!(CONTEXT.with(|slot| slot.borrow().is_none()));
    Ok(())
}

unsafe extern "C-unwind" fn existing_interrupt(_: *mut ffi::lua_State, _: c_int) {}

fn decode_label(label: &str) -> Vec<u8> {
    let mut bytes = label.bytes();
    let mut decoded = Vec::new();
    while let Some(byte) = bytes.next() {
        if byte != b'\\' {
            decoded.push(byte);
            continue;
        }
        decoded.push(match bytes.next().expect("an escape contains a suffix") {
            b'0' => 0,
            b't' => b'\t',
            b'n' => b'\n',
            b'r' => b'\r',
            b'\\' => b'\\',
            b'\'' => b'\'',
            b'"' => b'"',
            b'x' => {
                let high = char::from(bytes.next().expect("first hex digit"))
                    .to_digit(16)
                    .expect("hex digit");
                let low = char::from(bytes.next().expect("second hex digit"))
                    .to_digit(16)
                    .expect("hex digit");
                (high * 16 + low) as u8
            }
            other => panic!("unexpected escape suffix: {other}"),
        });
    }
    decoded
}
