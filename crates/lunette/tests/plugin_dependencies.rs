//! Validates supported plugin imports against the maintained source inventory.

use std::path::Path;

#[path = "support/plugin_dependencies/documentation_tests.rs"]
mod documentation_tests;
#[path = "support/plugin_dependencies/parser_tests.rs"]
mod parser_tests;
#[path = "support/plugin_dependencies/mod.rs"]
mod plugin_dependencies;
#[path = "support/plugin_dependencies/policy_tests.rs"]
mod policy_tests;

#[test]
fn repository_hierarchy_matches_catalog() -> Result<(), Box<dyn std::error::Error>> {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
    let report = plugin_dependencies::scan::repository_scan(&root)?;
    assert!(report.hierarchy.is_empty(), "{report}");
    Ok(())
}

#[test]
fn repository_dependency_boundaries() -> Result<(), Box<dyn std::error::Error>> {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
    let report = plugin_dependencies::scan::repository_scan(&root)?;
    assert!(report.dependencies.is_empty(), "{report}");
    assert!(!report.sources.is_empty(), "source inventory is empty");
    assert!(
        report.observation_count > 0,
        "parser returned no loader observations"
    );
    Ok(())
}
