//! Concrete userdata and state records for the plugin attachment.

use std::{
    cell::{Cell, RefCell},
    collections::{BTreeMap, VecDeque},
    rc::{Rc, Weak},
};

use lunette_luau::{Parameter, Type, Typed};
use mlua::{FromLua, Function, IntoLua, Lua, UserData, UserDataMethods, UserDataRef, Value};

use crate::{
    lua::declarations::{MethodSpec, MethodSurface, MethodsDescribed, Receiver},
    plugin::{
        contracts::{ContractId, ContractRegistry, ContractToken},
        graph::{ActivationId, ContractKey, Graph, InstanceId},
    },
};

/// The opaque contract token exposed to Lua.
pub type PluginContractToken = ContractToken;

impl Typed for ContractToken {
    fn luau() -> Type {
        Type::Named("PluginContractToken")
    }
}

/// An explicitly erased Lua value used by the plugin API.
#[derive(Clone, Debug)]
pub struct Unknown(pub(super) Value);

impl FromLua for Unknown {
    fn from_lua(value: Value, _: &Lua) -> mlua::Result<Self> {
        Ok(Self(value))
    }
}

impl IntoLua for Unknown {
    fn into_lua(self, _: &Lua) -> mlua::Result<Value> {
        Ok(self.0)
    }
}

impl Typed for Unknown {
    fn luau() -> Type {
        Type::Named("unknown")
    }
}

/// The callback accepted by the definition constructor.
#[derive(Clone, Debug)]
pub struct PluginInit(pub(super) Function);

impl FromLua for PluginInit {
    fn from_lua(value: Value, lua: &Lua) -> mlua::Result<Self> {
        Function::from_lua(value, lua).map(Self)
    }
}

impl Typed for PluginInit {
    fn luau() -> Type {
        Type::Function {
            receiver: None,
            parameters: vec![
                Parameter {
                    name: "context",
                    ty: Type::Named("PluginContext"),
                },
                Parameter {
                    name: "config",
                    ty: Type::Named("unknown"),
                },
            ],
            returns: Box::new(Type::Named("unknown")),
        }
    }
}

/// A non-yielding resource acquisition callback.
#[derive(Clone, Debug)]
pub struct PluginAcquire(pub(super) Function);

impl FromLua for PluginAcquire {
    fn from_lua(value: Value, lua: &Lua) -> mlua::Result<Self> {
        Function::from_lua(value, lua).map(Self)
    }
}

impl Typed for PluginAcquire {
    fn luau() -> Type {
        Type::Function {
            receiver: None,
            parameters: Vec::new(),
            returns: Box::new(Type::Function {
                receiver: None,
                parameters: Vec::new(),
                returns: Box::new(Type::Tuple(Vec::new())),
            }),
        }
    }
}

/// A reusable plugin definition.
#[derive(Clone)]
pub struct PluginDefinition {
    pub(super) data: Rc<DefinitionData>,
}

impl Typed for PluginDefinition {
    fn luau() -> Type {
        Type::Named("PluginDefinition")
    }
}

impl UserData for PluginDefinition {}

/// A runtime-local plugin graph.
#[derive(Clone)]
pub struct PluginRuntime {
    pub(super) state: Rc<RefCell<RuntimeState>>,
}

impl Typed for PluginRuntime {
    fn luau() -> Type {
        Type::Named("PluginRuntime")
    }
}

impl UserData for PluginRuntime {
    fn add_methods<Methods: UserDataMethods<Self>>(methods: &mut Methods) {
        crate::lua::declarations::add_described_methods(methods);
    }
}

fn runtime_use(
    lua: &Lua,
    this: &PluginRuntime,
    (definition, config): (UserDataRef<PluginDefinition>, Unknown),
) -> mlua::Result<PluginInstance> {
    super::use_definition(
        lua,
        &this.state,
        Rc::clone(&definition.data),
        config.0,
        None,
    )
}

fn runtime_close(lua: &Lua, this: &PluginRuntime, _: ()) -> mlua::Result<()> {
    super::close_runtime(lua, &this.state)
}

fn runtime_drain(lua: &Lua, this: &PluginRuntime, _: ()) -> mlua::Result<()> {
    super::drain_runtime(lua, &this.state)
}

impl MethodsDescribed for PluginRuntime {
    fn describe_methods(surface: &mut impl MethodSurface<Self>) {
        surface.method(
            MethodSpec {
                name: "use",
                doc: "Installs a definition with its configuration.",
                receiver: Receiver::Own,
                parameters: &["definition", "config"],
            },
            runtime_use,
        );
        surface.method(
            MethodSpec {
                name: "close",
                doc: "Disposes every instance in this runtime.",
                receiver: Receiver::Own,
                parameters: &[],
            },
            runtime_close,
        );
        surface.method(
            MethodSpec {
                name: "drain",
                doc: "Processes queued lifecycle work and records graph diagnostics.",
                receiver: Receiver::Own,
                parameters: &[],
            },
            runtime_drain,
        );
    }
}

/// A runtime-local installed plugin instance.
#[derive(Clone)]
pub struct PluginInstance {
    pub(super) runtime: Weak<RefCell<RuntimeState>>,
    pub(super) id: InstanceId,
}

impl Typed for PluginInstance {
    fn luau() -> Type {
        Type::Named("PluginInstance")
    }
}

impl UserData for PluginInstance {
    fn add_methods<Methods: UserDataMethods<Self>>(methods: &mut Methods) {
        crate::lua::declarations::add_described_methods(methods);
    }
}

fn instance_enable(lua: &Lua, this: &PluginInstance, _: ()) -> mlua::Result<()> {
    super::request_instance(lua, &this.runtime, Command::Enable(this.id))
}

fn instance_disable(lua: &Lua, this: &PluginInstance, _: ()) -> mlua::Result<()> {
    super::request_instance(lua, &this.runtime, Command::Disable(this.id))
}

fn instance_dispose(lua: &Lua, this: &PluginInstance, _: ()) -> mlua::Result<()> {
    super::request_instance(lua, &this.runtime, Command::Dispose(this.id))
}

fn instance_reload(lua: &Lua, this: &PluginInstance, (config,): (Unknown,)) -> mlua::Result<()> {
    super::request_instance(lua, &this.runtime, Command::Reload(this.id, config.0))
}

impl MethodsDescribed for PluginInstance {
    fn describe_methods(surface: &mut impl MethodSurface<Self>) {
        for (name, doc, body) in [
            (
                "enable",
                "Enables this plugin instance.",
                instance_enable as fn(&Lua, &Self, ()) -> _,
            ),
            (
                "disable",
                "Disables this plugin instance.",
                instance_disable,
            ),
            (
                "dispose",
                "Disables and retires this plugin instance.",
                instance_dispose,
            ),
        ] {
            surface.method(
                MethodSpec {
                    name,
                    doc,
                    receiver: Receiver::Own,
                    parameters: &[],
                },
                body,
            );
        }
        surface.method(
            MethodSpec {
                name: "reload",
                doc: "Replaces this instance's configuration and reloads it.",
                receiver: Receiver::Own,
                parameters: &["config"],
            },
            instance_reload,
        );
    }
}

/// A callback context bound to one exact runtime attachment allocation.
#[derive(Clone)]
pub struct PluginContext {
    pub(super) runtime: Weak<RefCell<RuntimeState>>,
    pub(super) instance: InstanceId,
    pub(super) activation: ActivationId,
}

impl Typed for PluginContext {
    fn luau() -> Type {
        Type::Named("PluginContext")
    }
}

impl UserData for PluginContext {
    fn add_methods<Methods: UserDataMethods<Self>>(methods: &mut Methods) {
        crate::lua::declarations::add_described_methods(methods);
    }
}

fn context_services(lua: &Lua, this: &PluginContext, _: ()) -> mlua::Result<Unknown> {
    super::services(lua, this)
}

fn context_effect(
    lua: &Lua,
    this: &PluginContext,
    (acquire,): (PluginAcquire,),
) -> mlua::Result<PluginEffect> {
    super::effect(lua, this, acquire.0)
}

fn context_child(
    lua: &Lua,
    this: &PluginContext,
    (definition, config): (UserDataRef<PluginDefinition>, Unknown),
) -> mlua::Result<PluginInstance> {
    super::child(lua, this, Rc::clone(&definition.data), config.0)
}

fn context_check_owner(
    lua: &Lua,
    this: &PluginContext,
    (caller,): (UserDataRef<PluginContext>,),
) -> mlua::Result<()> {
    super::check_owner(lua, this, &caller)
}

fn context_active(_: &Lua, this: &PluginContext, _: ()) -> mlua::Result<bool> {
    Ok(super::context_active(this))
}

impl MethodsDescribed for PluginContext {
    fn describe_methods(surface: &mut impl MethodSurface<Self>) {
        surface.method(
            MethodSpec {
                name: "services",
                doc: "Returns the services supplied by required contracts.",
                receiver: Receiver::Own,
                parameters: &[],
            },
            context_services,
        );
        surface.method(
            MethodSpec {
                name: "effect",
                doc: "Acquires a resource and registers its inverse for cleanup.",
                receiver: Receiver::Own,
                parameters: &["acquire"],
            },
            context_effect,
        );
        surface.method(
            MethodSpec {
                name: "child",
                doc: "Installs a child definition owned by this plugin.",
                receiver: Receiver::Own,
                parameters: &["definition", "config"],
            },
            context_child,
        );
        surface.method(
            MethodSpec {
                name: "checkOwner",
                doc: "Checks that another context is an owner of this plugin's service.",
                receiver: Receiver::Own,
                parameters: &["caller"],
            },
            context_check_owner,
        );
        surface.method(
            MethodSpec {
                name: "active",
                doc: "Reports whether this context's activation is still live.",
                receiver: Receiver::Own,
                parameters: &[],
            },
            context_active,
        );
    }
}

/// A one-shot resource effect.
#[derive(Clone)]
pub struct PluginEffect {
    pub(super) runtime: Weak<RefCell<RuntimeState>>,
    pub(super) instance: InstanceId,
    pub(super) activation: ActivationId,
    pub(super) ordinal: usize,
    pub(super) disposed: Cell<bool>,
}

impl Typed for PluginEffect {
    fn luau() -> Type {
        Type::Named("PluginEffect")
    }
}

impl UserData for PluginEffect {
    fn add_methods<Methods: UserDataMethods<Self>>(methods: &mut Methods) {
        crate::lua::declarations::add_described_methods(methods);
    }
}

fn effect_dispose(lua: &Lua, this: &PluginEffect, _: ()) -> mlua::Result<()> {
    if this.disposed.replace(true) {
        return Ok(());
    }
    super::dispose_effect(lua, this)
}

impl MethodsDescribed for PluginEffect {
    fn describe_methods(surface: &mut impl MethodSurface<Self>) {
        surface.method(
            MethodSpec {
                name: "dispose",
                doc: "Disposes this effect once.",
                receiver: Receiver::Own,
                parameters: &[],
            },
            effect_dispose,
        );
    }
}

pub(super) struct AttachmentHost {
    pub(super) registry: ContractRegistry,
    pub(super) contract_keys: std::collections::HashMap<ContractId, ContractKey>,
    pub(super) runtimes: Vec<Rc<RefCell<RuntimeState>>>,
    pub(super) definitions: Vec<Weak<DefinitionData>>,
    pub(super) callback_depth: usize,
}

impl AttachmentHost {
    pub(super) fn new() -> Self {
        Self {
            registry: ContractRegistry::new(),
            contract_keys: std::collections::HashMap::new(),
            runtimes: Vec::new(),
            definitions: Vec::new(),
            callback_depth: 0,
        }
    }
}

pub(super) struct DefinitionData {
    pub(super) host: Weak<RefCell<AttachmentHost>>,
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
    pub(super) queue: VecDeque<Command>,
    pub(super) draining: bool,
    pub(super) closed: bool,
    pub(super) closing: bool,
    pub(super) errors: Vec<String>,
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
    pub(super) effects: Vec<Option<Function>>,
    pub(super) service: Option<Value>,
    pub(super) cancelled: bool,
}

pub(super) enum Command {
    Enable(InstanceId),
    Disable(InstanceId),
    Reload(InstanceId, Value),
    Dispose(InstanceId),
    Shutdown,
}
