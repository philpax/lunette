//! Native mlua attachment bridge for the plugin contract registry and lifecycle graph.
//!
//! The attachment owns only Lua-state data. It does not retain a compositor
//! session. A state owns one contract epoch and can have several independent
//! runtime graphs. Definitions and contract tokens are shared by those graphs;
//! instances, services, effects, and configuration values remain runtime-local.
//!
//! Plugin callbacks are synchronous and must not yield. A failure inside a
//! drain is reported through the installed [`Reporter`] and recorded as the
//! instance's diagnostic; an operation a caller invoked raises its own error.

mod context;
mod error;
mod lifecycle;
mod state;
mod types;

use std::{
    cell::RefCell,
    rc::{Rc, Weak},
    sync::Arc,
};

use mlua::{Lua, UserDataRef, Value};

pub use self::{
    error::{
        AttachmentError, ContextOperation, ContextReason, FailureCause, FailurePhase,
        PluginFailure, PluginLabel, ProvisionError,
    },
    state::Reporter,
    types::{
        PluginAcquire, PluginContext, PluginContractToken, PluginDefinition, PluginEffect,
        PluginInit, PluginInstance, PluginRuntime, PluginState, Unknown,
    },
};
use self::{
    lifecycle::close_runtime,
    state::{AttachmentHost, DeclarationField, DefinitionData, RuntimeState},
};
use crate::plugin::{
    contracts::{ContractName, ContractRegistry, ValidatedDeclaration},
    graph::ContractKey,
};

/// Installs the state-bound contract registry if it is not already present.
///
/// Calling this more than once is harmless and does not replace the current
/// contract epoch.
pub fn install(lua: &Lua) -> Result<(), AttachmentError> {
    if lua.app_data_ref::<Rc<RefCell<AttachmentHost>>>().is_none() {
        lua.set_app_data(Rc::new(RefCell::new(AttachmentHost::new())));
    }
    Ok(())
}

/// Sets where plugin failures that happen while lifecycle work drains are
/// reported. The reporter survives epoch resets.
pub fn set_reporter(lua: &Lua, reporter: Reporter) -> Result<(), AttachmentError> {
    install(lua)?;
    require_host(lua)?.borrow_mut().reporter = Some(reporter);
    Ok(())
}

/// Shuts down every runtime attached to this Lua state.
///
/// Every runtime and every cleanup callback is attempted. The failures of
/// this shutdown are returned rather than reported to listeners, because the
/// listeners belong to the configuration being torn down. Failures reported
/// before shutdown are not returned again.
#[must_use]
pub fn shutdown_all(lua: &Lua) -> Vec<AttachmentError> {
    let Some(host) = host_inner(lua) else {
        return Vec::new();
    };
    if callback_active(lua) {
        return vec![AttachmentError::ShutdownInCallback];
    }
    let runtimes = host.borrow().runtimes.clone();
    let mut errors = Vec::new();
    for runtime in &runtimes {
        runtime.borrow_mut().collect_failures = true;
        if let Err(error) = close_runtime(lua, runtime) {
            errors.push(error);
        }
        let mut state = runtime.borrow_mut();
        errors.append(&mut state.collected);
        state.collect_failures = false;
    }
    clear_host_references(&host);
    {
        let mut state = host.borrow_mut();
        state.runtimes.clear();
        state.registry = ContractRegistry::new();
        state.contract_keys.clear();
        state.epoch = state.epoch.wrapping_add(1);
    }
    errors
}

/// Retires the current contract epoch after shutting down its runtimes.
///
/// # Errors
///
/// The new epoch starts even when shutdown reports failures; the error then
/// lists them. An error is also returned if the registry cannot advance its
/// epoch.
pub fn reset_epoch(lua: &Lua) -> Result<(), AttachmentError> {
    let failures = shutdown_all(lua);
    install(lua)?;
    let host = require_host(lua)?;
    host.borrow()
        .registry
        .retire_epoch()
        .map_err(AttachmentError::Contract)?;
    if failures.is_empty() {
        Ok(())
    } else {
        Err(AttachmentError::Shutdown(failures))
    }
}

/// Reports whether execution is currently inside a plugin callback.
#[must_use]
pub fn callback_active(lua: &Lua) -> bool {
    host_inner(lua).is_some_and(|host| host.borrow().callback_depth != 0)
}

/// Declares a qualified contract identity in this state's current epoch.
pub fn contract(lua: &Lua, (name, schema): (String, u64)) -> mlua::Result<PluginContractToken> {
    let host = require_host(lua)?;
    let contract_name = ContractName::from_qualified(name).map_err(AttachmentError::Contract)?;
    let key_name = contract_name.qualified();
    let schema_u32 = u32::try_from(schema).map_err(|_| AttachmentError::SchemaRange { schema })?;
    let registry = host.borrow().registry.clone();
    let token = registry
        .declare(contract_name, schema)
        .map_err(AttachmentError::Contract)?;
    let id = registry
        .validate_token(&token)
        .map_err(AttachmentError::Contract)?;
    host.borrow_mut()
        .contract_keys
        .insert(id, ContractKey::new(key_name, schema_u32));
    Ok(token)
}

/// Binds one erased native wrapper to one contract token.
pub fn bind(
    lua: &Lua,
    token: UserDataRef<PluginContractToken>,
    wrapper: Unknown,
) -> mlua::Result<()> {
    let host = require_host(lua)?;
    let table = match wrapper.0 {
        Value::Table(table) => table,
        other => {
            return Err(AttachmentError::WrapperNotTable {
                found: other.type_name(),
            }
            .into());
        }
    };
    let registry = host.borrow().registry.clone();
    Ok(registry
        .bind_token(&token, &table)
        .map_err(AttachmentError::Contract)?)
}

/// The arguments of [`define`]: required and provided declarations, the
/// initializer, and an optional name.
pub type DefineArguments = (Unknown, Unknown, PluginInit, Option<String>);

/// Defines a reusable plugin from exact required/provided token records.
///
/// The optional name labels the definition in logs, reports, and
/// diagnostics. Without one, the definition is named for where its
/// initializer is defined.
pub fn define(
    lua: &Lua,
    (required, provided, init, name): DefineArguments,
) -> mlua::Result<PluginDefinition> {
    let host = require_host(lua)?;
    let (required, provided, epoch) = {
        let host_ref = host.borrow();
        let required = host_ref
            .registry
            .validate_declaration(required.0)
            .map_err(AttachmentError::Contract)?;
        let provided = host_ref
            .registry
            .validate_declaration(provided.0)
            .map_err(AttachmentError::Contract)?;
        (
            fields_for_declaration(&host_ref, &required)?,
            fields_for_declaration(&host_ref, &provided)?,
            host_ref.epoch,
        )
    };
    let name = name.unwrap_or_else(|| {
        let info = init.0.info();
        match (info.short_src, info.line_defined) {
            (Some(source), Some(line)) => format!("{source}:{line}"),
            (Some(source), None) => source,
            _ => String::from("<anonymous plugin>"),
        }
    });
    let definition = Rc::new(DefinitionData {
        host: Rc::downgrade(&host),
        name: Arc::from(name),
        epoch,
        required,
        provided,
        init: RefCell::new(Some(init.0)),
    });
    {
        let mut host = host.borrow_mut();
        host.definitions.retain(|weak| weak.strong_count() > 0);
        host.definitions.push(Rc::downgrade(&definition));
    }
    Ok(PluginDefinition { data: definition })
}

/// Creates an independent runtime in the current Lua state.
pub fn runtime(lua: &Lua, _: ()) -> mlua::Result<PluginRuntime> {
    let host = require_host(lua)?;
    let state = Rc::new(RefCell::new(RuntimeState::new(Rc::downgrade(&host))));
    {
        let mut host = host.borrow_mut();
        host.runtimes
            .retain(|runtime| runtime.try_borrow().map_or(true, |state| !state.closed));
        host.runtimes.push(Rc::clone(&state));
    }
    Ok(PluginRuntime { state })
}

fn host_inner(lua: &Lua) -> Option<Rc<RefCell<AttachmentHost>>> {
    lua.app_data_ref::<Rc<RefCell<AttachmentHost>>>()
        .map(|host| Rc::clone(&host))
}

fn require_host(lua: &Lua) -> Result<Rc<RefCell<AttachmentHost>>, AttachmentError> {
    host_inner(lua).ok_or(AttachmentError::NotInstalled)
}

fn fields_for_declaration(
    host: &AttachmentHost,
    declaration: &ValidatedDeclaration,
) -> Result<Vec<DeclarationField>, AttachmentError> {
    declaration
        .iter()
        .map(|(field, id)| {
            let key = host
                .contract_keys
                .get(&id)
                .cloned()
                .ok_or(AttachmentError::UnmappedToken)?;
            Ok(DeclarationField {
                field: field.to_owned(),
                key,
            })
        })
        .collect()
}

/// Releases every definition's initializer so escaped definitions do not
/// keep the old epoch's Lua values alive.
fn clear_host_references(host: &Rc<RefCell<AttachmentHost>>) {
    let definitions: Vec<Rc<DefinitionData>> = {
        let mut host = host.borrow_mut();
        let definitions = host.definitions.iter().filter_map(Weak::upgrade).collect();
        host.definitions.clear();
        definitions
    };
    for definition in definitions {
        let callback = definition.init.borrow_mut().take();
        drop(callback);
    }
}
