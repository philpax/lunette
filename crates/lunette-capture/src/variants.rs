//! Declares enums with a runtime list of their members.
//!
//! The capture crate iterates its keys, buttons, and surface transforms at
//! runtime. Generating `ALL` from each enum keeps the list in declaration order.
//! Adding a member also adds it to the list.
//!
//! This macro is the local counterpart to `lunette_luau::closed_set!`. The
//! sibling macro derives names and string conversions; this macro supplies the
//! member slice and passes explicit discriminants through to the enum. Callers
//! define conversions for the external numbering they use.

/// Declares an enum and a slice containing every member.
///
/// Generates `ALL` in declaration order and passes explicit discriminants
/// through to the generated enum.
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
