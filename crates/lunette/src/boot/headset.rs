//! Reports an XR startup request that reaches the desktop simulator instead.

use lunette_lovr::raw;
use mlua::{FromLua, Lua, Table, Value};
use tracing::warn;

pub(super) fn report_fallback(
    lua: &Lua,
    headset_loaded: bool,
    has_session: bool,
) -> mlua::Result<()> {
    if !headset_loaded || has_session || !requested_xr(lua)? {
        return Ok(());
    }

    warn!(
        "headset: the configuration requested XR, but no XR session started; \
         running in the desktop simulator instead. Possible causes include an \
         unavailable runtime or headset, a runtime that refused the session, \
         or insufficient GPU memory. lunette cannot determine the cause"
    );
    Ok(())
}

fn requested_xr(lua: &Lua) -> mlua::Result<bool> {
    // SAFETY: `exec_raw` protects the registry read and restores the stack. `luax_pushconf`
    // only pushes the resolved configuration; it does not initialize any native module.
    let configuration: Option<Table> =
        unsafe { lua.exec_raw((), |state| raw::luax_pushconf(state.cast()))? };
    let Some(configuration) = configuration else {
        return Ok(false);
    };

    let modules: Table = configuration.get("modules")?;
    if !truthy(modules.get("headset")?) {
        return Ok(false);
    }

    match configuration.get("headset")? {
        Value::Nil | Value::Boolean(false) => Ok(true),
        value => {
            let headset = Table::from_lua(value, lua)?;
            // These are boot.lua's connection and start conditions, not the module parser's defaults.
            Ok(truthy(headset.get("connect")?) && truthy(headset.get("start")?))
        }
    }
}

fn truthy(value: Value) -> bool {
    !matches!(value, Value::Nil | Value::Boolean(false))
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        reason = "a failed expectation is how a test reports a failure; the ban is on production code"
    )]

    use mlua::Table;
    use pretty_assertions::assert_eq;

    use super::*;
    use crate::log_capture::Logs;

    fn configured(configuration: &str) -> Lua {
        let lua = Lua::new();
        let config: Table = lua
            .load(configuration)
            .eval()
            .expect("the resolved configuration");
        lua.set_named_registry_value("_lovrconf", config)
            .expect("LÖVR's resolved configuration registry entry");
        lua
    }

    const XR: &str =
        "return { modules = { headset = true }, headset = { connect = true, start = true } }";

    #[test]
    fn a_requested_headset_without_a_session_reports_the_simulator_and_possible_causes() {
        let lua = configured(XR);
        let logs = Logs::capture(|| {
            report_fallback(&lua, true, false).expect("the startup report");
        });

        assert_eq!(logs.mentioning("WARN"), 1);
        assert_eq!(logs.mentioning("requested XR"), 1);
        assert_eq!(logs.mentioning("no XR session started"), 1);
        assert_eq!(logs.mentioning("desktop simulator"), 1);
        assert_eq!(logs.mentioning("unavailable runtime or headset"), 1);
        assert_eq!(logs.mentioning("runtime that refused"), 1);
        assert_eq!(logs.mentioning("insufficient GPU memory"), 1);
        assert_eq!(logs.mentioning("cannot determine the cause"), 1);
    }

    #[test]
    fn inherited_configuration_fields_can_request_xr() {
        for configuration in [
            r#"
                return {
                    modules = { headset = true },
                    headset = setmetatable({}, { __index = { connect = true, start = true } }),
                }
            "#,
            r#"
                return setmetatable({}, { __index = {
                    modules = { headset = true },
                    headset = { connect = true, start = true },
                } })
            "#,
        ] {
            let lua = configured(configuration);
            let logs = Logs::capture(|| {
                report_fallback(&lua, true, false).expect("the startup report");
            });
            assert_eq!(logs.mentioning("desktop simulator"), 1, "{configuration}");
        }
    }

    #[test]
    fn inherited_configuration_fields_can_select_intentional_simulation() {
        for configuration in [
            r#"
                return setmetatable({ modules = { headset = true } }, { __index = {
                    headset = { connect = false, start = true },
                } })
            "#,
            r#"
                return {
                    modules = { headset = true },
                    headset = setmetatable({ start = true }, { __index = { connect = false } }),
                }
            "#,
        ] {
            let lua = configured(configuration);
            let logs = Logs::capture(|| {
                report_fallback(&lua, true, false).expect("the startup report");
            });
            assert_eq!(logs.mentioning("headset:"), 0, "{configuration}");
        }
    }

    #[test]
    fn a_configuration_metamethod_error_is_returned_without_reporting_a_fallback() {
        let lua = configured(
            r#"
            return setmetatable({}, { __index = function()
                error('configuration lookup failed')
            end })
        "#,
        );
        let logs = Logs::capture(|| {
            let error = report_fallback(&lua, true, false)
                .expect_err("the configuration lookup raises an error");
            assert!(error.to_string().contains("configuration lookup failed"));
        });
        assert_eq!(logs.mentioning("headset:"), 0);
    }

    #[test]
    fn a_started_xr_session_logs_nothing_new() {
        let lua = configured(XR);
        let logs = Logs::capture(|| {
            report_fallback(&lua, true, true).expect("the startup report");
        });
        assert_eq!(logs.mentioning("headset:"), 0);
    }

    #[test]
    fn intentional_simulation_and_deferred_startup_do_not_report_a_fallback() {
        for configuration in [
            "return { modules = { headset = false }, headset = { connect = true, start = true } }",
            "return { modules = {}, headset = { connect = true, start = true } }",
            "return { modules = { headset = true }, headset = { connect = false, start = true } }",
            "return { modules = { headset = true }, headset = { connect = true, start = false } }",
            "return { modules = { headset = true }, headset = {} }",
        ] {
            let lua = configured(configuration);
            let logs = Logs::capture(|| {
                report_fallback(&lua, true, false).expect("the startup report");
            });
            assert_eq!(logs.mentioning("headset:"), 0, "{configuration}");
        }
    }

    #[test]
    fn an_unloaded_headset_module_does_not_claim_the_simulator_is_running() {
        let lua = configured(XR);
        let logs = Logs::capture(|| {
            report_fallback(&lua, false, false).expect("the startup report");
        });
        assert_eq!(logs.mentioning("headset:"), 0);
    }

    #[test]
    fn an_absent_headset_configuration_uses_lovrs_startup_defaults() {
        for configuration in [
            "return { modules = { headset = true } }",
            "return { modules = { headset = true }, headset = false }",
        ] {
            let lua = configured(configuration);
            let logs = Logs::capture(|| {
                report_fallback(&lua, true, false).expect("the startup report");
            });
            assert_eq!(logs.mentioning("desktop simulator"), 1, "{configuration}");
        }
    }

    #[test]
    fn a_failure_before_configuration_is_resolved_does_not_report_a_fallback() {
        let lua = Lua::new();
        let logs = Logs::capture(|| {
            report_fallback(&lua, true, false).expect("the startup report");
        });
        assert_eq!(logs.mentioning("headset:"), 0);
    }
}
