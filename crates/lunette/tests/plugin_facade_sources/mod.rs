//! The plugin facade's modules, for a harness that preloads them by name
//! rather than walking the roots.

/// The facade's modules, by the name each is required by.
pub const FACADE_SOURCES: [(&str, &str); 4] = [
    (
        "@lunette-plugin",
        include_str!("../../../../lua/lunette-plugin/init.lua"),
    ),
    (
        "@lunette-plugin/adapter",
        include_str!("../../../../lua/lunette-plugin/adapter.lua"),
    ),
    (
        "@lunette-plugin/options",
        include_str!("../../../../lua/lunette-plugin/options.lua"),
    ),
    (
        "@lunette-plugin/provider",
        include_str!("../../../../lua/lunette-plugin/provider.lua"),
    ),
];
