//! Linux-only: resolves runtime manifests from supplied configuration without environment reads.
//! Monado requires the loader to accept the selected manifest through `XR_RUNTIME_JSON`.

mod discovery;

use std::ffi::OsStr;

// Unknown spellings fail closed rather than relying on a runtime fork's option parser.
pub fn monado_stage_unmapped(setting: Option<&OsStr>) -> bool {
    match setting {
        None => true,
        Some(value) => value == OsStr::new("0") || value == OsStr::new("false"),
    }
}

pub use discovery::{
    Architecture, Environment, EnvironmentConfig, LoaderConfig, SearchConfig, SystemFileSystem,
    select_manifest,
};

#[cfg(test)]
mod tests;
