//! Nil and Textured are the two markers that stand for a Luau type no value
//! carries.
//!
//! Everything else comes from [`lunette_luau`]: the leaves, the containers, and
//! the tuples are stated once there, and a handle's name comes from the
//! [`Typed`] impl that its `handle!` block generates.

use lunette_luau::{Type, Typed};

use crate::lua::declarations::{AliasSpec, Aliased};

/// A value Lua never receives. It is the type of the arm of a
/// discriminated handle that carries none.
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
            // A handle carries pixels exactly when one of its methods names
            // this as its receiver, as `getTexture` does. A third such handle
            // joins the union by declaring that method.
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
