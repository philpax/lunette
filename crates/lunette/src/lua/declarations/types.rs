//! The markers that stand for a Luau type with no Rust type behind it.
//!
//! Everything else comes from [`lunette_luau`]: the leaves, the containers, and
//! the tuples are stated once there, and a handle states its own name through
//! the [`Typed`] impl its `handle!` block generates. What is left here is the
//! two places a declaration names a type that no value ever has.

use lunette_luau::{Type, Typed};

/// A value Lua never receives, for the arm of a discriminated handle that
/// carries none.
#[derive(Clone, Copy, Debug)]
pub struct Nil;

/// The receiver of a method reached through the union of the handles that carry
/// pixels.
#[derive(Clone, Copy, Debug)]
pub struct Textured;

impl Typed for Nil {
    fn luau() -> Type {
        Type::NIL
    }
}

impl Typed for Textured {
    fn luau() -> Type {
        Type::Named("Textured")
    }
}
