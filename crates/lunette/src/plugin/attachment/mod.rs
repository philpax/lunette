//! Lua binding for plugin contracts, runtime graphs, and lifecycle callbacks.
//!
//! A Lua state shares one contract epoch across independent runtime graphs.
//! Instances, services, effects, and configuration belong to one runtime.
//! Plugin callbacks are synchronous and cannot yield.

mod context;
mod error;
mod lifecycle;
mod snapshot;
mod state;
mod types;

use std::{
    cell::RefCell,
    rc::{Rc, Weak},
    sync::Arc,
};

use mlua::{Lua, Value};

pub(crate) use self::snapshot::records as snapshot_records;
pub use self::{
    error::{
        AttachmentError, ContextOperation, ContextReason, FailureCause, FailurePhase,
        PluginFailure, PluginLabel, ProvisionError,
    },
    snapshot::{PluginAuthority, PluginEffectState},
    state::Reporter,
    types::{
        PluginAcquire, PluginContext, PluginDefinition, PluginEffect, PluginInit, PluginInstance,
        PluginRuntime, PluginState, Unknown,
    },
};
use self::{
    lifecycle::close_runtime,
    state::{AttachmentHost, DeclarationField, DefinitionData, RuntimeState},
};
pub use crate::plugin::contracts::PluginContractToken;
use crate::plugin::contracts::{ContractName, ContractRegistry, ValidatedDeclaration};

/// Installs the state-bound contract registry without changing its epoch.
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

/// Shuts down every runtime attached to this Lua state, attempting every
/// cleanup, and starts a new contract epoch with a fresh registry.
///
/// Failures are returned to the caller. The listeners belong to the configuration being torn down.
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
    let mut state = host.borrow_mut();
    state.runtimes.clear();
    state.registry = ContractRegistry::new();
    match state.epoch.checked_add(1) {
        Some(epoch) => state.epoch = epoch,
        None => errors.push(AttachmentError::EpochExhausted),
    }
    errors
}

/// Reports whether a plugin callback is running in this Lua state.
#[must_use]
pub fn callback_active(lua: &Lua) -> bool {
    host_inner(lua).is_some_and(|host| host.borrow().callback_depth != 0)
}

/// Declares a qualified contract identity in this state's current epoch.
pub fn contract(lua: &Lua, (name, schema): (String, u64)) -> mlua::Result<PluginContractToken> {
    let host = require_host(lua)?;
    let contract_name = ContractName::from_qualified(name).map_err(AttachmentError::Contract)?;
    let registry = host.borrow().registry.clone();
    Ok(registry
        .declare(contract_name, schema)
        .map_err(AttachmentError::Contract)?)
}

/// The arguments of [`define`].
pub type DefineArguments = (Unknown, Unknown, PluginInit, Option<String>);

/// Defines a reusable plugin from exact required/provided token records.
/// Without a name, the definition is named for where its initializer is defined.
pub fn define(
    lua: &Lua,
    (required, provided, init, name): DefineArguments,
) -> mlua::Result<PluginDefinition> {
    let host = require_host(lua)?;
    let (required, provided, epoch) = {
        let host_ref = host.borrow();
        (
            declaration_fields(&validate_declaration(&host_ref, required.0)?),
            declaration_fields(&validate_declaration(&host_ref, provided.0)?),
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

fn validate_declaration(
    host: &AttachmentHost,
    declaration: Value,
) -> Result<ValidatedDeclaration, AttachmentError> {
    host.registry
        .validate_declaration(declaration)
        .map_err(AttachmentError::Contract)
}

fn declaration_fields(declaration: &ValidatedDeclaration) -> Vec<DeclarationField> {
    declaration
        .iter()
        .map(|(field, key)| DeclarationField {
            field: field.to_owned(),
            key: key.clone(),
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
