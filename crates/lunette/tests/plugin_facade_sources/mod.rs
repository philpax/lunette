//! The plugin facade's modules, for a harness that preloads them by name
//! rather than walking the roots.

/// The facade's modules, by the name each is required by.
pub const FACADE_SOURCES: [(&str, &str); 5] = [
    (
        "@lunette-plugin",
        include_str!("../../../../lua/lunette-plugin/init.luau"),
    ),
    (
        "@lunette-plugin/adapter",
        include_str!("../../../../lua/lunette-plugin/adapter.luau"),
    ),
    (
        "@lunette-plugin/compose",
        include_str!("../../../../lua/lunette-plugin/compose.luau"),
    ),
    (
        "@lunette-plugin/options",
        include_str!("../../../../lua/lunette-plugin/options.luau"),
    ),
    (
        "@lunette-plugin/provider",
        include_str!("../../../../lua/lunette-plugin/provider.luau"),
    ),
];
