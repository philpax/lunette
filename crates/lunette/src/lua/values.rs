//! The values that cross into Lua and are not handles.
//!
//! Each wrapper exists because Rust states something less precisely than Luau does:
//! a texture that may be `false`, a string that is one of four words, a
//! property that is a number or a string but not a table. Wrapping them lets every
//! signature be derived rather than restated.
//!
//! Each type appears next to the conversion it crosses by and the Luau type it
//! is seen as, so what a wrapper carries and what it is declared to be read
//! together rather than a file apart.

use lunette_compositor::protocol::{
    ContentType, InputDomain, PointerButton, ProcessOutcome, Stream,
};
use lunette_luau::Type;
use mlua::{FromLua, Function, IntoLua, Lua, Table, Value};

use crate::{
    lua::{
        ErrorEvent,
        declarations::{AliasSpec, Aliased, Parameter, Typed, of},
    },
    properties::property_value,
};

/// A texture, or `false` while the client is gone or has committed nothing.
#[derive(Debug)]
pub struct MaybeTexture(pub Value);

impl IntoLua for MaybeTexture {
    fn into_lua(self, _: &Lua) -> mlua::Result<Value> {
        Ok(self.0)
    }
}

impl Typed for MaybeTexture {
    fn luau() -> Type {
        Type::Union(vec![Type::Named("Texture"), Type::Named("false")])
    }
}

/// A composition layer, or `false` while the claim holds none.
#[derive(Debug)]
pub struct MaybeLayer(pub Value);

impl IntoLua for MaybeLayer {
    fn into_lua(self, _: &Lua) -> mlua::Result<Value> {
        Ok(self.0)
    }
}

impl Typed for MaybeLayer {
    fn luau() -> Type {
        Type::Union(vec![Type::Named("Layer"), Type::Named("false")])
    }
}

/// What a window's client says it draws.
#[derive(Clone, Copy, Debug)]
pub struct ContentTypeName(pub ContentType);

impl IntoLua for ContentTypeName {
    fn into_lua(self, lua: &Lua) -> mlua::Result<Value> {
        self.0.as_str().into_lua(lua)
    }
}

impl Typed for ContentTypeName {
    fn luau() -> Type {
        Type::literals(ContentType::NAMES)
    }
}

/// Which pipeline a sink's events travel.
#[derive(Clone, Copy, Debug)]
pub struct SinkDomain(pub InputDomain);

impl IntoLua for SinkDomain {
    fn into_lua(self, lua: &Lua) -> mlua::Result<Value> {
        self.0.as_str().into_lua(lua)
    }
}

impl Typed for SinkDomain {
    fn luau() -> Type {
        Type::literals(InputDomain::NAMES)
    }
}

/// The domain of a sink that reaches a window this compositor hosts.
///
/// One arm of the union [`SinkDomain`] covers, for the view of a sink that is
/// known to be a window's. No value of it ever crosses: the field it declares
/// is answered by the domain the sink actually carries.
#[derive(Clone, Copy, Debug)]
pub struct WindowDomain;

impl Typed for WindowDomain {
    fn luau() -> Type {
        Type::Literal(InputDomain::Window.as_str())
    }
}

/// The domain of a sink that reaches the host desktop.
#[derive(Clone, Copy, Debug)]
pub struct HostDomain;

impl Typed for HostDomain {
    fn luau() -> Type {
        Type::Literal(InputDomain::Host.as_str())
    }
}

/// A pointer button, by the name Lua spells it with.
#[derive(Clone, Copy, Debug)]
pub struct PointerButtonName(pub PointerButton);

impl FromLua for PointerButtonName {
    fn from_lua(value: Value, lua: &Lua) -> mlua::Result<Self> {
        let name = String::from_lua(value, lua)?;
        PointerButton::from_name(&name).map(Self).ok_or_else(|| {
            mlua::Error::runtime(format!(
                "lunette: '{name}' is not a pointer button; the buttons are {}",
                PointerButton::NAMES.join(", ")
            ))
        })
    }
}

impl Typed for PointerButtonName {
    fn luau() -> Type {
        Type::Named("PointerButton")
    }
}

impl Aliased for PointerButtonName {
    const ALIAS: AliasSpec = AliasSpec {
        doc: "Which pointer button an event names. The runtime refuses anything else.",
        name: Self::luau,
        definition: |_| Type::literals(PointerButton::NAMES),
    };
}

/// A value a property can hold, on the way in.
#[derive(Debug)]
pub struct PropertyArgument(pub Value);

impl FromLua for PropertyArgument {
    fn from_lua(value: Value, _: &Lua) -> mlua::Result<Self> {
        Ok(Self(value))
    }
}

impl Typed for PropertyArgument {
    fn luau() -> Type {
        property_value()
    }
}

/// What a property held, or nil for a key that was never set.
#[derive(Debug)]
pub struct StoredProperty(pub Value);

impl IntoLua for StoredProperty {
    fn into_lua(self, _: &Lua) -> mlua::Result<Value> {
        Ok(self.0)
    }
}

/// A union with nil rather than `T?`. The reader of a property is asking what a
/// key holds, and the scalars followed by nil answers that in the order they
/// were declared.
impl Typed for StoredProperty {
    fn luau() -> Type {
        let Type::Union(mut members) = property_value() else {
            unreachable!("a property value is the union of the scalars it may hold")
        };
        members.push(Type::NIL);
        Type::Union(members)
    }
}

/// Every property a window carries.
#[derive(Debug)]
pub struct PropertyMap(pub Table);

impl IntoLua for PropertyMap {
    fn into_lua(self, _: &Lua) -> mlua::Result<Value> {
        Ok(Value::Table(self.0))
    }
}

impl Typed for PropertyMap {
    fn luau() -> Type {
        Type::map(Type::STRING, property_value())
    }
}

/// What a stroke is asked for by: a character to type, or a keysym to produce.
#[derive(Debug)]
pub struct StrokeQuery(pub Value);

impl FromLua for StrokeQuery {
    fn from_lua(value: Value, _: &Lua) -> mlua::Result<Self> {
        Ok(Self(value))
    }
}

impl Typed for StrokeQuery {
    fn luau() -> Type {
        Type::Union(vec![Type::STRING, Type::NUMBER])
    }
}

/// A layer a granted claim now holds.
///
/// Distinct from [`MaybeLayer`]: a grant carries one, so the event declares a
/// layer rather than a layer or `false`.
#[derive(Debug)]
pub struct GrantedLayer(pub Value);

impl IntoLua for GrantedLayer {
    fn into_lua(self, _: &Lua) -> mlua::Result<Value> {
        Ok(self.0)
    }
}

impl Typed for GrantedLayer {
    fn luau() -> Type {
        Type::Named("Layer")
    }
}

/// Which of a process's captured streams wrote.
#[derive(Clone, Copy, Debug)]
pub struct StreamName(pub Stream);

impl IntoLua for StreamName {
    fn into_lua(self, lua: &Lua) -> mlua::Result<Value> {
        self.0.as_str().into_lua(lua)
    }
}

impl Typed for StreamName {
    fn luau() -> Type {
        Type::literals(Stream::NAMES)
    }
}

/// How a process ended, by the name Lua reads on `event.outcome`.
#[derive(Clone, Debug)]
pub struct OutcomeName(pub ProcessOutcome);

impl IntoLua for OutcomeName {
    fn into_lua(self, lua: &Lua) -> mlua::Result<Value> {
        self.0.as_str().into_lua(lua)
    }
}

impl Typed for OutcomeName {
    fn luau() -> Type {
        Type::literals(ProcessOutcome::NAMES)
    }
}

/// A function subscribing to errors, by what it is handed.
#[derive(Debug)]
pub struct ErrorListener(pub Function);

impl FromLua for ErrorListener {
    fn from_lua(value: Value, lua: &Lua) -> mlua::Result<Self> {
        Function::from_lua(value, lua).map(Self)
    }
}

impl Typed for ErrorListener {
    fn luau() -> Type {
        Type::Function {
            receiver: None,
            parameters: vec![Parameter {
                name: "event",
                ty: of::<ErrorEvent>(),
            }],
            returns: Box::new(of::<()>()),
        }
    }
}

/// The function that ends a subscription. Calling it twice is harmless: the
/// second call names a subscription that is no longer there.
#[derive(Debug)]
pub struct Cancel(pub Function);

impl IntoLua for Cancel {
    fn into_lua(self, _: &Lua) -> mlua::Result<Value> {
        Ok(Value::Function(self.0))
    }
}

impl Typed for Cancel {
    fn luau() -> Type {
        Type::Function {
            receiver: None,
            parameters: Vec::new(),
            returns: Box::new(of::<()>()),
        }
    }
}
