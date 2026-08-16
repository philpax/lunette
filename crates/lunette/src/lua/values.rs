//! The values that cross into Lua and are not handles.
//!
//! Each one exists because Rust states something less precisely than Luau does:
//! a texture that may be `false`, a string that is one of four words, a
//! property that is a number or a string but not a table. Wrapping them is what
//! lets every signature be derived rather than restated.

use lunette_compositor::protocol::{ContentType, InputDomain, PointerButton};
use lunette_luau::Type;
use mlua::{FromLua, IntoLua, Lua, Table, Value};

use crate::{lua::declarations::Typed, properties::property_value};

/// A texture, or `false` while the client is gone or has committed nothing.
#[derive(Debug)]
pub struct MaybeTexture(pub Value);

/// A composition layer, or `false` while the claim holds none.
#[derive(Debug)]
pub struct MaybeLayer(pub Value);

/// What a window's client says it draws.
#[derive(Clone, Copy, Debug)]
pub struct ContentTypeName(pub ContentType);

/// Which pipeline a sink's events travel.
#[derive(Clone, Copy, Debug)]
pub struct SinkDomain(pub InputDomain);

/// The domain of a sink that reaches a window this compositor hosts.
#[derive(Clone, Copy, Debug)]
pub struct WindowDomain;

/// The domain of a sink that reaches the host desktop.
#[derive(Clone, Copy, Debug)]
pub struct HostDomain;

/// A pointer button, by the name Lua spells it with.
#[derive(Clone, Copy, Debug)]
pub struct PointerButtonName(pub PointerButton);

/// A value a property can hold, on the way in.
#[derive(Debug)]
pub struct PropertyArgument(pub Value);

/// What a property held, or nil for a key that was never set.
#[derive(Debug)]
pub struct StoredProperty(pub Value);

/// Every property a window carries.
#[derive(Debug)]
pub struct PropertyMap(pub Table);

/// What a stroke is asked for by: a character to type, or a keysym to produce.
#[derive(Debug)]
pub struct StrokeQuery(pub Value);

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

impl Typed for WindowDomain {
    fn luau() -> Type {
        Type::Literal(InputDomain::Window.as_str())
    }
}

impl Typed for HostDomain {
    fn luau() -> Type {
        Type::Literal(InputDomain::Host.as_str())
    }
}

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

impl IntoLua for StoredProperty {
    fn into_lua(self, _: &Lua) -> mlua::Result<Value> {
        Ok(self.0)
    }
}

impl Typed for StoredProperty {
    fn luau() -> Type {
        let Type::Union(mut members) = property_value() else {
            unreachable!("a property value is the union of the scalars it may hold")
        };
        members.push(Type::NIL);
        Type::Union(members)
    }
}

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
