//! Runs a test file and reports failures.
//!
//! Every case runs in file order, even after an earlier case fails. A case fails when it
//! raises or leaves a plugin failure unreported through `testing.takeReports()`. The file
//! fails when it returns no suite, defines no cases, has a failing case, or reports a plugin
//! shutdown failure.

use std::fmt::Write as _;

use mlua::{Function, Lua, Table, Value};

use crate::{
    discover::{Source, TestFile},
    state::{self, Roots},
};

/// Runs `file` in a fresh state.
pub fn file(roots: &Roots, file: &TestFile) -> Result<(), String> {
    let lua =
        state::new(roots).map_err(|error| format!("the test state could not be built: {error}"))?;
    if file.source == Source::Development {
        state::use_configuration(&lua, roots.repository.join("dev")).map_err(|error| {
            format!("the development configuration could not be selected: {error}")
        })?;
    }
    module(&lua, &file.module)
}

/// Requires the test module `name` in `lua` and runs its suite.
pub fn module(lua: &Lua, name: &str) -> Result<(), String> {
    let suite = load_suite(lua, name)?;
    let cases = suite
        .get::<Table>("cases")
        .map_err(|error| format!("{name}: the suite has no case list: {error}"))?;
    let cases = cases
        .sequence_values::<Table>()
        .collect::<mlua::Result<Vec<_>>>()
        .map_err(|error| format!("{name}: the case list is malformed: {error}"))?;
    if cases.is_empty() {
        return Err(format!("{name} defines no cases"));
    }

    let mut failures = Vec::new();
    for case in &cases {
        let title = case
            .get::<String>("name")
            .unwrap_or_else(|_| "an unnamed case".to_owned());
        if let Err(message) = run_case(lua, case) {
            failures.push((title, message));
        }
    }

    let remaining = state::shutdown(lua);
    if failures.is_empty() && remaining.is_empty() {
        return Ok(());
    }
    let mut report = String::new();
    for (title, message) in &failures {
        let _ = writeln!(report, "FAIL {title}\n  {}", message.replace('\n', "\n  "));
    }
    if !remaining.is_empty() {
        let _ = writeln!(
            report,
            "FAIL the plugin shutdown after the last case\n  {}",
            remaining.join("\n  ")
        );
    }
    let _ = write!(
        report,
        "{} of {} case{} failed",
        failures.len(),
        cases.len(),
        if cases.len() == 1 { "" } else { "s" }
    );
    Err(report)
}

fn load_suite(lua: &Lua, name: &str) -> Result<Table, String> {
    let require: Function = lua
        .globals()
        .get("require")
        .map_err(|error| format!("the state has no require: {error}"))?;
    let returned: Value = require
        .call(name)
        .map_err(|error| format!("{name} could not be loaded: {error}"))?;
    let suite: Table = require
        .call::<Table>("@testing/suite")
        .map_err(|error| format!("@testing/suite could not be loaded: {error}"))?;
    let is_suite: Function = suite
        .get("isSuite")
        .map_err(|error| format!("@testing/suite has no isSuite: {error}"))?;
    let accepted = is_suite
        .call::<bool>(returned.clone())
        .map_err(|error| format!("@testing/suite isSuite raised: {error}"))?;
    match returned {
        Value::Table(table) if accepted => Ok(table),
        other => Err(format!(
            "{name} did not return a test suite; it returned a {}",
            other.type_name()
        )),
    }
}

fn run_case(lua: &Lua, case: &Table) -> Result<(), String> {
    let run: Function = case
        .get("run")
        .map_err(|error| format!("the case has no function: {error}"))?;
    let outcome = run
        .call::<()>(())
        .map_err(|error| error.to_string())
        .and_then(|()| drain_temporaries(lua));
    let reports = state::take_reports(lua);
    match (outcome, reports.is_empty()) {
        (Ok(()), true) => Ok(()),
        (Ok(()), false) => Err(untaken(&reports)),
        (Err(message), true) => Err(message),
        (Err(message), false) => Err(format!("{message}\n{}", untaken(&reports))),
    }
}

fn untaken(reports: &[String]) -> String {
    format!(
        "plugin failures were reported that the case did not take:\n  {}",
        reports.join("\n  ")
    )
}

/// LÖVR hands out temporary math objects from a pool it drains at each frame
/// boundary. A test never reaches one, so the pool is drained between cases.
fn drain_temporaries(lua: &Lua) -> Result<(), String> {
    // A case may have replaced `lovr` or its math module with a fake of its
    // own, which has no pool to drain.
    let drain = lua
        .globals()
        .get::<Option<Table>>("lovr")
        .and_then(|lovr| lovr.map_or(Ok(None), |lovr| lovr.get::<Option<Table>>("math")))
        .and_then(|math| math.map_or(Ok(None), |math| math.get::<Option<Function>>("drain")))
        .map_err(|error| format!("lovr.math could not be reached after the case: {error}"))?;
    match drain {
        Some(drain) => drain
            .call::<()>(())
            .map_err(|error| format!("lovr.math.drain raised after the case: {error}")),
        None => Ok(()),
    }
}
