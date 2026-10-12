//! How a Rust type maps to a Luau type.
//!
//! Rust has no reflection. One impl per type that crosses into Lua states the
//! mapping, and a leaf appears here and nowhere else. Every signature derives
//! from this mapping, and nothing is restated.

use std::collections::HashMap;

use crate::expression::Type;

/// The Luau type for a value of this Rust type.
pub trait Typed {
    fn luau() -> Type;
}

/// The types of an argument tuple, in order.
///
/// Separate from [`Typed`] because a tuple of arguments is a list of types.
/// `(f64, f64)` reaches Lua as two arguments, and a single argument never has
/// the type `(number, number)`.
pub trait Arguments {
    fn luau() -> Vec<Type>;
}

/// [`Typed::luau`] as a function, for the places a type is named where a turbofish
/// cannot be written.
#[must_use]
pub fn of<T: Typed>() -> Type {
    T::luau()
}

macro_rules! leaf {
    ($($rust:ty => $luau:expr),* $(,)?) => {
        $(
            impl Typed for $rust {
                fn luau() -> Type {
                    $luau
                }
            }
        )*
    };
}

leaf! {
    bool => Type::BOOLEAN,
    f32 => Type::NUMBER,
    f64 => Type::NUMBER,
    i32 => Type::NUMBER,
    i64 => Type::NUMBER,
    u32 => Type::NUMBER,
    u64 => Type::NUMBER,
    usize => Type::NUMBER,
    String => Type::STRING,
    &'static str => Type::STRING,
}

impl<T: Typed> Typed for Option<T> {
    fn luau() -> Type {
        T::luau().optional()
    }
}

impl<T: Typed> Typed for Vec<T> {
    fn luau() -> Type {
        T::luau().array()
    }
}

impl<K: Typed, V: Typed> Typed for HashMap<K, V> {
    fn luau() -> Type {
        Type::map(K::luau(), V::luau())
    }
}

/// The empty tuple is the Luau type for returning nothing.
impl Typed for () {
    fn luau() -> Type {
        Type::Tuple(Vec::new())
    }
}

impl Arguments for () {
    fn luau() -> Vec<Type> {
        Vec::new()
    }
}

macro_rules! tuples {
    ($(($($member:ident),+)),* $(,)?) => {
        $(
            impl<$($member: Typed),+> Typed for ($($member,)+) {
                fn luau() -> Type {
                    Type::Tuple(vec![$($member::luau()),+])
                }
            }

            impl<$($member: Typed),+> Arguments for ($($member,)+) {
                fn luau() -> Vec<Type> {
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

/// The impls for mlua's own types.
///
/// The `mlua` feature gates this module. A crate that names its Luau types
/// does not link a Lua binding.
#[cfg(feature = "mlua")]
mod lua {
    use mlua::{Buffer, LuaString, UserDataRef};

    use crate::{expression::Type, typed::Typed};

    impl Typed for LuaString {
        fn luau() -> Type {
            Type::STRING
        }
    }

    impl Typed for Buffer {
        fn luau() -> Type {
            Type::BUFFER
        }
    }

    /// A handle borrowed from Lua has the Luau type of the value it borrows.
    impl<T: Typed + 'static> Typed for UserDataRef<T> {
        fn luau() -> Type {
            T::luau()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(feature = "mlua")]
    #[test]
    fn an_mlua_buffer_maps_to_the_luau_builtin_buffer_type() {
        assert_eq!(of::<mlua::Buffer>().to_string(), "buffer");
        assert_eq!(of::<Option<mlua::Buffer>>().to_string(), "buffer?");
    }

    #[test]
    fn an_option_is_optional_and_a_vec_is_an_array() {
        assert_eq!(of::<Option<String>>().to_string(), "string?");
        assert_eq!(of::<Vec<String>>().to_string(), "{ string }");
    }

    #[test]
    fn a_map_carries_both_halves() {
        assert_eq!(
            of::<HashMap<String, bool>>().to_string(),
            "{ [string]: boolean }"
        );
    }

    #[test]
    fn an_optional_array_is_not_an_array_of_optionals() {
        assert_eq!(of::<Option<Vec<String>>>().to_string(), "{ string }?");
        assert_eq!(of::<Vec<Option<String>>>().to_string(), "{ string? }");
    }

    #[test]
    fn an_argument_tuple_is_a_list_rather_than_a_type() {
        let arguments = <(f64, Option<String>) as Arguments>::luau();
        let rendered: Vec<String> = arguments.iter().map(ToString::to_string).collect();
        assert_eq!(rendered, ["number", "string?"]);
        assert_eq!(
            of::<(f64, Option<String>)>().to_string(),
            "(number, string?)"
        );
    }
}
