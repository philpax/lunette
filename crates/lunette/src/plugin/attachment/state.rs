//! State owned by the plugin attachment and guards for callback and drain state.

use std::{
    cell::RefCell,
    collections::BTreeMap,
    rc::{Rc, Weak},
    sync::Arc,
};

use mlua::{Function, Lua, Value};

use crate::plugin::{
    attachment::{
        error::{AttachmentError, PluginFailure, PluginLabel},
        snapshot::PluginEffectState,
    },
    contracts::ContractRegistry,
    graph::{ActivationId, ContractKey, Graph, InstanceId},
};

/// Receives plugin failures that happen while lifecycle work drains. Without
/// one, a failure is only logged.
pub type Reporter = Rc<dyn Fn(&Lua, &PluginFailure)>;

pub(super) struct AttachmentHost {
    pub(super) registry: ContractRegistry,
    pub(super) runtimes: Vec<Rc<RefCell<RuntimeState>>>,
    pub(super) definitions: Vec<Weak<DefinitionData>>,
    pub(super) callback_depth: usize,
    /// Advances whenever shutdown retires the runtimes, so a definition from
    /// an earlier epoch is recognised and rejected.
    pub(super) epoch: u64,
    pub(super) reporter: Option<Reporter>,
}

impl AttachmentHost {
    pub(super) fn new() -> Self {
        Self {
            registry: ContractRegistry::new(),
            runtimes: Vec::new(),
            definitions: Vec::new(),
            callback_depth: 0,
            epoch: 0,
            reporter: None,
        }
    }
}

pub(super) struct DefinitionData {
    pub(super) host: Weak<RefCell<AttachmentHost>>,
    pub(super) name: Arc<str>,
    pub(super) epoch: u64,
    pub(super) required: Vec<DeclarationField>,
    pub(super) provided: Vec<DeclarationField>,
    pub(super) init: RefCell<Option<Function>>,
}

#[derive(Clone)]
pub(super) struct DeclarationField {
    pub(super) field: String,
    pub(super) key: ContractKey,
}

pub(super) struct RuntimeState {
    pub(super) host: Weak<RefCell<AttachmentHost>>,
    pub(super) graph: Graph,
    pub(super) instances: BTreeMap<InstanceId, InstanceState>,
    pub(super) draining: bool,
    pub(super) closing: bool,
    pub(super) closed: bool,
    /// Host shutdown collects failures because the configuration's listeners are being removed.
    pub(super) collect_failures: bool,
    pub(super) collected: Vec<AttachmentError>,
}

impl RuntimeState {
    pub(super) fn new(host: Weak<RefCell<AttachmentHost>>) -> Self {
        Self {
            host,
            graph: Graph::new(),
            instances: BTreeMap::new(),
            draining: false,
            closing: false,
            closed: false,
            collect_failures: false,
            collected: Vec::new(),
        }
    }

    /// Names an instance by its definition, or by identity alone once the
    /// attachment no longer holds it.
    pub(super) fn label(&self, instance: InstanceId) -> PluginLabel {
        PluginLabel {
            name: self.instances.get(&instance).map_or_else(
                || Arc::from("<removed plugin>"),
                |state| Arc::clone(&state.definition.name),
            ),
            instance,
        }
    }
}

// Live allocations retain service bindings during cleanup without resource authority.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum ActivationAuthority {
    Detached,
    Resources(ActivationId),
    Cleanup(ActivationId),
}

impl ActivationAuthority {
    pub(super) fn permits_resources(self, activation: ActivationId) -> bool {
        self == Self::Resources(activation)
    }
}

pub(super) struct InstanceState {
    pub(super) authority: ActivationAuthority,
    pub(super) definition: Rc<DefinitionData>,
    pub(super) config: Value,
    /// Registered inverses in acquisition order. Disposed entries are removed.
    pub(super) effects: BTreeMap<u64, Function>,
    /// Detached status for inverses registered by the current or most recently ended activation.
    pub(super) effect_states: BTreeMap<u64, EffectState>,
    pub(super) next_effect: u64,
    pub(super) service: Option<Value>,
    pub(super) last_diagnostic: Option<String>,
    pub(super) last_failure: Option<String>,
}

pub(super) struct EffectState {
    pub(super) activation: ActivationId,
    pub(super) state: PluginEffectState,
}

impl InstanceState {
    pub(super) fn mark_effect(&mut self, ordinal: u64, state: PluginEffectState) {
        if let Some(effect) = self.effect_states.get_mut(&ordinal) {
            effect.state = state;
        }
    }
}

/// Counts a plugin callback for [`crate::plugin::attachment::callback_active`]
/// for as long as it is held, including when the callback unwinds.
pub(super) struct CallbackGuard {
    host: Rc<RefCell<AttachmentHost>>,
}

impl CallbackGuard {
    pub(super) fn enter(host: Rc<RefCell<AttachmentHost>>) -> Self {
        host.borrow_mut().callback_depth += 1;
        Self { host }
    }
}

impl Drop for CallbackGuard {
    fn drop(&mut self) {
        // A failed mutable borrow leaves the counter for the next guard drop.
        if let Ok(mut host) = self.host.try_borrow_mut() {
            host.callback_depth = host.callback_depth.saturating_sub(1);
        }
    }
}

/// Marks a runtime as draining and restores its previous state when dropped.
pub(super) struct DrainGuard {
    runtime: Rc<RefCell<RuntimeState>>,
    previous: bool,
}

impl DrainGuard {
    pub(super) fn enter(runtime: &Rc<RefCell<RuntimeState>>) -> Self {
        let previous = std::mem::replace(&mut runtime.borrow_mut().draining, true);
        Self {
            runtime: Rc::clone(runtime),
            previous,
        }
    }
}

impl Drop for DrainGuard {
    fn drop(&mut self) {
        if let Ok(mut runtime) = self.runtime.try_borrow_mut() {
            runtime.draining = self.previous;
        }
    }
}
