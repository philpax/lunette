//! The attachment's records: the per-state host, definitions, runtimes, and
//! instances, and the guards that keep their counters balanced.

use std::{
    cell::RefCell,
    collections::{BTreeMap, HashMap},
    rc::{Rc, Weak},
    sync::Arc,
};

use mlua::{Function, Lua, Table, Value};

use crate::plugin::{
    attachment::error::{AttachmentError, PluginFailure, PluginLabel},
    contracts::{ContractId, ContractRegistry},
    graph::{ActivationId, ContractKey, Graph, InstanceId},
};

/// Receives plugin failures that happen while lifecycle work drains. Without
/// one, a failure is only logged.
pub type Reporter = Rc<dyn Fn(&Lua, &PluginFailure)>;

pub(super) struct AttachmentHost {
    pub(super) registry: ContractRegistry,
    pub(super) contract_keys: HashMap<ContractId, ContractKey>,
    pub(super) runtimes: Vec<Rc<RefCell<RuntimeState>>>,
    pub(super) definitions: Vec<Weak<DefinitionData>>,
    pub(super) callback_depth: usize,
    /// Advances whenever shutdown retires the runtimes, so a definition from
    /// an earlier epoch is recognised and rejected.
    pub(super) epoch: u64,
    pub(super) reporter: Option<Reporter>,
    /// Capability wrappers bound in retired epochs, as the keys of a Lua
    /// table with weak keys. A wrapper stays recognisable while anything can
    /// still pass it, and the table does not keep it alive.
    pub(super) retired_wrappers: Option<Table>,
}

impl AttachmentHost {
    pub(super) fn new() -> Self {
        Self {
            registry: ContractRegistry::new(),
            contract_keys: HashMap::new(),
            runtimes: Vec::new(),
            definitions: Vec::new(),
            callback_depth: 0,
            epoch: 0,
            reporter: None,
            retired_wrappers: None,
        }
    }
}

impl AttachmentHost {
    /// Reports whether the wrapper in `field` of `declaration` was bound in a
    /// retired epoch.
    pub(super) fn holds_retired_wrapper(&self, declaration: &Table, field: &str) -> bool {
        let Some(retired) = &self.retired_wrappers else {
            return false;
        };
        let Ok(Value::Table(wrapper)) = declaration.raw_get::<Value>(field) else {
            return false;
        };
        retired
            .raw_get::<Option<bool>>(wrapper)
            .ok()
            .flatten()
            .unwrap_or(false)
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
    /// Set by host shutdown, which returns failures rather than reporting
    /// them to listeners that belong to the configuration being torn down.
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

// Retained graph allocations preserve dependency reads, not permission to acquire during cleanup.
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
    pub(super) next_effect: u64,
    pub(super) service: Option<Value>,
    pub(super) last_diagnostic: Option<String>,
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
        // A borrow held while unwinding must not turn a panic into an abort.
        if let Ok(mut host) = self.host.try_borrow_mut() {
            host.callback_depth = host.callback_depth.saturating_sub(1);
        }
    }
}

/// Marks a runtime as draining for as long as it is held, restoring the
/// previous mark when dropped, including when the work unwinds.
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
