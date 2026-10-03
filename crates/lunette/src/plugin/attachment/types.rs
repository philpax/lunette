//! The userdata handles the plugin attachment exposes to Lua.

use std::{
    cell::RefCell,
    rc::{Rc, Weak},
};

use lunette_luau::{Parameter, Type, Typed, closed_set};
use mlua::{FromLua, Function, IntoLua, Lua, UserData, UserDataMethods, UserDataRef, Value};

use crate::{
    lua::declarations::{MethodSpec, MethodSurface, MethodsDescribed, Receiver},
    plugin::{
        attachment::{
            context, lifecycle,
            state::{DefinitionData, RuntimeState},
        },
        contracts::PluginContractToken,
        graph::{ActivationId, InstanceId, LifecycleState},
    },
};

impl Typed for PluginContractToken {
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

closed_set! {
    /// The lifecycle state of an instance as Lua sees it.
    #[derive(Clone, Copy, Debug, PartialEq, Eq)]
    pub enum PluginState {
        /// Installed and not loaded; it may be waiting for a provider.
        Inactive = "inactive",
        /// Its initializer is running.
        Loading = "loading",
        /// Its services are published.
        Active = "active",
        /// Its cleanup is running.
        Unloading = "unloading",
        /// Its last load failed.
        Failed = "failed",
        /// A cleanup inverse failed, so it never loads again.
        Quarantined = "quarantined",
        /// It was disposed and removed, or its runtime closed.
        Removed = "removed",
    }
}

impl From<LifecycleState> for PluginState {
    fn from(state: LifecycleState) -> Self {
        match state {
            LifecycleState::Inactive => Self::Inactive,
            LifecycleState::Loading => Self::Loading,
            LifecycleState::Active => Self::Active,
            LifecycleState::Unloading => Self::Unloading,
            LifecycleState::Failed => Self::Failed,
            LifecycleState::Quarantined => Self::Quarantined,
        }
    }
}

impl IntoLua for PluginState {
    fn into_lua(self, lua: &Lua) -> mlua::Result<Value> {
        self.as_str().into_lua(lua)
    }
}

impl Typed for PluginState {
    fn luau() -> Type {
        Type::Named("PluginState")
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
    _: &Lua,
    this: &PluginRuntime,
    (definition, config): (UserDataRef<PluginDefinition>, Unknown),
) -> mlua::Result<PluginInstance> {
    Ok(lifecycle::use_definition(
        &this.state,
        Rc::clone(&definition.data),
        config.0,
        None,
    )?)
}

fn runtime_close(lua: &Lua, this: &PluginRuntime, _: ()) -> mlua::Result<()> {
    Ok(lifecycle::close_runtime(lua, &this.state)?)
}

fn runtime_drain(lua: &Lua, this: &PluginRuntime, _: ()) -> mlua::Result<()> {
    Ok(lifecycle::drain_runtime(lua, &this.state)?)
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
                doc: "Performs pending lifecycle work and reports graph diagnostics.",
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
    Ok(lifecycle::request_instance(
        lua,
        &this.runtime,
        lifecycle::Request::Enable(this.id),
    )?)
}

fn instance_disable(lua: &Lua, this: &PluginInstance, _: ()) -> mlua::Result<()> {
    Ok(lifecycle::request_instance(
        lua,
        &this.runtime,
        lifecycle::Request::Disable(this.id),
    )?)
}

fn instance_dispose(lua: &Lua, this: &PluginInstance, _: ()) -> mlua::Result<()> {
    Ok(lifecycle::request_instance(
        lua,
        &this.runtime,
        lifecycle::Request::Dispose(this.id),
    )?)
}

fn instance_reload(lua: &Lua, this: &PluginInstance, (config,): (Unknown,)) -> mlua::Result<()> {
    Ok(lifecycle::request_instance(
        lua,
        &this.runtime,
        lifecycle::Request::Reload(this.id, config.0),
    )?)
}

fn instance_state(_: &Lua, this: &PluginInstance, _: ()) -> mlua::Result<PluginState> {
    Ok(lifecycle::instance_state(&this.runtime, this.id))
}

fn instance_diagnostic(_: &Lua, this: &PluginInstance, _: ()) -> mlua::Result<Option<String>> {
    Ok(lifecycle::instance_diagnostic(&this.runtime, this.id))
}

impl MethodsDescribed for PluginInstance {
    fn describe_methods(surface: &mut impl MethodSurface<Self>) {
        for (name, doc, body) in [
            (
                "enable",
                "Enables this plugin instance and reserves its provided contracts.",
                instance_enable as fn(&Lua, &Self, ()) -> _,
            ),
            (
                "disable",
                "Disables this plugin instance.",
                instance_disable,
            ),
            (
                "dispose",
                "Disables and permanently retires this plugin instance.",
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
        surface.method(
            MethodSpec {
                name: "state",
                doc: "Reports this instance's lifecycle state.",
                receiver: Receiver::Own,
                parameters: &[],
            },
            instance_state,
        );
        surface.method(
            MethodSpec {
                name: "diagnostic",
                doc: "Describes why this instance last failed or is not loading, if it has a reason.",
                receiver: Receiver::Own,
                parameters: &[],
            },
            instance_diagnostic,
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
    Ok(context::services(lua, this)?)
}

fn context_effect(
    lua: &Lua,
    this: &PluginContext,
    (acquire,): (PluginAcquire,),
) -> mlua::Result<PluginEffect> {
    context::effect(lua, this, acquire.0)
}

fn context_child(
    _: &Lua,
    this: &PluginContext,
    (definition, config): (UserDataRef<PluginDefinition>, Unknown),
) -> mlua::Result<PluginInstance> {
    Ok(context::child(this, Rc::clone(&definition.data), config.0)?)
}

fn context_check_owner(
    _: &Lua,
    this: &PluginContext,
    (caller,): (UserDataRef<PluginContext>,),
) -> mlua::Result<()> {
    Ok(context::check_owner(this, &caller)?)
}

fn context_owns(
    _: &Lua,
    this: &PluginContext,
    (caller,): (UserDataRef<PluginContext>,),
) -> mlua::Result<bool> {
    Ok(context::check_owner(this, &caller).is_ok())
}

fn context_active(_: &Lua, this: &PluginContext, _: ()) -> mlua::Result<bool> {
    Ok(context::context_active(this))
}

fn context_serving(_: &Lua, this: &PluginContext, _: ()) -> mlua::Result<bool> {
    Ok(context::context_serving(this))
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
                doc: "Installs a child definition owned by this activation.",
                receiver: Receiver::Own,
                parameters: &["definition", "config"],
            },
            context_child,
        );
        surface.method(
            MethodSpec {
                name: "checkOwner",
                doc: "Checks that another context is a live dependent of this plugin's current generation.",
                receiver: Receiver::Own,
                parameters: &["caller"],
            },
            context_check_owner,
        );
        surface.method(
            MethodSpec {
                name: "owns",
                doc: "Reports whether another context is a live dependent of this plugin's current generation: whether checkOwner would accept it.",
                receiver: Receiver::Own,
                parameters: &["caller"],
            },
            context_owns,
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
        surface.method(
            MethodSpec {
                name: "serving",
                doc: "Reports whether this context's activation is published and has not begun unloading, so its services may be read.",
                receiver: Receiver::Own,
                parameters: &[],
            },
            context_serving,
        );
    }
}

/// A one-shot resource effect.
#[derive(Clone)]
pub struct PluginEffect {
    pub(super) runtime: Weak<RefCell<RuntimeState>>,
    pub(super) instance: InstanceId,
    pub(super) activation: ActivationId,
    pub(super) ordinal: u64,
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
    context::dispose_effect(lua, this)
}

impl MethodsDescribed for PluginEffect {
    fn describe_methods(surface: &mut impl MethodSurface<Self>) {
        surface.method(
            MethodSpec {
                name: "dispose",
                doc: "Runs this effect's inverse once. Disposing an effect whose activation, instance, or runtime has ended does nothing.",
                receiver: Receiver::Own,
                parameters: &[],
            },
            effect_dispose,
        );
    }
}
