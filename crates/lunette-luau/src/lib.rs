//! The Luau type language, and what a Rust type is seen as in it.
//!
//! Two things live here and they are deliberately different kinds of thing.
//! [`Type`] is a Luau type expression: a small tree that knows how to render
//! itself, so parentheses follow from structure rather than from whoever wrote
//! the format string. [`Typed`] is the claim that a Rust type appears in Luau
//! as one of them, which is what lets a signature be derived from a function's
//! own types instead of restated beside it.
//!
//! The crate carries no Lua binding by default. A closed set declaring that it
//! is a union of four string literals is not a reason for the compositor to
//! link mlua, and its tests run headless. The `mlua` feature adds the impls for
//! mlua's own types, and `lunette` is what turns it on.

mod closed_set;
mod expression;
mod typed;

pub use crate::{
    expression::{Parameter, Type},
    typed::{Arguments, Typed, of},
};
