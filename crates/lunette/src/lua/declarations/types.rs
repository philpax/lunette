//! The markers that stand for a Luau type with no Rust type behind it.
//!
//! Everything else comes from [`lunette_luau`]: the leaves, the containers, and
//! the tuples are stated once there, and a handle states its own name through
//! the [`Typed`] impl its `handle!` block generates. What is left here is the
//! two places a declaration names a type that no value ever has.

use lunette_luau::{Type, Typed};

use crate::lua::declarations::{AliasSpec, Aliased};

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

impl Aliased for Textured {
    const ALIAS: AliasSpec = AliasSpec {
        doc: "The handles that carry pixels. A caller with one and no interest in which reads the \
              fields both have and calls `getTexture`, which is why that method names this as its \
              receiver on both.",
        name: Self::luau,
        definition: |handles| {
            // Read off the declarations: a handle carries pixels exactly when
            // one of its methods names this as its receiver, which is what
            // `getTexture` does. A third such handle joins the union by
            // declaring that method.
            let marker = Textured::luau();
            Type::Union(
                handles
                    .iter()
                    .filter(|handle| {
                        handle.methods.iter().any(|method| {
                            matches!(
                                &method.ty,
                                Type::Function { receiver: Some(receiver), .. }
                                    if **receiver == marker
                            )
                        })
                    })
                    .map(|handle| Type::Named(handle.spec.name))
                    .collect(),
            )
        },
    };
}
