//! The Luau checker over shipped and development sources and the checker fixtures.
//!
//! One case checks every shipped root and development source together and fails on any diagnostic,
//! lint warnings included, which `lunette check` would let through. The other
//! cases check the fixtures in `luau_check/`, which one `.luaurc` there gives
//! every module root: ones that must check cleanly, and ones whose mistakes
//! must be reported at an exact span, on an exact set of lines, or within line
//! ranges.
//!
//! `exit_status.rs` runs the relative-require fixture in a session. Each module
//! there answers where it is as a singleton type, so a require the checker
//! resolved to another file is a type error here.

use std::{
    fs,
    path::{Path, PathBuf},
};

use lunette::aliases::{install_manifest, installed_luaurc};
use lunette_lovr::analyze::{self, Kind, Report, Request};
use tempfile::TempDir;

#[test]
fn every_shipped_root_checks_without_diagnostics() {
    let root = repository();
    let mut paths = Vec::new();
    for directory in [
        "lua/lunette",
        "lua/lunette-plugin",
        "lua/lunette-contracts",
        "lua/lunette-plugins",
        "lua/lunette-desktop",
        "examples",
        "dev",
    ] {
        collect_sources(&root.join(directory), &mut paths);
    }
    paths.push(root.join("etc/xdg/lunette/main.luau"));
    paths.push(root.join("etc/xdg/lunette/conf.luau"));
    let report = check(paths);
    assert!(report.diagnostics.is_empty(), "{:#?}", report.diagnostics);
}

#[test]
fn clean_fixtures_check_without_diagnostics() {
    let report = check(
        [
            "luau_check/laser/recursive_definition.luau",
            "luau_check/keyboard/recursive_definition.luau",
            "luau_check/keyboard/mappings.luau",
            "luau_check/keyboard/visibility_positive.luau",
            "luau_check/frame/positive.luau",
            "luau_check/surface/positive.luau",
            "luau_check/surface/placement_positive.luau",
            "luau_check/focus/positive.luau",
            "luau_check/focus/source_positive.luau",
            "luau_check/ui/readonly_positive.luau",
            "luau_check/ui/receivers_positive.luau",
            "luau_check/ui/widgets_positive.luau",
            "luau_check/ui/pointer_positive.luau",
            "luau_check/ui/service_positive.luau",
            "luau_check/pass/ui-substitute.luau",
            "luau_check/ui/installed.luau",
            "luau_check/menu/positive.luau",
            "luau_check/keyboard-display/positive.luau",
            "luau_check/desktop-menu/positive.luau",
            "luau_check/native/default_seat_positive.luau",
            "fixtures/require-relative/lunette/main.luau",
            "luau_check/conf/supported.luau",
            "luau_check/rules/rules_positive.luau",
            "luau_check/authoring/positive.luau",
            "luau_check/authoring/recursive.luau",
            "luau_check/authoring/extra_keys.luau",
            "luau_check/simple_authoring/positive.luau",
            "luau_check/simple_authoring/runtime_guarantees.luau",
            "luau_check/schema/positive.luau",
            "luau_check/schema/collections.luau",
            "luau_check/schema/readonly.luau",
            "luau_check/schema/providers_positive.luau",
            "luau_check/schema/providers_readonly.luau",
            "luau_check/schema/pointing_overrides.luau",
            "luau_check/schema/workspace_input.luau",
            "luau_check/schema/layout_readonly.luau",
            "luau_check/inspection/positive.luau",
        ]
        .into_iter()
        .map(fixture)
        .collect(),
    );
    assert!(report.diagnostics.is_empty(), "{:#?}", report.diagnostics);
}

#[test]
fn frame_batches_and_events_reject_invalid_handlers_and_mutation() {
    assert_marked_lines(
        "luau_check/frame/negative.luau",
        include_str!("luau_check/frame/negative.luau"),
    );
}

#[test]
fn surfaces_and_pointer_events_reject_invalid_values_and_mutation() {
    assert_marked_lines(
        "luau_check/surface/negative.luau",
        include_str!("luau_check/surface/negative.luau"),
    );
}

#[test]
fn placement_settings_reject_invalid_callback_receivers_and_properties() {
    assert_marked_lines(
        "luau_check/surface/placement_negative.luau",
        include_str!("luau_check/surface/placement_negative.luau"),
    );
}

#[test]
fn focus_targets_receivers_and_notifications_reject_invalid_types_and_mutation() {
    assert_marked_lines(
        "luau_check/focus/negative.luau",
        include_str!("luau_check/focus/negative.luau"),
    );
}

#[test]
fn focus_sources_require_valid_activations_and_result_narrowing() {
    assert_marked_lines(
        "luau_check/focus/source_negative.luau",
        include_str!("luau_check/focus/source_negative.luau"),
    );
}

#[test]
fn keyboard_visibility_rejects_invalid_reasons_callbacks_and_mutation() {
    assert_marked_lines(
        "luau_check/keyboard/visibility_negative.luau",
        include_str!("luau_check/keyboard/visibility_negative.luau"),
    );
}

#[test]
fn menu_actions_updates_and_results_reject_invalid_types_and_mutation() {
    assert_marked_lines(
        "luau_check/menu/negative.luau",
        include_str!("luau_check/menu/negative.luau"),
    );
}

#[test]
fn desktop_menu_settings_reject_invalid_geometry_and_mutation() {
    assert_marked_lines(
        "luau_check/desktop-menu/negative.luau",
        include_str!("luau_check/desktop-menu/negative.luau"),
    );
}

#[test]
fn keyboard_display_changes_and_receivers_reject_invalid_types_and_mutation() {
    assert_marked_lines(
        "luau_check/keyboard-display/negative.luau",
        include_str!("luau_check/keyboard-display/negative.luau"),
    );
}

#[test]
fn ui_readonly_records_reject_mutation_and_writable_substitution() {
    assert_marked_lines(
        "luau_check/ui/readonly_negative.luau",
        include_str!("luau_check/ui/readonly_negative.luau"),
    );
}

#[test]
fn ui_public_methods_reject_wrong_receivers() {
    assert_marked_lines(
        "luau_check/ui/receivers_negative.luau",
        include_str!("luau_check/ui/receivers_negative.luau"),
    );
}

#[test]
fn ui_widgets_reject_invalid_options_and_callbacks() {
    assert_marked_lines(
        "luau_check/ui/widgets_negative.luau",
        include_str!("luau_check/ui/widgets_negative.luau"),
    );
}

#[test]
fn ui_regions_require_pointer_event_discrimination() {
    assert_marked_lines(
        "luau_check/ui/pointer_negative.luau",
        include_str!("luau_check/ui/pointer_negative.luau"),
    );
}

#[test]
fn ui_modules_resolve_from_installed_manifest_roots() {
    let installation = TempDir::with_prefix("lunette-ui-installed-")
        .unwrap_or_else(|error| panic!("installed roots: temporary directory: {error}"));
    for entry in install_manifest().lines() {
        let (source, destination) = entry
            .split_once('\t')
            .unwrap_or_else(|| panic!("installed roots: malformed manifest entry: {entry}"));
        copy_install_artifact(
            &repository().join(source),
            &installation.path().join(destination),
        );
    }
    assert!(!installation.path().join("lua/testing").exists());
    assert!(
        installation
            .path()
            .join("lua/lunette-contracts/ui.luau")
            .is_file()
    );
    assert!(
        installation
            .path()
            .join("lua/lunette-plugins/ui/init.luau")
            .is_file()
    );
    let configuration = installation.path().join("configuration");
    fs::create_dir_all(&configuration)
        .unwrap_or_else(|error| panic!("installed roots: configuration directory: {error}"));
    fs::write(configuration.join(".luaurc"), installed_luaurc("../lua"))
        .unwrap_or_else(|error| panic!("installed roots: configuration aliases: {error}"));
    let source = configuration.join("main.luau");
    fs::write(&source, include_str!("luau_check/ui/installed.luau"))
        .unwrap_or_else(|error| panic!("installed roots: configuration source: {error}"));
    let request = Request::new(
        Some(installation.path().join("definitions.luau")),
        vec![source],
    );
    let report = analyze::check(&request)
        .unwrap_or_else(|error| panic!("installed roots: checker: {error}"));
    assert!(
        report.skipped(&request).is_empty(),
        "{:#?}",
        report.skipped(&request)
    );
    assert!(report.diagnostics.is_empty(), "{:#?}", report.diagnostics);
}

#[test]
fn native_default_seat_requires_optional_narrowing_and_rejects_mutation() {
    assert_marked_lines(
        "luau_check/native/default_seat_negative.luau",
        include_str!("luau_check/native/default_seat_negative.luau"),
    );
}

#[test]
fn linked_modules_keep_relative_paths_and_use_the_targets_alias_directory() {
    let report = check(vec![fixture("luau_check/navigation/main.luau")]);
    assert!(report.diagnostics.is_empty(), "{:#?}", report.diagnostics);
}

#[test]
fn ambiguous_missing_and_nonmodule_paths_are_rejected() {
    let report = check(vec![fixture("luau_check/navigation/ambiguous.luau")]);
    assert_eq!(report.diagnostics.len(), 5, "{:#?}", report.diagnostics);
    for (line, diagnostic) in (1..=5).zip(&report.diagnostics) {
        assert_eq!(diagnostic.kind, Kind::TypeError);
        assert_eq!(diagnostic.line, line);
        assert_eq!(diagnostic.message, "Unknown require: unsupported path");
    }
}

#[test]
fn linked_aliases_preserve_component_and_prefix_rejections() {
    for path in [
        "luau_check/navigation/target/invalid.luau",
        "luau_check/navigation/nested/linked/invalid.luau",
    ] {
        let report = check(vec![fixture(path)]);
        assert_eq!(
            report.diagnostics.len(),
            4,
            "{path}: {:#?}",
            report.diagnostics
        );
        for (line, diagnostic) in (1..=4).zip(&report.diagnostics) {
            assert_eq!(diagnostic.kind, Kind::TypeError);
            assert_eq!(diagnostic.line, line);
            assert_eq!(diagnostic.message, "Unknown require: unsupported path");
        }
    }
}

#[test]
fn linked_configurations_preserve_quoted_directory_names() {
    let report = check(vec![fixture(
        "luau_check/navigation/nested/quoted/main.luau",
    )]);
    assert!(report.diagnostics.is_empty(), "{:#?}", report.diagnostics);
}

#[test]
fn linked_directory_alias_endpoints_keep_the_selected_init_module() {
    for path in [
        "luau_check/navigation/target/endpoint.luau",
        "luau_check/navigation/nested/linked/endpoint.luau",
    ] {
        let report = check(vec![fixture(path)]);
        assert!(
            report.diagnostics.is_empty(),
            "{path}: {:#?}",
            report.diagnostics
        );
    }
}

#[test]
fn invalid_configuration_fields_types_and_enums_are_rejected() {
    let report = check(vec![fixture("luau_check/conf/invalid.luau")]);
    let source = include_str!("luau_check/conf/invalid.luau");
    let sites: Vec<_> = source
        .lines()
        .enumerate()
        .filter_map(|(index, text)| text.contains("-- reject.").then_some(index as u32 + 1))
        .collect();
    assert_eq!(
        report.diagnostics.len(),
        sites.len(),
        "{:#?}",
        report.diagnostics
    );
    for line in sites {
        let diagnostics: Vec<_> = report
            .diagnostics
            .iter()
            .filter(|diagnostic| diagnostic.line == line && diagnostic.kind == Kind::TypeError)
            .collect();
        assert_eq!(
            diagnostics.len(),
            1,
            "line {line}: {:#?}",
            report.diagnostics
        );
        assert!(!diagnostics[0].message.contains("too complex"));
    }
}

/// A configure patch is checked against its definition's options, the type
/// inferred from the definition or factory: the correct calls report nothing,
/// and each incorrect call is reported on its own line.
#[test]
fn a_configure_patch_is_checked_against_its_definitions_options() {
    let report = check(vec![fixture("luau_check/desktop/configure_checked.luau")]);
    let mut lines = report
        .diagnostics
        .iter()
        .filter(|diagnostic| diagnostic.module.ends_with("configure_checked.luau"))
        .map(|diagnostic| diagnostic.line)
        .collect::<Vec<_>>();
    lines.sort_unstable();
    lines.dedup();
    assert_eq!(
        lines,
        [38, 39, 40, 41, 42, 43, 44, 45],
        "{:#?}",
        report.diagnostics
    );
}

#[test]
fn entry_configuration_and_desktop_settings_reject_wrong_option_types() {
    let name = "entry_settings_checked.luau";
    let source = include_str!("luau_check/desktop/entry_settings_checked.luau");
    let report = check(vec![fixture(
        "luau_check/desktop/entry_settings_checked.luau",
    )]);
    let expected = source
        .lines()
        .enumerate()
        .filter(|(_, line)| line.contains("-- reject."))
        .map(|(index, _)| index + 1)
        .collect::<Vec<_>>();
    let mut actual = report
        .diagnostics
        .iter()
        .map(|diagnostic| {
            assert!(diagnostic.module.ends_with(name), "{diagnostic:#?}");
            assert!(!diagnostic.message.contains("too complex"));
            diagnostic.line as usize
        })
        .collect::<Vec<_>>();
    actual.sort_unstable();
    assert_eq!(actual, expected, "{:#?}", report.diagnostics);
}

#[test]
fn rules_predicates_and_evaluators_reject_misuse() {
    let name = "rules_negative.luau";
    let report = check(vec![fixture("luau_check/rules/rules_negative.luau")]);
    for (first, last) in [(2, 6), (7, 11), (12, 16), (17, 21), (22, 22)] {
        assert!(
            report.diagnostics.iter().any(|diagnostic| {
                diagnostic.module.ends_with(name)
                    && diagnostic.line <= last
                    && diagnostic.end_line >= first
            }),
            "missing diagnostic in lines {first}..={last}: {:#?}",
            report.diagnostics
        );
    }
    assert!(
        report
            .diagnostics
            .iter()
            .all(|d| d.module.ends_with(name) && (2..=22).contains(&d.line)),
        "unexpected diagnostics: {:#?}",
        report.diagnostics
    );
}

#[test]
fn invalid_owner_effect_and_configuration_sites_are_reported_exactly() {
    assert_rejections(
        "luau_check/authoring/negative.luau",
        include_str!("luau_check/authoring/negative.luau"),
        &[
            (10, 33, 10, 71),
            (11, 33, 11, 46),
            (12, 19, 12, 28),
            (13, 23, 13, 37),
            (14, 4, 14, 19),
            (15, 4, 15, 11),
            (20, 35, 20, 37),
            (22, 27, 22, 29),
            (29, 35, 29, 40),
        ],
    );
}

#[test]
fn plugin_handles_are_not_satisfied_by_tables_or_other_handles() {
    assert_rejections(
        "luau_check/authoring/opaque_handles.luau",
        include_str!("luau_check/authoring/opaque_handles.luau"),
        &[(5, 20, 5, 22), (6, 12, 6, 14), (7, 12, 7, 17)],
    );
}

#[test]
fn malformed_declarations_are_reported_exactly() {
    assert_rejections(
        "luau_check/authoring/malformed.luau",
        include_str!("luau_check/authoring/malformed.luau"),
        &[(4, 52, 4, 59), (5, 45, 5, 72), (6, 63, 6, 65)],
    );
}

/// `plugin.capability` without `<<Service>>` checks as a `Capability<unknown>`,
/// which Luau accepts silently; the checker reports the call that made it.
#[test]
fn a_capability_without_its_service_type_is_reported_at_the_call() {
    assert_rejections(
        "luau_check/authoring/unnamed_service.luau",
        include_str!("luau_check/authoring/unnamed_service.luau"),
        &[(5, 16, 5, 74)],
    );
}

#[test]
fn per_capability_authoring_rejects_misuse_of_real_contracts() {
    assert_rejections(
        "luau_check/simple_authoring/negative.luau",
        include_str!("luau_check/simple_authoring/negative.luau"),
        &[
            (20, 39, 20, 41),
            (21, 41, 25, 5),
            (26, 41, 26, 54),
            (27, 33, 27, 52),
            (28, 34, 28, 48),
            (29, 35, 29, 47),
            (31, 19, 31, 21),
            (32, 21, 32, 30),
            (33, 38, 33, 43),
            (34, 33, 34, 45),
            (37, 39, 37, 45),
            (38, 8, 38, 29),
            (44, 41, 44, 58),
            (45, 51, 45, 68),
            (47, 34, 47, 36),
            (49, 16, 49, 54),
            (50, 38, 50, 40),
        ],
    );
}

#[test]
fn schema_types_preserve_nested_defaults_callbacks_and_configure_inputs() {
    assert_schema_lines(
        "luau_check/schema/negative.luau",
        &[
            (3, "number?"),
            (4, "missing field 'label'"),
            (5, "missing fields"),
            (6, "string?"),
            (7, "number?"),
            (8, "number"),
            (12, "(string) -> number"),
            (16, "vector?"),
            (17, "\"left\" | \"right\""),
            (18, "number?"),
            (21, "(string) -> number"),
            (25, "number"),
            (26, "number"),
            (27, "\"left\""),
            (33, "number"),
            (36, "\"quiet\""),
        ],
    );
}

#[test]
fn schema_map_input_output_and_nested_projection_reject_wrong_values() {
    assert_schema_lines(
        "luau_check/schema/collections_negative.luau",
        &[(5, "string"), (6, "string"), (7, "number"), (10, "string")],
    );
}

#[test]
fn schema_outputs_metadata_and_error_paths_reject_mutation() {
    assert_schema_lines(
        "luau_check/schema/readonly_negative.luau",
        &[
            (3, "read-only"),
            (4, "read-only"),
            (5, "read-only"),
            (6, "read-only"),
            (9, "read-only"),
            (12, "read-only"),
            (14, "read-only"),
        ],
    );
}

#[test]
fn immutable_runtime_snapshot_lists_reject_assignment_removal_and_writable_substitution() {
    for (path, first, last) in [
        ("luau_check/inspection/assignment.luau", 5, 15),
        ("luau_check/inspection/removal.luau", 5, 11),
        ("luau_check/inspection/writable_substitution.luau", 17, 22),
    ] {
        let report = check(vec![fixture(path)]);
        assert_eq!(
            report.diagnostics.len(),
            (last - first + 1) as usize,
            "{path}: {:#?}",
            report.diagnostics
        );
        for (line, diagnostic) in (first..=last).zip(&report.diagnostics) {
            assert_eq!(diagnostic.kind, Kind::TypeError);
            assert_eq!(diagnostic.line, line, "{path}: {diagnostic:#?}");
            assert!(
                diagnostic.message.contains("read-only") || diagnostic.message.contains("{read"),
                "{path}: {diagnostic:#?}"
            );
        }
    }
}

#[test]
fn provider_schemas_reject_invalid_fields_vectors_enums_and_callbacks() {
    assert_schema_lines(
        "luau_check/schema/providers_negative.luau",
        &[
            (9, "number"),
            (10, "pinch"),
            (11, "warp"),
            (12, "boolean"),
            (13, "number"),
            (14, "number"),
            (15, "vector"),
            (16, "missing"),
            (17, "missing"),
            (20, "number"),
            (25, "number"),
        ],
    );
}

#[test]
fn desktop_settings_preserve_writable_inputs_and_readonly_outputs() {
    assert_marked_lines(
        "luau_check/schema/desktop_settings_checked.luau",
        include_str!("luau_check/schema/desktop_settings_checked.luau"),
    );
}

#[test]
fn manager_settings_preserve_writable_inputs_and_readonly_outputs() {
    assert_schema_lines(
        "luau_check/schema/manager_settings_checked.luau",
        &[(9, "read-only"), (11, "read-only"), (12, "boolean")],
    );
}

#[test]
fn workspace_settings_reject_nested_assignment_and_list_replacement() {
    assert_schema_lines(
        "luau_check/schema/workspace_readonly.luau",
        &[(4, "Property name"), (5, "Property indexer")],
    );
}

fn assert_marked_lines(path: &str, source: &str) {
    let expected = source
        .lines()
        .enumerate()
        .filter(|(_, line)| line.contains("-- reject."))
        .map(|(index, _)| index as u32 + 1)
        .collect::<Vec<_>>();
    assert!(
        !expected.is_empty(),
        "fixture has no rejection markers: {path}"
    );
    let report = check(vec![fixture(path)]);
    let mut actual = report
        .diagnostics
        .iter()
        .map(|diagnostic| {
            assert_eq!(diagnostic.kind, Kind::TypeError, "{diagnostic:#?}");
            assert!(diagnostic.module.ends_with(path), "{diagnostic:#?}");
            assert!(!diagnostic.message.contains("too complex"));
            diagnostic.line
        })
        .collect::<Vec<_>>();
    actual.sort_unstable();
    assert_eq!(actual, expected, "{:#?}", report.diagnostics);
}

fn assert_schema_lines(path: &str, sites: &[(u32, &str)]) {
    let report = check(vec![fixture(path)]);
    assert_eq!(
        report.diagnostics.len(),
        sites.len(),
        "{:#?}",
        report.diagnostics
    );
    for (line, message) in sites {
        let matches = report
            .diagnostics
            .iter()
            .filter(|diagnostic| {
                diagnostic.kind == Kind::TypeError
                    && diagnostic.module.ends_with(path)
                    && diagnostic.line == *line
                    && diagnostic.message.contains(message)
                    && (!message.starts_with("Property ")
                        || diagnostic.message.contains("is read-only"))
                    && !diagnostic.message.contains("too complex")
            })
            .count();
        assert_eq!(
            matches, 1,
            "missing {message} at line {line}: {:#?}",
            report.diagnostics
        );
    }
}

/// Checks that the fixture's diagnostics are exactly its `-- reject: ` markers:
/// one type error per marker, at the expected span, carrying the marker's text.
fn assert_rejections(path: &str, source: &str, spans: &[(u32, u32, u32, u32)]) {
    let report = check(vec![fixture(path)]);
    let sites: Vec<_> = source
        .lines()
        .enumerate()
        .filter_map(|(line, text)| {
            text.split_once("-- reject: ")
                .map(|(_, message)| (line as u32 + 1, message.trim_end_matches('.')))
        })
        .collect();
    assert_eq!(sites.len(), spans.len(), "{:#?}", report.diagnostics);
    assert_eq!(
        report.diagnostics.len(),
        spans.len(),
        "{:#?}",
        report.diagnostics
    );
    for ((line, message), expected_span) in sites.iter().zip(spans) {
        assert_eq!(*line, expected_span.2, "rejection marker moved");
        let matches = report
            .diagnostics
            .iter()
            .filter(|diagnostic| {
                diagnostic.kind == Kind::TypeError
                    && diagnostic.module.ends_with(path)
                    && (
                        diagnostic.line,
                        diagnostic.column,
                        diagnostic.end_line,
                        diagnostic.end_column,
                    ) == *expected_span
                    && diagnostic.message.contains(message)
                    && !diagnostic.message.contains("too complex")
            })
            .count();
        assert_eq!(
            matches, 1,
            "missing {message} at {expected_span:?}: {:#?}",
            report.diagnostics
        );
    }
}

fn check(paths: Vec<PathBuf>) -> Report {
    let request = Request::new(
        Some(repository().join("etc/lunette/definitions.luau")),
        paths,
    );
    let report = analyze::check(&request).unwrap_or_else(|error| panic!("checker: {error}"));
    assert!(
        report.skipped(&request).is_empty(),
        "requested modules skipped: {:#?}",
        report.skipped(&request)
    );
    report
}

fn collect_sources(directory: &Path, paths: &mut Vec<PathBuf>) {
    let mut entries: Vec<_> = fs::read_dir(directory)
        .unwrap_or_else(|error| panic!("{}: {error}", directory.display()))
        .map(|entry| {
            entry
                .unwrap_or_else(|error| panic!("{}: {error}", directory.display()))
                .path()
        })
        .collect();
    entries.sort();
    for path in entries {
        if path.is_dir() {
            // Test files are not checked; CONTRIBUTING.md records why.
            if path.file_name().is_some_and(|name| name == "tests") {
                continue;
            }
            collect_sources(&path, paths);
        } else if path
            .extension()
            .is_some_and(|extension| extension == "luau")
        {
            paths.push(path);
        }
    }
}

fn copy_install_artifact(source: &Path, destination: &Path) {
    if source.is_dir() {
        fs::create_dir_all(destination)
            .unwrap_or_else(|error| panic!("installed roots: {}: {error}", destination.display()));
        let mut sources = Vec::new();
        collect_sources(source, &mut sources);
        for path in sources {
            let relative = path
                .strip_prefix(source)
                .unwrap_or_else(|error| panic!("installed roots: {}: {error}", path.display()));
            copy_install_artifact(&path, &destination.join(relative));
        }
        return;
    }
    let parent = destination
        .parent()
        .unwrap_or_else(|| panic!("installed roots: {} has no parent", destination.display()));
    fs::create_dir_all(parent)
        .unwrap_or_else(|error| panic!("installed roots: {}: {error}", parent.display()));
    fs::copy(source, destination).unwrap_or_else(|error| {
        panic!(
            "installed roots: {} to {}: {error}",
            source.display(),
            destination.display()
        )
    });
}

fn fixture(path: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join(path)
}

fn repository() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..")
}
