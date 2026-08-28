//! The Luau type language, and how a Rust type appears in it.
//!
//! The crate contains two different kinds of value. [`Type`] is a Luau type
//! expression: a small tree that renders as text. Parentheses follow from the
//! tree's structure. The text that names the type does not affect them.
//! [`Typed`] states that a Rust type appears in Luau as one of them. A
//! signature derives from the function's own types and is not restated beside
//! the function.
//!
//! The crate has no Lua binding by default. A closed set that is a union
//! of four string literals requires no Lua binding. The compositor does not
//! link mlua for it. The crate's tests run headless. The `mlua` feature
//! adds the impls for mlua's own types, and `lunette` enables the feature.

mod closed_set;
mod expression;
mod typed;

pub use crate::{
    expression::{Parameter, Type},
    typed::{Arguments, Typed, of},
};
