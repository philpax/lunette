//! What a Rust type is called in Luau.
//!
//! Rust has no reflection, so the mapping is written out: one impl per type
//! that crosses into Lua. The spelling of a type appears here and nowhere else,
//! which is what lets a signature be derived rather than restated.

use std::collections::HashMap;

use mlua::{LuaString, UserDataRef};

/// The Luau type a value of this Rust type is seen as.
pub trait LuauType {
    fn luau() -> String;
}

/// The names of an argument tuple's types, in order.
pub trait LuauArgs {
    fn luau_args() -> Vec<String>;
}

/// [`LuauType::luau`] as a function pointer, for the places a type is named in
/// a `const`.
#[must_use]
pub fn luau_of<T: LuauType>() -> String {
    T::luau()
}

/// A value Lua never receives, for the arm of a discriminated handle that
/// carries none.
#[derive(Clone, Copy, Debug)]
pub struct Nil;

/// The receiver of a method reached through the union of the handles that carry
/// pixels.
#[derive(Clone, Copy, Debug)]
pub struct Textured;

macro_rules! leaf {
    ($($rust:ty => $luau:literal),* $(,)?) => {
        $(
            impl LuauType for $rust {
                fn luau() -> String {
                    $luau.to_owned()
                }
            }
        )*
    };
}

leaf! {
    bool => "boolean",
    f32 => "number",
    f64 => "number",
    i32 => "number",
    i64 => "number",
    u32 => "number",
    u64 => "number",
    usize => "number",
    String => "string",
    LuaString => "string",
    Nil => "nil",
    Textured => "Textured",
}

impl<T: LuauType> LuauType for Option<T> {
    fn luau() -> String {
        format!("{}?", T::luau())
    }
}

impl<T: LuauType> LuauType for Vec<T> {
    fn luau() -> String {
        format!("{{ {} }}", T::luau())
    }
}

impl<K: LuauType, V: LuauType> LuauType for HashMap<K, V> {
    fn luau() -> String {
        format!("{{ [{}]: {} }}", K::luau(), V::luau())
    }
}

impl<T: LuauType + 'static> LuauType for UserDataRef<T> {
    fn luau() -> String {
        T::luau()
    }
}

impl LuauType for () {
    fn luau() -> String {
        "()".to_owned()
    }
}

impl LuauArgs for () {
    fn luau_args() -> Vec<String> {
        Vec::new()
    }
}

macro_rules! tuples {
    ($(($($member:ident),+)),* $(,)?) => {
        $(
            impl<$($member: LuauType),+> LuauType for ($($member,)+) {
                fn luau() -> String {
                    let members = [$($member::luau()),+];
                    format!("({})", members.join(", "))
                }
            }

            impl<$($member: LuauType),+> LuauArgs for ($($member,)+) {
                fn luau_args() -> Vec<String> {
                    vec![$($member::luau()),+]
                }
            }
        )*
    };
}

tuples! {
    (A),
    (A, B),
    (A, B, C),
    (A, B, C, D),
}
