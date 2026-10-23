use std::time::{Duration, Instant};

use mlua::Lua;

use super::*;

const PROBE: &str = "return function(probe: () -> boolean): boolean return probe() end";

// Compilation finishes on another thread, so a test waits for the bind instead of assuming how long the worker takes.
const DEADLINE: Duration = Duration::from_secs(10);

#[test]
fn the_worker_compiles_and_a_later_step_binds_existing_closures() {
    let Some(lua) = tiered(2) else { return };
    let function = returned(&lua, Loader::C, PROBE);
    call_probe(&lua, &function);
    call_probe(&lua, &function);
    assert_eq!(hot_queue_len(&lua).expect("the queue is readable"), 1);

    let mut promoter = Promoter::spawn(InstructionBudget(usize::MAX)).expect("the worker starts");
    assert_eq!(promoter.step(&lua).expect("the job is handed over"), 0);
    assert_eq!(hot_queue_len(&lua).expect("the queue is readable"), 0);
    // The function keeps running interpreted while its code is generated.
    assert!(!call_probe(&lua, &function));

    let started = Instant::now();
    let mut bound = 0;
    while bound == 0 {
        assert!(
            started.elapsed() < DEADLINE,
            "the worker did not finish the job"
        );
        bound = promoter
            .step(&lua)
            .expect("the step binds when the job is ready");
    }
    assert_eq!(bound, 1);
    assert!(call_probe(&lua, &function));
    promoter.shutdown(&lua).expect("the idle promoter stops");
}

#[test]
fn shutdown_discards_the_job_in_flight_before_the_vm_closes() {
    let Some(lua) = tiered(1) else { return };
    let function = returned(&lua, Loader::C, PROBE);
    call_probe(&lua, &function);

    let mut promoter = Promoter::spawn(InstructionBudget(usize::MAX)).expect("the worker starts");
    promoter.step(&lua).expect("the job is handed over");
    promoter
        .shutdown(&lua)
        .expect("the job in flight is discarded");
    assert!(!call_probe(&lua, &function));
    lua.gc_collect()
        .expect("the released function can be collected");
    drop(lua);
}

#[test]
fn dropping_a_promoter_waits_for_its_job_before_the_vm_closes() {
    let Some(lua) = tiered(1) else { return };
    let function = returned(&lua, Loader::C, PROBE);
    call_probe(&lua, &function);

    let mut promoter = Promoter::spawn(InstructionBudget(usize::MAX)).expect("the worker starts");
    promoter.step(&lua).expect("the job is handed over");
    drop(promoter);
    // The worker has finished with the pinned function, so the VM closes without a reader.
    drop(function);
    drop(lua);
}

#[test]
fn a_promoter_outside_tiered_execution_takes_nothing() {
    let lua = Lua::new();
    configure(&lua, ExecutionMode::Optimized).expect("optimized execution is supported");
    let mut promoter = Promoter::spawn(InstructionBudget(usize::MAX)).expect("the worker starts");
    for _ in 0..3 {
        assert_eq!(promoter.step(&lua).expect("an empty step succeeds"), 0);
    }
    promoter.shutdown(&lua).expect("the idle promoter stops");
}
