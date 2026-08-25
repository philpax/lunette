//! Declaring a closed set together with the names it is known by.
//!
//! A set whose members are listed twice is a set that drifts: the list and the
//! names are written apart, a variant is added to one, and the other is quietly
//! short. Every consumer here derives from the declaration, so adding a member
//! is one line and there is nowhere for a second list to go stale.
//!
//! Naming rather than projection, because not every closed set reaches Lua. A
//! DRM connector kind has names and no Luau type; one that does reach Lua says
//! so beside itself, in one line, from [`NAMES`](crate::Type::literals).

/// Declares an enum and the names its members are known by.
///
/// Generates `ALL`, `NAMES`, `as_str`, `from_name`, and [`Display`]. The enum
/// must derive [`Copy`], because `as_str` takes its receiver by value.
///
/// ```
/// lunette_luau::closed_set! {
///     /// Which pipeline a sink's events travel.
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

            /// The name this member is known by.
            #[must_use]
            pub const fn as_str(self) -> &'static str {
                match self {
                    $(Self::$variant => $spelling,)+
                }
            }

            /// The member a name refers to, rejecting anything else.
            ///
            /// `None` rather than a default: an unrecognised name is a typo,
            /// and a member that silently stands in for one is harder to find
            /// than an error.
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
    use crate::Type;

    closed_set! {
        /// A set with the shapes a real declaration has: a default, a doc
        /// comment per member, and a name that is not the variant lowercased.
        #[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
        pub enum Sample {
            /// The one a missing value means.
            #[default]
            None = "none",
            /// A name Rust cannot spell as an identifier.
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
    fn the_lists_agree_with_the_names() {
        let named: Vec<&str> = Sample::ALL.iter().map(|member| member.as_str()).collect();
        assert_eq!(named, Sample::NAMES);
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
    fn the_default_is_the_member_that_asked_for_it() {
        assert_eq!(Sample::default(), Sample::None);
    }

    #[test]
    fn display_is_the_name() {
        assert_eq!(Sample::CapsLock.to_string(), "capsLock");
    }

    /// The reason a set declared this way can be projected in one line.
    #[test]
    fn the_names_are_what_a_luau_union_is_built_from() {
        assert_eq!(
            Type::literals(Sample::NAMES).to_string(),
            "'none' | 'capsLock' | 'video'"
        );
    }
}
