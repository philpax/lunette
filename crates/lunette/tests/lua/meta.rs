//! Tests runner path classification and failure reporting with in-memory modules.

use std::path::Path;

use libtest_mimic::{Failed, Trial};
use mlua::{Lua, Table};

use crate::{
    discover::{self, Kind, Source},
    run,
    state::{self, Roots},
};

pub fn trials(roots: &Roots) -> Vec<Trial> {
    let mut trials = vec![
        Trial::test("runner::test_files_are_directly_inside_tests", || {
            classification()
        }),
        Trial::test("runner::a_test_file_is_required_under_its_root", || {
            naming()
        }),
    ];
    for (name, outcome) in OUTCOMES {
        let roots = roots.clone();
        trials.push(Trial::test(format!("runner::{name}"), move || {
            outcome_of(&roots, &outcome)
        }));
    }
    trials
}

fn classification() -> Result<(), Failed> {
    let cases = [
        ("lunette-plugins/pacing/tests/pacer.luau", Kind::Test),
        ("testing/tests/expect.luau", Kind::Test),
        ("plugins/demo-terminal/tests/startup.luau", Kind::Test),
        ("plugins/demo-terminal/tests/nested/case.luau", Kind::Stray),
        (
            "plugins/demo-terminal/tests/support/fixture.luau",
            Kind::Support,
        ),
        (
            "lunette-plugins/arrangement/tests/support/fixture.luau",
            Kind::Support,
        ),
        (
            "lunette-plugins/arrangement/tests/support/deeper/fixture.luau",
            Kind::Support,
        ),
        (
            "lunette-plugins/arrangement/tests/nested/case.luau",
            Kind::Stray,
        ),
        ("lunette-plugins/arrangement/tests/notes.txt", Kind::Stray),
        ("lunette-plugins/pacing/pacer.luau", Kind::Other),
        ("lunette-plugins/pacing/init.luau", Kind::Other),
    ];
    for (path, wanted) in cases {
        let found = discover::classify(Path::new(path));
        if found != wanted {
            return Err(format!("{path}: wanted {wanted:?}, got {found:?}").into());
        }
    }
    Ok(())
}

fn naming() -> Result<(), Failed> {
    let file = discover::test_file(
        Path::new("lunette-plugins/pacing/tests/pacer.luau"),
        Source::Library,
    )
    .map_err(|error| error.to_string())?;
    if file.name != "lunette-plugins/pacing/tests/pacer"
        || file.module != "@lunette-plugins/pacing/tests/pacer"
    {
        return Err(format!("{file:?}").into());
    }
    if discover::test_file(Path::new("elsewhere/tests/case.luau"), Source::Library).is_ok() {
        return Err("a test file outside every module root was named".into());
    }
    let development = discover::test_file(
        Path::new("plugins/demo-terminal/tests/startup.luau"),
        Source::Development,
    )
    .map_err(|error| error.to_string())?;
    if development.name != "dev/plugins/demo-terminal/tests/startup"
        || development.module != "plugins/demo-terminal/tests/startup"
        || development.source != Source::Development
    {
        return Err(format!("{development:?}").into());
    }
    Ok(())
}

/// A test module's source, and the substrings its failure has to contain, or
/// none when it has to pass.
struct Outcome {
    source: &'static str,
    failure: Option<&'static [&'static str]>,
    /// A global the source counts its cases into, and the count the run has
    /// to leave, so a run that stopped early is noticed.
    ran: Option<i64>,
}

const OUTCOMES: [(&str, Outcome); 6] = [
    (
        "a_file_returning_no_suite_fails",
        Outcome {
            source: "local _ = 1",
            failure: Some(&["did not return a test suite", "boolean"]),
            ran: None,
        },
    ),
    (
        "a_file_with_no_cases_fails",
        Outcome {
            source: "return require('@testing').suite()",
            failure: Some(&["defines no cases"]),
            ran: None,
        },
    ),
    (
        "a_raising_case_fails_and_the_cases_after_it_run",
        Outcome {
            source: "
                local test = require('@testing').suite()
                RAN = 0
                test('first', function() RAN += 1 end)
                test('raises', function() RAN += 1; error 'meta: deliberate' end)
                test('last', function() RAN += 1 end)
                return test",
            failure: Some(&["FAIL raises", "meta: deliberate", "1 of 3 cases failed"]),
            ran: Some(3),
        },
    ),
    (
        "a_report_no_case_took_fails_that_case",
        Outcome {
            source: "
                local testing = require '@testing'
                local plugin = require '@lunette-plugin'
                local test = testing.suite()
                local function fail()
                  local runtime = plugin.runtime()
                  runtime:use(plugin.define { name = 'meta', init = function() error 'meta: init' end }, {}):enable()
                  runtime:close()
                end
                test('takes', function()
                  fail()
                  local reports = testing.takeReports()
                  assert(#reports == 1 and reports[1]:find('meta: init', 1, true), 'the report is taken')
                end)
                test('leaves', fail)
                return test",
            failure: Some(&[
                "FAIL leaves",
                "did not take",
                "meta: init",
                "1 of 2 cases failed",
            ]),
            ran: None,
        },
    ),
    (
        "a_runtime_left_open_is_shut_down_after_the_last_case",
        Outcome {
            source: "
                local testing = require '@testing'
                local plugin = require '@lunette-plugin'
                local test = testing.suite()
                test('leaves a failing cleanup', function()
                  local runtime = plugin.runtime()
                  runtime:use(plugin.define { name = 'meta', init = function(context)
                    context:effect(function() return function() error 'meta: cleanup' end end)
                  end }, {}):enable()
                end)
                return test",
            failure: Some(&["the plugin shutdown after the last case", "meta: cleanup"]),
            ran: None,
        },
    ),
    (
        "a_file_whose_cases_pass_passes",
        Outcome {
            source: "
                local testing = require '@testing'
                local test = testing.suite()
                RAN = 0
                test('one', function() RAN += 1; testing.expect.equal(1, 1) end)
                test('two', function() RAN += 1 end)
                return test",
            failure: None,
            ran: Some(2),
        },
    ),
];

const MODULE: &str = "meta/case";

fn outcome_of(roots: &Roots, outcome: &Outcome) -> Result<(), Failed> {
    let lua = state::new(roots).map_err(|error| error.to_string())?;
    preload(&lua, outcome.source).map_err(|error| error.to_string())?;
    let result = run::module(&lua, MODULE);
    match (outcome.failure, &result) {
        (None, Ok(())) => {}
        (None, Err(message)) => return Err(format!("the file failed: {message}").into()),
        (Some(_), Ok(())) => return Err("the file passed".into()),
        (Some(wanted), Err(message)) => {
            for part in wanted {
                if !message.contains(part) {
                    return Err(format!("the failure lacks '{part}': {message}").into());
                }
            }
        }
    }
    if let Some(wanted) = outcome.ran {
        let ran: i64 = lua
            .globals()
            .get("RAN")
            .map_err(|error| error.to_string())?;
        if ran != wanted {
            return Err(format!("{ran} cases ran, wanted {wanted}").into());
        }
    }
    Ok(())
}

fn preload(lua: &Lua, source: &str) -> mlua::Result<()> {
    let package: Table = lua.globals().get("package")?;
    let preload: Table = package.get("preload")?;
    let chunk = lua
        .load(source)
        .set_name(format!("@{MODULE}.luau"))
        .into_function()?;
    preload.set(MODULE, chunk)
}
