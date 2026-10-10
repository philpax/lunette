//! Declaring a closed set together with the names of its members.
//!
//! A set whose members are listed twice is written as two separate lists.
//! Adding a variant to one list does not add it to the other. Every consumer
//! derives from the declaration; adding a member is one line, and no second
//! list is updated manually.
//!
//! The macro records names and generates no Luau type, because not every
//! closed set is exposed to Lua. A DRM connector kind has names without a
//! Luau type. For a set exposed to Lua, one line beside the declaration
//! builds the union type from [`NAMES`](crate::Type::literals).

/// Declares an enum and the names of its members.
///
/// Generates `ALL`, `NAMES`, `as_str`, `from_name`, and [`Display`]. The enum
/// must derive [`Copy`], because `as_str` takes its receiver by value.
///
/// ```
/// lunette_luau::closed_set! {
///     /// Which pipeline a sink's events use.
///     #[derive(Clone, Copy, Debug, PartialEq, Eq)]
///     pub enum InputDomain {
///         /// A surface this compositor hosts.
///         Window = "window",
///         /// The host desktop.
///         Host = "host",
///     }
/// }
///
/// assert_eq!(InputDomain::NAMES, ["window", "host"]);
/// assert_eq!(InputDomain::from_name("host"), Some(InputDomain::Host));
/// assert_eq!(InputDomain::from_name("Host"), None);
/// ```
///
/// [`Display`]: std::fmt::Display
#[macro_export]
macro_rules! closed_set {
    (
        $(#[$enum_meta:meta])*
        $vis:vis enum $name:ident {
            $(
                $(#[$variant_meta:meta])*
                $variant:ident = $spelling:literal
            ),+ $(,)?
        }
    ) => {
        $(#[$enum_meta])*
        $vis enum $name {
            $(
                $(#[$variant_meta])*
                $variant,
            )+
        }

        impl $name {
            /// Every member, in the order they are declared.
            pub const ALL: &'static [Self] = &[$(Self::$variant),+];

            /// Every name, in the order they are declared.
            pub const NAMES: &'static [&'static str] = &[$($spelling),+];

            /// The name this member maps to.
            #[must_use]
            pub const fn as_str(self) -> &'static str {
                match self {
                    $(Self::$variant => $spelling,)+
                }
            }

            /// The member a name refers to, rejecting anything else.
            ///
            /// An unrecognised name is a typo, and `from_name` returns `None` for it.
            /// A default member would substitute for the typo, and the substitution is
            /// harder to find than an error.
            #[must_use]
            pub fn from_name(name: &str) -> Option<Self> {
                Self::ALL
                    .iter()
                    .copied()
                    .find(|member| member.as_str() == name)
            }
        }

        impl ::std::fmt::Display for $name {
            fn fmt(&self, formatter: &mut ::std::fmt::Formatter<'_>) -> ::std::fmt::Result {
                formatter.write_str(self.as_str())
            }
        }
    };
}

#[cfg(test)]
mod tests {
    closed_set! {
        /// A set with the properties a declaration can have: a default member, a doc
        /// comment per member, and a spelling that differs from the lowercased variant name.
        #[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
        pub enum Sample {
            /// The member a missing value maps to.
            #[default]
            None = "none",
            /// A name Rust cannot write as an identifier.
            CapsLock = "capsLock",
            Video = "video",
        }
    }

    #[test]
    fn every_member_is_listed_once_in_declaration_order() {
        assert_eq!(Sample::ALL, [Sample::None, Sample::CapsLock, Sample::Video]);
        assert_eq!(Sample::NAMES, ["none", "capsLock", "video"]);
    }

    #[test]
    fn every_name_round_trips_and_nothing_else_parses() {
        for member in Sample::ALL {
            assert_eq!(Sample::from_name(member.as_str()), Some(*member));
        }
        assert_eq!(Sample::from_name("caps_lock"), None);
        assert_eq!(Sample::from_name(""), None);
    }

    #[test]
    fn display_is_the_name() {
        assert_eq!(Sample::CapsLock.to_string(), "capsLock");
    }
}
