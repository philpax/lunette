//! The userdata handles the plugin attachment exposes to Lua.

use std::{
    cell::RefCell,
    rc::{Rc, Weak},
};

use lunette_luau::{Parameter, Type, Typed, closed_set};
use mlua::{FromLua, Function, IntoLua, Lua, UserData, UserDataMethods, UserDataRef, Value};

use crate::{
    lua::declarations::{MethodSurface, MethodsDescribed, add_described_methods, handle},
    plugin::{
        attachment::{
            context, lifecycle,
            snapshot::{self, PluginRuntimeSnapshot},
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

/// A resource acquisition callback that cannot yield.
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
    /// The lifecycle state exposed to Lua.
    #[derive(Clone, Copy, Debug, PartialEq, Eq)]
    pub enum PluginState {
        /// Installed and not loaded; it may be waiting for a provider.
        Inactive = "inactive",
        /// Its initializer is running.
        Loading = "loading",
        /// Its services are published.
        Active = "active",
        /// Its unload is running.
        Unloading = "unloading",
        /// Its last load failed.
        Failed = "failed",
        /// An inverse failed, so it cannot load again.
        Quarantined = "quarantined",
        /// It is disposed and removed, or its runtime is closed.
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
        add_described_methods(methods);
    }
}

impl MethodsDescribed for PluginRuntime {
    fn describe_methods(surface: &mut impl MethodSurface<Self>) {
        handle!(@items surface,
            /// Installs a definition with its configuration.
            method use(_lua, this, definition: UserDataRef<PluginDefinition>, config: Unknown) -> PluginInstance {
                Ok(lifecycle::use_definition(
                    &this.state,
                    Rc::clone(&definition.data),
                    config.0,
                    None,
                )?)
            }

            /// Copies coherent runtime state without lifecycle work, callbacks, or diagnostic consumption.
            method snapshot(_lua, this) -> PluginRuntimeSnapshot {
                snapshot::snapshot(&this.state)
            }

            /// Returns a context's owning instance identity only when it belongs to this exact runtime, including after its activation ends.
            method ownerId(_lua, this, context: UserDataRef<PluginContext>) -> Option<String> {
                Ok(context.runtime.upgrade()
                    .filter(|runtime| Rc::ptr_eq(runtime, &this.state))
                    .map(|_| snapshot::instance_id(context.instance)))
            }

            /// Disposes every instance in this runtime.
            method close(lua, this) -> () {
                Ok(lifecycle::close_runtime(lua, &this.state)?)
            }

            /// Performs pending lifecycle work and reports graph diagnostics.
            method drain(lua, this) -> () {
                Ok(lifecycle::drain_runtime(lua, &this.state)?)
            }
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
        add_described_methods(methods);
    }
}

impl MethodsDescribed for PluginInstance {
    fn describe_methods(surface: &mut impl MethodSurface<Self>) {
        handle!(@items surface,
            /// Enables this plugin instance and reserves its provided contracts.
            method enable(lua, this) -> () {
                Ok(lifecycle::request_instance(
                    lua,
                    &this.runtime,
                    lifecycle::Request::Enable(this.id),
                )?)
            }

            /// Disables this plugin instance.
            method disable(lua, this) -> () {
                Ok(lifecycle::request_instance(
                    lua,
                    &this.runtime,
                    lifecycle::Request::Disable(this.id),
                )?)
            }

            /// Disables and permanently retires this plugin instance.
            method dispose(lua, this) -> () {
                Ok(lifecycle::request_instance(
                    lua,
                    &this.runtime,
                    lifecycle::Request::Dispose(this.id),
                )?)
            }

            /// Accepts a replacement configuration and reload intent without draining lifecycle work.
            /// The caller drains the runtime separately; rejection leaves configuration unchanged.
            method requestReload(_lua, this, config: Unknown) -> () {
                lifecycle::request_instance_deferred(
                    &this.runtime,
                    lifecycle::Request::Reload(this.id, config.0),
                )?;
                Ok(())
            }

            /// Returns this handle's exact runtime-local identity, without consulting its name or lifecycle.
            method id(_lua, this) -> String {
                Ok(snapshot::instance_id(this.id))
            }

            /// Reports this instance's lifecycle state.
            method state(_lua, this) -> PluginState {
                Ok(lifecycle::instance_state(&this.runtime, this.id))
            }
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
        add_described_methods(methods);
    }
}

impl MethodsDescribed for PluginContext {
    fn describe_methods(surface: &mut impl MethodSurface<Self>) {
        handle!(@items surface,
            /// Returns the services supplied by required contracts.
            method services(lua, this) -> Unknown {
                Ok(context::services(lua, this)?)
            }

            /// Acquires a resource and registers its inverse for cleanup.
            method effect(lua, this, acquire: PluginAcquire) -> PluginEffect {
                context::effect(lua, this, acquire.0)
            }

            /// Acquires a resource and registers its inverse without draining queued lifecycle work.
            method effectDeferred(lua, this, acquire: PluginAcquire) -> PluginEffect {
                context::effect_deferred(lua, this, acquire.0)
            }

            /// Installs a child definition owned by this activation.
            method child(_lua, this, definition: UserDataRef<PluginDefinition>, config: Unknown) -> PluginInstance {
                Ok(context::child(this, Rc::clone(&definition.data), config.0)?)
            }

            /// Checks that another context is a live dependent of this plugin's current generation.
            method checkOwner(_lua, this, caller: UserDataRef<PluginContext>) -> () {
                Ok(context::check_owner(this, &caller)?)
            }

            /// Reports whether another context is a live dependent of this plugin's current generation: whether checkOwner would accept it.
            method owns(_lua, this, caller: UserDataRef<PluginContext>) -> bool {
                Ok(context::check_owner(this, &caller).is_ok())
            }

            /// Reports whether this context's activation is still live.
            method active(_lua, this) -> bool {
                Ok(context::context_active(this))
            }

            /// Reports whether this context's activation is published and has not begun unloading, so its services may be read.
            method serving(_lua, this) -> bool {
                Ok(context::context_serving(this))
            }
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
        add_described_methods(methods);
    }
}

impl MethodsDescribed for PluginEffect {
    fn describe_methods(surface: &mut impl MethodSurface<Self>) {
        handle!(@items surface,
            /// Runs this effect's inverse once. Disposing an effect whose activation, instance, or runtime has ended does nothing.
            method dispose(lua, this) -> () {
                context::dispose_effect(lua, this)
            }
        );
    }
}
