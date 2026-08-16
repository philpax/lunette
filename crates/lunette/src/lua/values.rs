//! The values that cross into Lua and are not handles.
//!
//! Each one exists because Rust states something less precisely than Luau does:
//! a texture that may be `false`, a string that is one of four words, a
//! property that is a number or a string but not a table. Wrapping them is what
//! lets every signature be derived rather than restated.

use lunette_compositor::protocol::{ContentType, InputDomain, PointerButton};
use mlua::{FromLua, IntoLua, Lua, Table, Value};

use crate::{
    lua::{declarations::LuauType, pointer_button, pointer_button_names},
    properties::PROPERTY_VALUE,
};

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

impl LuauType for MaybeTexture {
    fn luau() -> String {
        "Texture | false".to_owned()
    }
}

impl IntoLua for MaybeLayer {
    fn into_lua(self, _: &Lua) -> mlua::Result<Value> {
        Ok(self.0)
    }
}

impl LuauType for MaybeLayer {
    fn luau() -> String {
        "Layer | false".to_owned()
    }
}

impl IntoLua for ContentTypeName {
    fn into_lua(self, lua: &Lua) -> mlua::Result<Value> {
        self.0.as_str().into_lua(lua)
    }
}

impl LuauType for ContentTypeName {
    fn luau() -> String {
        union(ContentType::NAMES)
    }
}

impl IntoLua for SinkDomain {
    fn into_lua(self, lua: &Lua) -> mlua::Result<Value> {
        self.0.as_str().into_lua(lua)
    }
}

impl LuauType for SinkDomain {
    fn luau() -> String {
        union(InputDomain::NAMES)
    }
}

impl LuauType for WindowDomain {
    fn luau() -> String {
        literal(InputDomain::Window.as_str())
    }
}

impl LuauType for HostDomain {
    fn luau() -> String {
        literal(InputDomain::Host.as_str())
    }
}

impl FromLua for PointerButtonName {
    fn from_lua(value: Value, lua: &Lua) -> mlua::Result<Self> {
        let name = String::from_lua(value, lua)?;
        pointer_button(&name).map(Self).ok_or_else(|| {
            mlua::Error::runtime(format!(
                "lunette: '{name}' is not a pointer button; the buttons are {}",
                pointer_button_names().collect::<Vec<_>>().join(", ")
            ))
        })
    }
}

impl LuauType for PointerButtonName {
    fn luau() -> String {
        "PointerButton".to_owned()
    }
}

impl FromLua for PropertyArgument {
    fn from_lua(value: Value, _: &Lua) -> mlua::Result<Self> {
        Ok(Self(value))
    }
}

impl LuauType for PropertyArgument {
    fn luau() -> String {
        PROPERTY_VALUE.to_owned()
    }
}

impl IntoLua for StoredProperty {
    fn into_lua(self, _: &Lua) -> mlua::Result<Value> {
        Ok(self.0)
    }
}

impl LuauType for StoredProperty {
    fn luau() -> String {
        format!("{PROPERTY_VALUE} | nil")
    }
}

impl IntoLua for PropertyMap {
    fn into_lua(self, _: &Lua) -> mlua::Result<Value> {
        Ok(Value::Table(self.0))
    }
}

impl LuauType for PropertyMap {
    fn luau() -> String {
        format!("{{ [string]: {PROPERTY_VALUE} }}")
    }
}

impl FromLua for StrokeQuery {
    fn from_lua(value: Value, _: &Lua) -> mlua::Result<Self> {
        Ok(Self(value))
    }
}

impl LuauType for StrokeQuery {
    fn luau() -> String {
        "string | number".to_owned()
    }
}

/// The Luau union of a set of string literals.
fn union(names: &[&str]) -> String {
    names
        .iter()
        .map(|name| literal(name))
        .collect::<Vec<_>>()
        .join(" | ")
}

fn literal(name: &str) -> String {
    format!("'{name}'")
}
