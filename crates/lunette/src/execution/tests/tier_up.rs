use std::num::NonZeroU32;

use mlua::{Function, Lua};

use super::*;

const PROBE: &str = "return function(probe: () -> boolean): boolean return probe() end";

#[test]
fn a_function_promotes_after_its_threshold_and_its_closures_enter_native_code() {
    let Some(lua) = tiered(4) else { return };
    for loader in [Loader::C, Loader::Mlua] {
        let function = returned(&lua, loader, PROBE);
        for _ in 0..3 {
            assert!(!call_probe(&lua, &function));
        }
        assert_eq!(hot_queue_len(&lua).expect("the queue is readable"), 0);

        assert!(!call_probe(&lua, &function));
        assert_eq!(hot_queue_len(&lua).expect("the queue is readable"), 1);
        assert_eq!(
            promote(&lua, InstructionBudget(usize::MAX)).expect("promotion succeeds"),
            1
        );
        assert_eq!(hot_queue_len(&lua).expect("the queue is readable"), 0);
        assert!(call_probe(&lua, &function));
    }
}

#[test]
fn loop_iterations_count_towards_the_threshold() {
    let Some(lua) = tiered(50) else { return };
    let function = returned(
        &lua,
        Loader::C,
        "return function(probe: () -> boolean): boolean local total = 0 for index = 1, 100 do total += index end return probe() end",
    );
    assert!(!call_probe(&lua, &function));
    assert_eq!(
        promote(&lua, InstructionBudget(usize::MAX)).expect("promotion succeeds"),
        1
    );
    assert!(call_probe(&lua, &function));
}

#[test]
fn the_instruction_budget_still_takes_one_function() {
    let Some(lua) = tiered(1) else { return };
    let first = returned(&lua, Loader::C, PROBE);
    let second = returned(&lua, Loader::C, PROBE);
    call_probe(&lua, &first);
    call_probe(&lua, &second);
    assert_eq!(hot_queue_len(&lua).expect("the queue is readable"), 2);

    assert_eq!(
        promote(&lua, InstructionBudget(0)).expect("promotion succeeds"),
        1
    );
    assert!(call_probe(&lua, &first));
    assert!(!call_probe(&lua, &second));
    assert_eq!(
        promote(&lua, InstructionBudget(0)).expect("promotion succeeds"),
        1
    );
    assert!(call_probe(&lua, &second));
    assert_eq!(
        promote(&lua, InstructionBudget(0)).expect("an empty queue promotes nothing"),
        0
    );
}

#[test]
fn leaving_tiered_mode_stops_new_functions_counting_and_keeps_queued_ones() {
    let Some(lua) = tiered(2) else { return };
    let queued = returned(&lua, Loader::C, PROBE);
    call_probe(&lua, &queued);
    call_probe(&lua, &queued);
    assert_eq!(hot_queue_len(&lua).expect("the queue is readable"), 1);

    configure(&lua, ExecutionMode::NativeMarked).expect("marked execution is supported");
    let uncounted = returned(&lua, Loader::C, PROBE);
    for _ in 0..10 {
        assert!(!call_probe(&lua, &uncounted));
    }
    assert_eq!(hot_queue_len(&lua).expect("the queue is readable"), 1);
    let error = promote(&lua, InstructionBudget(usize::MAX))
        .expect_err("promotion outside tiered execution is rejected");
    assert!(
        error.to_string().contains("requires tiered execution"),
        "{error}"
    );

    configure(&lua, ExecutionMode::Tiered).expect("tiered execution is supported");
    assert_eq!(
        promote(&lua, InstructionBudget(usize::MAX)).expect("promotion succeeds"),
        1
    );
    assert!(call_probe(&lua, &queued));
    assert!(!call_probe(&lua, &uncounted));
}

#[test]
fn promotion_is_rejected_outside_tiered_execution() {
    for mode in [
        ExecutionMode::Interpreter,
        ExecutionMode::Optimized,
        ExecutionMode::Native,
        ExecutionMode::NativeMarked,
    ] {
        let lua = Lua::new();
        configure(&lua, ExecutionMode::Interpreter).expect("interpreter execution is supported");
        configure_mode(&lua, mode);
        let error = promote(&lua, InstructionBudget(usize::MAX))
            .expect_err("promotion outside tiered execution is rejected");
        assert!(
            error.to_string().contains("requires tiered execution"),
            "{mode:?} {error}"
        );
        assert_eq!(hot_queue_len(&lua).expect("the queue is readable"), 0);
    }
}

#[test]
fn tier_up_parameters_outside_the_c_range_are_rejected() {
    let lua = Lua::new();
    let error = set_tier_up(
        &lua,
        TierUp {
            threshold: NonZeroU32::MAX,
            queue_capacity: NonZeroU32::MIN,
        },
    )
    .expect_err("an oversized threshold is rejected");
    assert!(error.to_string().contains("threshold exceeds"), "{error}");
}

#[test]
fn promoted_functions_keep_source_errors_and_debug_information() {
    let Some(lua) = tiered(1) else { return };
    let function = returned(
        &lua,
        Loader::C,
        "local function fail(raise: boolean)\n    if raise then\n        error('promotion sentinel')\n    end\nend\nreturn fail",
    );
    function.call::<()>(false).expect("the function runs");
    assert_eq!(
        promote(&lua, InstructionBudget(usize::MAX)).expect("promotion succeeds"),
        1
    );
    let message = function
        .call::<()>(true)
        .expect_err("the promoted function raises")
        .to_string();
    assert!(message.contains("tier-up.luau:3:"), "{message}");
    assert!(message.contains("promotion sentinel"), "{message}");
    assert_eq!(function.info().line_defined, Some(1));
}

#[test]
fn promotion_metrics_are_a_subset_of_the_native_totals() {
    let lua = Lua::new();
    enable_metrics(&lua).expect("metrics are enabled before configuration");
    if !configure_tiered(&lua, 1) {
        return;
    }
    let before = snapshot(&lua);
    // The chunk queues itself on entry and `returned` promotes it.
    let function = returned(&lua, Loader::C, PROBE);
    call_probe(&lua, &function);
    assert_eq!(
        promote(&lua, InstructionBudget(usize::MAX)).expect("promotion succeeds"),
        1
    );
    assert_eq!(
        promote(&lua, InstructionBudget(usize::MAX)).expect("an empty queue promotes nothing"),
        0
    );

    let after = snapshot(&lua);
    assert_monotonic(&before, &after);
    assert_eq!(after.hotPromotionCalls - before.hotPromotionCalls, 2);
    assert_eq!(after.hotFunctionsPromoted - before.hotFunctionsPromoted, 2);
    assert_eq!(after.nativeFunctionsBound - before.nativeFunctionsBound, 2);
    // The C loader's marked-only request for the unmarked chunk counts as a native compile call that binds nothing.
    assert_eq!(after.nativeCompileCalls - before.nativeCompileCalls, 3);
    assert!(after.hotPromotionCpuNs <= after.nativeCompileCpuNs);
    assert!(after.hotPromotionElapsedNs <= after.nativeCompileElapsedNs);
    if after.threadCpuClockAvailable != 0 {
        assert!(after.hotPromotionCpuNs > before.hotPromotionCpuNs);
    }
}

/// Returns a VM in tiered execution with the given threshold, or `None` when native compilation is unsupported.
fn tiered(threshold: u32) -> Option<Lua> {
    let lua = Lua::new();
    configure_tiered(&lua, threshold).then_some(lua)
}

fn configure_tiered(lua: &Lua, threshold: u32) -> bool {
    configure(lua, ExecutionMode::Interpreter).expect("interpreter execution is supported");
    configure_mode(lua, ExecutionMode::Tiered);
    if !supported() {
        return false;
    }
    set_tier_up(
        lua,
        TierUp {
            threshold: NonZeroU32::new(threshold).expect("the threshold is nonzero"),
            queue_capacity: NonZeroU32::new(8).expect("the capacity is nonzero"),
        },
    )
    .expect("tier-up parameters are accepted");
    true
}

// The chunk is loaded after the parameters apply, so its own entry counts too. Draining a chunk that queued itself keeps the queue to the
// functions under test, which is unambiguous only while nothing else waits.
fn returned(lua: &Lua, loader: Loader, source: &str) -> Function {
    let chunk = loader
        .load(lua, source, c"@tier-up.luau")
        .expect("the fixture loads");
    let before = hot_queue_len(lua).expect("the queue is readable");
    let function = chunk.call(()).expect("the fixture returns a function");
    if hot_queue_len(lua).expect("the queue is readable") > before {
        assert_eq!(
            before, 0,
            "a queued chunk is drained only from an empty queue"
        );
        promote(lua, InstructionBudget(usize::MAX)).expect("the chunk promotes");
    }
    function
}

fn call_probe(lua: &Lua, function: &Function) -> bool {
    function.call(probe(lua)).expect("the probe returns")
}
