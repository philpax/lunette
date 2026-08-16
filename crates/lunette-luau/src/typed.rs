//! What a Rust type is seen as in Luau.
//!
//! Rust has no reflection, so the mapping is written out: one impl per type
//! that crosses into Lua. A leaf appears here and nowhere else, which is what
//! lets every signature be derived rather than restated.

use std::collections::HashMap;

use crate::expression::Type;

/// The Luau type a value of this Rust type is seen as.
pub trait Typed {
    fn luau() -> Type;
}

/// The types of an argument tuple, in order.
///
/// Separate from [`Typed`] because a tuple of arguments is a list of types
/// rather than one type: `(f64, f64)` reaches Lua as two arguments, not as one
/// value of type `(number, number)`.
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

/// Returning nothing, which Luau writes as an empty tuple.
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
/// Behind the feature so that a crate naming its Luau types does not link a Lua
/// binding to do it.
#[cfg(feature = "mlua")]
mod lua {
    use mlua::{LuaString, UserDataRef};

    use crate::{expression::Type, typed::Typed};

    impl Typed for LuaString {
        fn luau() -> Type {
            Type::STRING
        }
    }

    /// A handle borrowed from Lua is seen as the handle.
    impl<T: Typed + 'static> Typed for UserDataRef<T> {
        fn luau() -> Type {
            T::luau()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_number_is_a_number_however_it_is_spelled_in_rust() {
        assert_eq!(of::<f64>().to_string(), "number");
        assert_eq!(of::<u32>().to_string(), "number");
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

    #[test]
    fn nothing_is_an_empty_tuple() {
        assert_eq!(of::<()>().to_string(), "()");
    }
}
