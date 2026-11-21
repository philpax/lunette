use lunette_luau::closed_set;

closed_set! {
    /// The frame orientation carried across the capture boundary, with the
    /// name Lua reads it by.
    ///
    /// Undefined samples identically to Normal.
    #[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
    pub enum FrameTransform {
        Undefined = "undefined",
        #[default]
        Normal = "normal",
        Rotated90 = "rot90",
        Rotated180 = "rot180",
        Rotated270 = "rot270",
        Flipped = "flipped",
        Flipped90 = "flipped90",
        Flipped180 = "flipped180",
        Flipped270 = "flipped270",
    }
}
