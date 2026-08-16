//! Declaring an enum together with the list of every member it has.
//!
//! Three enums here are enumerated at runtime: the keys and buttons a uinput
//! device declares at creation, and the transforms a `wl_output` names. Each
//! carried its members twice, once as variants and once as a list, and the
//! second copy is one nothing checks — 165 keys in `VirtualKey`'s case. A key
//! added to the enum and missed in the list is a key the virtual device never
//! declares, so `sink:key` refuses it and the kernel is never asked.
//!
//! The nameless sibling of `lunette_luau::closed_set!`. That macro is for a set
//! whose members are known outside Rust by a name, and generates the naming
//! machinery with the list; these are known by an integer the kernel or the
//! protocol assigns, and each keeps its own accessor for it, because
//! `from_evdev` and `from_wl_output` say which numbering they mean and
//! `from_code` would not. Those accessors are exhaustive matches, so the
//! compiler already holds them to the enum; it is only the list that needed a
//! declaration to derive from.

/// Declares an enum and the list of its members.
///
/// Generates `ALL`, in declaration order. Discriminants are passed through, so
/// an enum whose members carry the integer they travel as keeps it.
///
/// ```text
/// variants! {
///     /// A pointer button, by the evdev code it travels as.
///     #[derive(Clone, Copy, Debug, PartialEq, Eq)]
///     #[repr(u16)]
///     pub enum Button {
///         Left = 0x110,
///         Right = 0x111,
///     }
/// }
///
///
/// // Button::ALL is [Button::Left, Button::Right], and Button::Left as u16 is 0x110.
/// ```
macro_rules! variants {
    (
        $(#[$enum_meta:meta])*
        $vis:vis enum $name:ident {
            $(
                $(#[$variant_meta:meta])*
                $variant:ident $(= $discriminant:expr)?
            ),+ $(,)?
        }
    ) => {
        $(#[$enum_meta])*
        $vis enum $name {
            $(
                $(#[$variant_meta])*
                $variant $(= $discriminant)?,
            )+
        }

        impl $name {
            /// Every member, in the order they are declared.
            pub const ALL: &'static [Self] = &[$(Self::$variant),+];
        }
    };
}

#[cfg(test)]
mod tests {
    variants! {
        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        #[repr(u16)]
        pub enum Coded {
            /// Carries the number it travels as.
            First = 0x110,
            Second = 0x111,
        }
    }

    variants! {
        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub enum Plain {
            One,
            Two,
            Three,
        }
    }

    #[test]
    fn every_member_is_listed_once_in_declaration_order() {
        assert_eq!(Coded::ALL, [Coded::First, Coded::Second]);
        assert_eq!(Plain::ALL, [Plain::One, Plain::Two, Plain::Three]);
    }

    #[test]
    fn a_discriminant_survives_the_declaration() {
        assert_eq!(Coded::First as u16, 0x110);
        assert_eq!(Coded::Second as u16, 0x111);
    }
}
