//! Fonts for tests: the standard kinds' bundled faces, so text measures the same on
//! every machine. Tests in other crates reach them through the `test-fonts` feature.

use crate::text::Fonts;

/// Iosevka Regular, a monospace face, so every advance is the same.
pub const MONO: &[u8] = include_bytes!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../lua/lunette-plugins/ui/standard/fonts/Iosevka-Regular.ttf"
));

/// The family name of [`MONO`].
pub const MONO_FAMILY: &str = "Iosevka";

/// IBM Plex Sans Regular, a proportional face with combining marks.
pub const SANS: &[u8] = include_bytes!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../lua/lunette-plugins/ui/standard/fonts/IBMPlexSans-Regular.ttf"
));

/// The family name of [`SANS`].
pub const SANS_FAMILY: &str = "IBM Plex Sans";

/// A font set holding only [`MONO`].
#[must_use]
pub fn mono() -> Fonts {
    Fonts::bundled([MONO.to_vec()])
}
