//! Schedules bounded proactive Luau collection without replacing automatic collection.

use std::{
    fmt::{self, Display, Formatter},
    num::ParseIntError,
    str::FromStr,
    time::{Duration, Instant},
};

use mlua::Lua;
use tracing::{debug, trace};

/// A soft elapsed-time limit for starting proactive GC steps after each completed frame.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct GcBudget(Duration);

impl Default for GcBudget {
    fn default() -> Self {
        // A provisional small share of an 11.1ms frame, not a measured optimum or idle-time allowance.
        Self(Duration::from_micros(200))
    }
}

impl Display for GcBudget {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> fmt::Result {
        self.0.as_micros().fmt(formatter)
    }
}

impl FromStr for GcBudget {
    type Err = ParseIntError;

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        value
            .parse()
            .map(|micros| Self(Duration::from_micros(micros)))
    }
}

/// Keeps per-state diagnostics; it owns no Lua references or asynchronous work.
pub(super) struct GcScheduler {
    budget: GcBudget,
    frames: u64,
    steps: u64,
    cycles: u64,
    overruns: u64,
}

impl GcScheduler {
    pub(super) fn new(budget: GcBudget) -> Self {
        debug!(target: "lunette::gc", budget_us = %budget, max_steps = MAX_STEPS, "proactive collection configured");
        Self {
            budget,
            frames: 0,
            steps: 0,
            cycles: 0,
            overruns: 0,
        }
    }

    pub(super) fn run(&mut self, lua: &Lua) -> mlua::Result<Report> {
        if self.budget.0.is_zero() {
            return Ok(Report::default());
        }
        let mut clock = MonotonicClock(Instant::now());
        let report = schedule(self.budget, &mut clock, &mut LuauCollector(lua))?;
        self.frames = self.frames.saturating_add(1);
        self.steps = self.steps.saturating_add(u64::from(report.steps));
        self.cycles = self
            .cycles
            .saturating_add(u64::from(report.cycle_completed));
        self.overruns = self
            .overruns
            .saturating_add(u64::from(report.elapsed > self.budget.0));
        trace!(
            target: "lunette::gc",
            budget_us = report.budget.as_micros(),
            elapsed_us = report.elapsed.as_micros(),
            budget_overrun = report.overrun,
            steps = report.steps,
            cycle_completed = report.cycle_completed,
            clock_regressed = report.clock_regressed,
            frames = self.frames,
            total_steps = self.steps,
            total_cycles = self.cycles,
            budget_overruns = self.overruns,
            "proactive collection completed"
        );
        Ok(report)
    }
}

// This also bounds work when the clock has insufficient resolution or stops advancing.
const MAX_STEPS: u32 = 32;

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub(super) struct Report {
    pub(super) budget: Duration,
    pub(super) steps: u32,
    pub(super) cycle_completed: bool,
    pub(super) elapsed: Duration,
    pub(super) overrun: bool,
    pub(super) clock_regressed: bool,
}

trait Clock {
    fn now(&mut self) -> Duration;
}

trait Collector {
    fn step(&mut self) -> mlua::Result<bool>;
}

fn schedule(
    budget: GcBudget,
    clock: &mut impl Clock,
    collector: &mut impl Collector,
) -> mlua::Result<Report> {
    let mut report = Report {
        budget: budget.0,
        ..Report::default()
    };
    if budget.0.is_zero() {
        return Ok(report);
    }
    let started = clock.now();
    let mut previous = started;
    while report.steps < MAX_STEPS {
        let now = clock.now();
        if now < previous {
            report.clock_regressed = true;
            break;
        }
        report.elapsed = now - started;
        report.overrun = report.elapsed > budget.0;
        if report.elapsed >= budget.0 {
            break;
        }
        previous = now;

        // Luau's atomic phase cannot be preempted. The budget only controls starting another step.
        report.cycle_completed = collector.step()?;
        report.steps += 1;
        let finished = clock.now();
        if finished < previous {
            report.clock_regressed = true;
            break;
        }
        report.elapsed = finished - started;
        report.overrun = report.elapsed > budget.0;
        previous = finished;
        if report.cycle_completed || report.elapsed >= budget.0 {
            break;
        }
    }
    Ok(report)
}

struct MonotonicClock(Instant);

impl Clock for MonotonicClock {
    fn now(&mut self) -> Duration {
        self.0.elapsed()
    }
}

struct LuauCollector<'a>(&'a Lua);

impl Collector for LuauCollector<'_> {
    fn step(&mut self) -> mlua::Result<bool> {
        // The minimum explicit step leaves automatic allocation assists and the GC tuning unchanged.
        self.0.gc_step()
    }
}

#[cfg(test)]
#[expect(
    clippy::expect_used,
    reason = "a failed expectation reports a test failure; production code does not use expect"
)]
mod tests {
    use std::{cell::Cell, rc::Rc};

    use proptest::prelude::*;

    use super::*;

    struct FakeClock {
        time: Rc<Cell<Duration>>,
    }

    impl Clock for FakeClock {
        fn now(&mut self) -> Duration {
            self.time.get()
        }
    }

    struct FakeCollector {
        time: Rc<Cell<Duration>>,
        cost: Duration,
        steps: u32,
        complete_at: Option<u32>,
        fail_at: Option<u32>,
        regress: bool,
    }

    impl Collector for FakeCollector {
        fn step(&mut self) -> mlua::Result<bool> {
            self.steps += 1;
            if self.fail_at == Some(self.steps) {
                return Err(mlua::Error::runtime("gc test: step failed"));
            }
            if self.regress {
                self.time.set(self.time.get().saturating_sub(self.cost));
            } else {
                self.time.set(self.time.get() + self.cost);
            }
            Ok(self.complete_at == Some(self.steps))
        }
    }

    fn fixture(cost_us: u64) -> (FakeClock, FakeCollector) {
        let time = Rc::new(Cell::new(Duration::from_secs(1)));
        (
            FakeClock {
                time: Rc::clone(&time),
            },
            FakeCollector {
                time,
                cost: Duration::from_micros(cost_us),
                steps: 0,
                complete_at: None,
                fail_at: None,
                regress: false,
            },
        )
    }

    #[test]
    fn zero_budget_does_not_read_the_clock_or_collect() {
        struct UnusedClock;
        impl Clock for UnusedClock {
            fn now(&mut self) -> Duration {
                panic!("disabled scheduling must not read the clock");
            }
        }
        let (_, mut collector) = fixture(10);
        let report = schedule(GcBudget(Duration::ZERO), &mut UnusedClock, &mut collector)
            .expect("disabled scheduling succeeds");
        assert_eq!(collector.steps, 0);
        assert_eq!(report, Report::default());
    }

    #[test]
    fn an_indivisible_overrun_step_stops_additional_work() {
        let (mut clock, mut collector) = fixture(300);
        let report = schedule(
            GcBudget(Duration::from_micros(200)),
            &mut clock,
            &mut collector,
        )
        .expect("the overrun is not a collection error");
        assert_eq!(report.steps, 1);
        assert_eq!(report.elapsed, Duration::from_micros(300));
        assert_eq!(report.budget, Duration::from_micros(200));
        assert!(report.overrun);
    }

    #[test]
    fn elapsed_clock_time_is_checked_before_starting_any_step() {
        struct ScriptedClock(std::array::IntoIter<Duration, 2>);
        impl Clock for ScriptedClock {
            fn now(&mut self) -> Duration {
                self.0
                    .next()
                    .expect("the scheduler stops at the elapsed cap")
            }
        }
        let mut clock = ScriptedClock([Duration::ZERO, Duration::from_micros(200)].into_iter());
        let (_, mut collector) = fixture(0);
        let report = schedule(
            GcBudget(Duration::from_micros(200)),
            &mut clock,
            &mut collector,
        )
        .expect("scheduling stops before its first step");
        assert_eq!(report.steps, 0);
        assert_eq!(collector.steps, 0);
    }

    #[test]
    fn elapsed_clock_time_between_steps_does_not_start_another_step() {
        struct ScriptedClock(std::array::IntoIter<Duration, 4>);
        impl Clock for ScriptedClock {
            fn now(&mut self) -> Duration {
                self.0
                    .next()
                    .expect("the scheduler stops at the elapsed cap")
            }
        }
        let mut clock = ScriptedClock(
            [
                Duration::ZERO,
                Duration::ZERO,
                Duration::from_micros(10),
                Duration::from_micros(200),
            ]
            .into_iter(),
        );
        let (_, mut collector) = fixture(0);
        let report = schedule(
            GcBudget(Duration::from_micros(200)),
            &mut clock,
            &mut collector,
        )
        .expect("scheduling stops before the second step");
        assert_eq!(report.steps, 1);
        assert_eq!(report.elapsed, Duration::from_micros(200));
        assert!(!report.overrun);
    }

    #[test]
    fn a_completed_cycle_does_not_start_another_cycle_in_the_same_frame() {
        let (mut clock, mut collector) = fixture(1);
        collector.complete_at = Some(2);
        let report = schedule(
            GcBudget(Duration::from_micros(200)),
            &mut clock,
            &mut collector,
        )
        .expect("the cycle completes");
        assert_eq!(report.steps, 2);
        assert!(report.cycle_completed);
    }

    #[test]
    fn a_stalled_clock_still_has_a_step_limit() {
        let (mut clock, mut collector) = fixture(0);
        let report = schedule(
            GcBudget(Duration::from_micros(200)),
            &mut clock,
            &mut collector,
        )
        .expect("the step limit terminates the loop");
        assert_eq!(report.steps, MAX_STEPS);
        assert_eq!(report.elapsed, Duration::ZERO);
    }

    #[test]
    fn a_regressing_clock_stops_without_underflow_or_more_steps() {
        let (mut clock, mut collector) = fixture(1);
        collector.regress = true;
        let report = schedule(
            GcBudget(Duration::from_micros(200)),
            &mut clock,
            &mut collector,
        )
        .expect("a clock regression terminates scheduling");
        assert_eq!(report.steps, 1);
        assert!(report.clock_regressed);
        assert_eq!(report.elapsed, Duration::ZERO);
    }

    #[test]
    fn collection_errors_return_without_retrying_or_finishing_the_cycle() {
        let (mut clock, mut collector) = fixture(1);
        collector.fail_at = Some(2);
        let result = schedule(
            GcBudget(Duration::from_micros(200)),
            &mut clock,
            &mut collector,
        );
        assert!(result.is_err());
        assert_eq!(collector.steps, 2);
    }

    #[test]
    fn an_unfinished_cycle_continues_on_the_next_frame_without_forcing_completion() {
        let (mut clock, mut collector) = fixture(100);
        collector.complete_at = Some(5);
        for expected_steps in [2, 2, 1] {
            let report = schedule(
                GcBudget(Duration::from_micros(200)),
                &mut clock,
                &mut collector,
            )
            .expect("a later frame resumes proactive work");
            assert_eq!(report.steps, expected_steps);
        }
        assert_eq!(collector.steps, 5);
    }

    #[test]
    fn proactive_steps_keep_automatic_collection_and_suspended_coroutines_live() {
        let lua = Lua::new();
        let function = lua
            .load("local value = { answer = 42 }; coroutine.yield(value); return value.answer")
            .into_function()
            .expect("the coroutine compiles");
        let thread = lua
            .create_thread(function)
            .expect("the coroutine is created");
        let value: mlua::Table = thread
            .resume(())
            .expect("the coroutine yields its live table");
        let (mut clock, _) = fixture(0);
        let report = schedule(GcBudget::default(), &mut clock, &mut LuauCollector(&lua))
            .expect("proactive collection succeeds on a suspended coroutine");
        assert!(report.steps > 0);
        assert!(lua.gc_is_running());
        assert_eq!(value.get::<u32>("answer").expect("the table is live"), 42);
        assert_eq!(thread.resume::<u32>(()).expect("the coroutine resumes"), 42);
    }

    proptest! {
        #[test]
        fn positive_step_cost_never_starts_work_at_or_after_the_budget(
            budget_us in 1_u64..=1_000,
            cost_us in 1_u64..=2_000,
        ) {
            let (mut clock, mut collector) = fixture(cost_us);
            let report = schedule(GcBudget(Duration::from_micros(budget_us)), &mut clock, &mut collector)
                .expect("bounded scheduling succeeds");
            prop_assert!(report.steps > 0);
            prop_assert!(report.steps <= MAX_STEPS);
            prop_assert!(u64::from(report.steps - 1) * cost_us < budget_us);
            prop_assert!(report.elapsed >= Duration::from_micros(budget_us) || report.steps == MAX_STEPS);
        }
    }
}
