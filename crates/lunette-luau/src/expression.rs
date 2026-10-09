//! A Luau type expression, and how it renders.
//!
//! A type is a structured value that code builds. It is not a string that
//! code formats with interpolation. A union interpolated into a string needs
//! parentheses when a `?` is added. Without the parentheses,
//! `(A) -> B?` is a function returning `B?`, not an optional function. A user
//! sees the mistake as a type error in their own configuration.

use std::fmt;

/// A type in Luau's syntax.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Type {
    /// A type named by an identifier: `Window`, `number`, `nil`.
    Named(&'static str),
    /// A string singleton: `'photo'`.
    Literal(&'static str),
    /// `T?`.
    Optional(Box<Type>),
    /// `A | B`.
    Union(Vec<Type>),
    /// `{ T }`.
    Array(Box<Type>),
    /// `{ read [number]: T }`. Its elements can be read but not assigned or removed.
    ReadonlyArray(Box<Type>),
    /// `{ [K]: V }`.
    Map { key: Box<Type>, value: Box<Type> },
    /// `(self: R, name: P) -> T`.
    Function {
        receiver: Option<Box<Type>>,
        parameters: Vec<Parameter>,
        returns: Box<Type>,
    },
    /// `(A, B)`. A function uses this type for an empty return and for a
    /// multi-value return.
    Tuple(Vec<Type>),
}

/// One named parameter of a [`Type::Function`].
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Parameter {
    pub name: &'static str,
    pub ty: Type,
}

impl Type {
    pub const BOOLEAN: Self = Self::Named("boolean");
    pub const NIL: Self = Self::Named("nil");
    pub const NUMBER: Self = Self::Named("number");
    pub const STRING: Self = Self::Named("string");

    /// `T?`.
    #[must_use]
    pub fn optional(self) -> Self {
        Self::Optional(Box::new(self))
    }

    /// `{ T }`.
    #[must_use]
    pub fn array(self) -> Self {
        Self::Array(Box::new(self))
    }

    /// `{ read [number]: T }`.
    #[must_use]
    pub fn readonly_array(self) -> Self {
        Self::ReadonlyArray(Box::new(self))
    }

    /// `{ [K]: V }`.
    #[must_use]
    pub fn map(key: Self, value: Self) -> Self {
        Self::Map {
            key: Box::new(key),
            value: Box::new(value),
        }
    }

    /// The union of a set of string singletons, which is how the code
    /// represents a closed set of names.
    #[must_use]
    pub fn literals(names: &[&'static str]) -> Self {
        Self::Union(names.iter().copied().map(Self::Literal).collect())
    }

    /// Whether this needs parentheses to be the operand of `?`.
    ///
    /// `A | B` and `(A) -> B` both bind looser than the postfix `?`. An
    /// optional of them is `(A | B)?`. Without the parentheses, `A | B?`
    /// parses as `A | (B?)`, which is a different type.
    const fn binds_looser_than_optional(&self) -> bool {
        matches!(
            self,
            Self::Union(_) | Self::Function { .. } | Self::Optional(_)
        )
    }

    /// Whether this needs parentheses to be a member of a union.
    ///
    /// A function type needs parentheses: `((A) -> B) | C`. An optional does
    /// not. `A | B?` is already the union that `(A | B)?` is.
    const fn binds_looser_than_union(&self) -> bool {
        matches!(self, Self::Function { .. })
    }

    fn render(&self, out: &mut String) {
        match self {
            Self::Named(name) => out.push_str(name),
            Self::Literal(name) => {
                out.push('\'');
                out.push_str(name);
                out.push('\'');
            }
            Self::Optional(inner) => {
                inner.render_parenthesised(out, Self::binds_looser_than_optional);
                out.push('?');
            }
            Self::Union(members) => render_joined(out, members, " | "),
            Self::Array(element) => {
                out.push_str("{ ");
                element.render(out);
                out.push_str(" }");
            }
            Self::ReadonlyArray(element) => {
                out.push_str("{ read [number]: ");
                element.render(out);
                out.push_str(" }");
            }
            Self::Map { key, value } => {
                out.push_str("{ [");
                key.render(out);
                out.push_str("]: ");
                value.render(out);
                out.push_str(" }");
            }
            Self::Function {
                receiver,
                parameters,
                returns,
            } => {
                out.push('(');
                let mut first = true;
                if let Some(receiver) = receiver {
                    out.push_str("self: ");
                    receiver.render(out);
                    first = false;
                }
                for parameter in parameters {
                    if !first {
                        out.push_str(", ");
                    }
                    first = false;
                    out.push_str(parameter.name);
                    out.push_str(": ");
                    parameter.ty.render(out);
                }
                out.push_str(") -> ");
                returns.render(out);
            }
            Self::Tuple(members) => {
                out.push('(');
                render_joined(out, members, ", ");
                out.push(')');
            }
        }
    }

    fn render_parenthesised(&self, out: &mut String, needs: fn(&Self) -> bool) {
        if needs(self) {
            out.push('(');
            self.render(out);
            out.push(')');
        } else {
            self.render(out);
        }
    }
}

impl fmt::Display for Type {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        let mut rendered = String::new();
        self.render(&mut rendered);
        formatter.write_str(&rendered)
    }
}

/// Renders each member, parenthesising the ones that bind looser than the
/// separator.
fn render_joined(out: &mut String, members: &[Type], separator: &str) {
    for (index, member) in members.iter().enumerate() {
        if index > 0 {
            out.push_str(separator);
        }
        member.render_parenthesised(out, Type::binds_looser_than_union);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_named_type_is_itself() {
        assert_eq!(Type::NUMBER.to_string(), "number");
    }

    #[test]
    fn a_literal_carries_its_quotes() {
        assert_eq!(Type::Literal("photo").to_string(), "'photo'");
    }

    #[test]
    fn an_optional_union_is_parenthesised() {
        let union = Type::Union(vec![Type::NUMBER, Type::STRING]);
        assert_eq!(union.clone().to_string(), "number | string");
        assert_eq!(union.optional().to_string(), "(number | string)?");
    }

    #[test]
    fn an_optional_function_is_parenthesised() {
        let function = Type::Function {
            receiver: None,
            parameters: Vec::new(),
            returns: Box::new(Type::BOOLEAN),
        };
        assert_eq!(function.clone().to_string(), "() -> boolean");
        assert_eq!(function.optional().to_string(), "(() -> boolean)?");
    }

    #[test]
    fn a_function_in_a_union_is_parenthesised() {
        let function = Type::Function {
            receiver: None,
            parameters: Vec::new(),
            returns: Box::new(Type::BOOLEAN),
        };
        assert_eq!(
            Type::Union(vec![function, Type::NIL]).to_string(),
            "(() -> boolean) | nil"
        );
    }

    #[test]
    fn an_optional_inside_a_union_needs_no_parentheses() {
        let union = Type::Union(vec![Type::NUMBER, Type::STRING.optional()]);
        assert_eq!(union.to_string(), "number | string?");
    }

    #[test]
    fn a_double_optional_is_parenthesised_rather_than_written_twice() {
        assert_eq!(Type::STRING.optional().optional().to_string(), "(string?)?");
    }

    #[test]
    fn a_container_needs_no_parentheses_around_its_element() {
        let union = Type::Union(vec![Type::NUMBER, Type::STRING]);
        assert_eq!(union.clone().array().to_string(), "{ number | string }");
        assert_eq!(
            Type::map(Type::STRING, union).to_string(),
            "{ [string]: number | string }"
        );
    }

    #[test]
    fn a_readonly_array_has_a_readonly_numeric_indexer() {
        let array = Type::NUMBER.readonly_array();
        assert_eq!(array, Type::ReadonlyArray(Box::new(Type::NUMBER)));
        assert_ne!(array, Type::NUMBER.array());
        assert_eq!(array.to_string(), "{ read [number]: number }");
        assert_eq!(array.optional().to_string(), "{ read [number]: number }?");
    }

    #[test]
    fn readonly_arrays_render_structured_elements_without_changing_their_meaning() {
        let union = Type::Union(vec![Type::NUMBER, Type::STRING]);
        assert_eq!(
            union.readonly_array().to_string(),
            "{ read [number]: number | string }"
        );
        let function = Type::Function {
            receiver: None,
            parameters: vec![Parameter {
                name: "values",
                ty: Type::STRING.readonly_array(),
            }],
            returns: Box::new(Type::BOOLEAN),
        };
        assert_eq!(
            function.readonly_array().to_string(),
            "{ read [number]: (values: { read [number]: string }) -> boolean }"
        );
        assert_eq!(
            Type::STRING.readonly_array().readonly_array().to_string(),
            "{ read [number]: { read [number]: string } }"
        );
    }

    #[test]
    fn a_method_names_its_receiver_first() {
        let method = Type::Function {
            receiver: Some(Box::new(Type::Named("Window"))),
            parameters: vec![
                Parameter {
                    name: "width",
                    ty: Type::NUMBER,
                },
                Parameter {
                    name: "height",
                    ty: Type::NUMBER,
                },
            ],
            returns: Box::new(Type::BOOLEAN),
        };
        assert_eq!(
            method.to_string(),
            "(self: Window, width: number, height: number) -> boolean"
        );
    }

    #[test]
    fn returning_nothing_and_returning_several_are_both_tuples() {
        assert_eq!(Type::Tuple(Vec::new()).to_string(), "()");
        assert_eq!(
            Type::Tuple(vec![Type::BOOLEAN, Type::STRING.optional()]).to_string(),
            "(boolean, string?)"
        );
    }

    #[test]
    fn a_closed_set_is_the_union_of_its_names() {
        assert_eq!(
            Type::literals(&["none", "photo"]).to_string(),
            "'none' | 'photo'"
        );
    }
}
