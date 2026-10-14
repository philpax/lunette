//! Pure fixtures for ownership, dependency failures, and resolution inventories.

use std::{
    collections::{BTreeMap, BTreeSet},
    fs,
    path::{Path, PathBuf},
};

use lunette_lovr::analyze::{MemberCallObservation, RequireObservation, RequireOutcome};

use crate::plugin_dependencies::{
    catalog::{
        CONFIGURATION_SWITCHES, CONFIGURED_LOADS, CONTRACT_SCHEMAS, EXTENSION_SUPPORT,
        LibraryDomain, WHITEBOX_EDGES,
    },
    ownership::{Owner, Ownership, Role, Visibility, ownership, public_plugin_files},
    policy::{
        Edge, check_edge, check_observation, check_preloaded, configuration_switch_diagnostics,
        configured_load_diagnostics, cycle_diagnostics, hierarchy_diagnostics,
    },
    scan::{
        canonical_owner_diagnostics, context_use_diagnostics, installed_scan, request,
        resolution_context,
    },
};

fn permits(source: &str, target: &str) -> Result<(), String> {
    let source_path = Path::new(source);
    let target_path = Path::new(target);
    let source = ownership(source_path)?;
    let target = ownership(target_path)?;
    check_edge(&Edge {
        source_path,
        source: &source,
        target_path,
        target: &target,
        installed: false,
    })
}

fn observed(outcome: RequireOutcome) -> RequireObservation {
    RequireObservation {
        line: 7,
        column: 3,
        requested: Some("./module".into()),
        outcome,
    }
}

#[test]
fn policy_allows_own_private_and_declared_public_exports() {
    for source in [
        "init.luau",
        "config.luau",
        "tests/pacer.luau",
        "private/pacer.luau",
    ] {
        assert!(
            permits(
                &format!("lua/lunette-plugins/pacing/service/{source}"),
                "lua/lunette-plugins/pacing/service/private/state.luau"
            )
            .is_ok()
        );
    }
}

#[test]
fn cross_owner_private_imports_fail_for_all_callers() {
    for source in [
        "lua/lunette-plugins/pacing/controller/init.luau",
        "lua/lunette-plugins/pacing/controller/config.luau",
        "lua/lunette-plugins/pacing/controller/tests/state.luau",
        "lua/lunette-desktop/settings.luau",
        "examples/desktop/main.luau",
        "dev/plugins/sample/init.luau",
        "crates/lunette/tests/graphics/fixtures/support/theme.luau",
    ] {
        assert!(
            permits(
                source,
                "lua/lunette-plugins/pacing/service/private/state.luau"
            )
            .is_err(),
            "{source}"
        );
        assert!(
            permits(source, "lua/lunette-plugins/pacing/service/init.luau").is_ok(),
            "{source}"
        );
        assert!(
            permits(source, "lua/lunette-plugins/pacing/service/config.luau").is_ok(),
            "{source}"
        );
    }
}

#[test]
fn exports_are_exact_and_no_category_or_leaf_is_blanket_public() {
    for path in [
        "lua/lunette-plugins/audio/init.luau",
        "lua/lunette-plugins/audio/mystery.luau",
        "lua/lunette-plugins/audio/analysis/fft.luau",
        "lua/lunette-plugins/theme/standard/presets.luau",
        "lua/lunette-plugins/graphics/tests/unlisted.luau",
        "lua/lunette-plugins/registration/tests/support/unlisted.luau",
        "lua/lunette-plugins/input/bindings/config.luau",
        "lua/lunette-plugins/pacing/service-old/private/state.luau",
        "lua/lunette-plugins/input/keyboard/legend-extra.luau",
    ] {
        assert!(ownership(Path::new(path)).is_err(), "{path}");
    }
    for path in public_plugin_files() {
        assert!(ownership(Path::new(&path)).is_ok(), "{path}");
    }
}

#[test]
fn neutral_contracts_and_schemas_cannot_import_providers() {
    for source in [
        "lua/lunette-contracts/theme.luau",
        "lua/lunette-contracts/schemas/theme.luau",
        "lua/lunette-plugin/schema.luau",
    ] {
        for target in [
            "lua/lunette-plugins/theme/resolver/init.luau",
            "lua/lunette-plugins/theme/resolver/private/resources.luau",
            "lua/lunette-desktop/init.luau",
            "dev/plugins/sample/init.luau",
            "lua/testing/init.luau",
        ] {
            assert!(permits(source, target).is_err(), "{source} -> {target}");
        }
        assert!(permits(source, "lua/lunette-plugin/schema.luau").is_ok());
        assert!(permits(source, "lua/lunette-contracts/vocabulary.luau").is_ok());
    }
}

#[test]
fn every_shared_library_rejects_provider_and_desktop_dependencies() {
    for source in [
        "graphics/client-pixels",
        "registration/listeners",
        "lifecycle/cleanup",
        "diagnostics/desktop-logging",
        "theme/base",
        "ui/titlebar-configuration",
        "interaction/picking",
    ] {
        let source = format!("lua/lunette-plugins/{source}.luau");
        assert!(
            permits(&source, "lua/lunette-plugins/theme/resolver/init.luau").is_err(),
            "{source}"
        );
        assert!(
            permits(&source, "lua/lunette-desktop/init.luau").is_err(),
            "{source}"
        );
        assert!(
            permits(&source, "lua/lunette-contracts/vocabulary.luau").is_ok(),
            "{source}"
        );
    }
    assert!(
        permits(
            "lua/lunette-plugins/graphics/rounded-drawing.luau",
            "lua/lunette-plugins/theme/base.luau"
        )
        .is_err()
    );
    assert!(
        permits(
            "lua/lunette-plugins/graphics/rounded-drawing.luau",
            "lua/lunette-plugins/graphics/rounded-geometry.luau"
        )
        .is_ok()
    );
    assert!(
        permits(
            "lua/lunette-plugins/ui/titlebar-configuration.luau",
            "lua/lunette-plugins/theme/configuration.luau"
        )
        .is_ok()
    );
    assert!(
        permits(
            "lua/lunette-plugins/registration/listeners.luau",
            "lua/lunette-plugins/diagnostics/protected-call.luau"
        )
        .is_ok()
    );
}

#[test]
fn public_extensions_do_not_publish_mixed_private_renderers() {
    for source in [
        "input/keyboard/legend",
        "input/keyboard/hooks",
        "layout/arc/geometry",
    ] {
        let source = format!("lua/lunette-plugins/{source}.luau");
        assert!(
            permits(
                &source,
                "lua/lunette-plugins/input/keyboard/private/draw.luau"
            )
            .is_err()
        );
        assert!(permits(&source, "lua/lunette-plugins/input/keyboard/init.luau").is_err());
    }
    let support = format!("lua/lunette-plugins/{}.luau", EXTENSION_SUPPORT[0].module);
    assert!(permits("lua/lunette-plugins/input/keyboard/legend.luau", &support).is_ok());
    assert!(
        permits(
            "lua/lunette-plugins/input/keyboard/private/draw.luau",
            &support
        )
        .is_ok()
    );
    assert!(permits("examples/keyboard/split.luau", &support).is_err());
    assert!(
        permits(
            &support,
            "lua/lunette-plugins/input/keyboard/private/draw.luau"
        )
        .is_err()
    );
}

#[test]
fn tests_have_own_internals_not_other_owners_test_support() {
    assert!(
        permits(
            "lua/lunette-plugins/pacing/service/tests/pacer.luau",
            "lua/lunette-plugins/pacing/service/tests/support/fixture.luau"
        )
        .is_ok()
    );
    assert!(
        permits(
            "lua/lunette-plugins/pacing/controller/tests/pacer.luau",
            "lua/lunette-plugins/pacing/service/tests/support/fixture.luau"
        )
        .is_err()
    );
    assert!(
        permits(
            "lua/lunette-plugins/pacing/service/init.luau",
            "lua/lunette-plugins/pacing/service/tests/support/fixture.luau"
        )
        .is_err()
    );
}

#[test]
fn policy_limits_whitebox_exceptions_to_exact_edges() {
    for edge in WHITEBOX_EDGES {
        let target = format!("lua/lunette-plugins/{}", edge.target);
        assert!(permits(edge.source, &target).is_ok());
        assert!(
            permits(
                "crates/lunette/tests/graphics/fixtures/unlisted.luau",
                &target
            )
            .is_err()
        );
        assert!(
            permits(
                edge.source,
                "lua/lunette-plugins/environment/backdrop/private/rendering/geometry.luau"
            )
            .is_err()
        );
        assert!(
            permits(
                edge.source,
                "lua/lunette-plugins/audio/analysis/private/fft.luau"
            )
            .is_err()
        );
    }
}

#[test]
fn shipped_modules_cannot_import_development_scaffolding() {
    for source in [
        "lua/lunette-plugins/pacing/service/init.luau",
        "lua/lunette-desktop/init.luau",
        "etc/xdg/lunette/main.luau",
    ] {
        assert!(permits(source, "lua/testing/init.luau").is_err());
        assert!(permits(source, "dev/plugins/sample/init.luau").is_err());
    }
    assert!(
        permits(
            "dev/plugins/sample/init.luau",
            "dev/plugins/other/private/state.luau"
        )
        .is_err()
    );
}

#[test]
fn preload_names_and_host_sources_are_exact() -> Result<(), String> {
    for source_path in [
        "lua/testing/init.luau",
        "lua/testing/native.luau",
        "lua/testing/session.luau",
        "lua/lunette-plugins/pacing/service/init.luau",
        "lua/lunette-contracts/window.luau",
    ] {
        let source_path = Path::new(source_path);
        let source = ownership(source_path)?;
        assert!(check_preloaded(source_path, &source, "@lunette", false).is_ok());
        let host = check_preloaded(source_path, &source, "@testing/host", false);
        assert_eq!(
            host.is_ok(),
            matches!(
                source_path.to_str(),
                Some("lua/testing/init.luau" | "lua/testing/native.luau")
            )
        );
        assert!(check_preloaded(source_path, &source, "@testing/host", true).is_err());
        assert!(check_preloaded(source_path, &source, "@lunette/private", false).is_err());
        assert!(check_preloaded(source_path, &source, "@testing/host-extra", false).is_err());
    }
    Ok(())
}

#[test]
fn dynamic_and_escaped_loader_forms_fail_even_in_tests() -> Result<(), String> {
    for source in [
        "lua/testing/session.luau",
        "lua/lunette-plugins/environment/backdrop/tests/lifetime.luau",
        "dev/plugins/sample/init.luau",
    ] {
        let path = Path::new(source);
        let source = ownership(path)?;
        for outcome in [
            RequireOutcome::Dynamic,
            RequireOutcome::Escaped,
            RequireOutcome::Overwritten,
            RequireOutcome::Unsupported,
            RequireOutcome::Unresolved("missing".into()),
        ] {
            let error = check_observation(path, &source, &observed(outcome), false)
                .err()
                .ok_or("loader must fail")?;
            assert_eq!(error.line, 7);
            assert_eq!(error.column, 3);
            assert!(error.to_string().contains("plugin dependencies:"));
        }
    }
    Ok(())
}

#[test]
fn terminal_imports_do_not_create_file_graph_nodes() -> Result<(), String> {
    let path = Path::new("lua/lunette-contracts/window.luau");
    let source = ownership(path)?;
    assert_eq!(
        check_observation(
            path,
            &source,
            &observed(RequireOutcome::Preloaded("@lunette".into())),
            false
        )
        .map_err(|error| error.to_string())?,
        None
    );
    Ok(())
}

#[test]
fn resolved_observations_enforce_target_ownership_and_report_public_boundary() -> Result<(), String>
{
    let path = Path::new("lua/lunette-desktop/settings.luau");
    let source = ownership(path)?;
    let target = PathBuf::from("lua/lunette-plugins/pacing/service/private/pacer.luau");
    let error = check_observation(
        path,
        &source,
        &observed(RequireOutcome::Resolved(target.clone())),
        false,
    )
    .err()
    .ok_or("private import must fail")?;
    assert_eq!(error.target, Some(target));
    assert!(error.message.contains("entry, config"));
    Ok(())
}

#[test]
fn installed_policy_rejects_testing_dev_and_test_files() -> Result<(), String> {
    let source_path = Path::new("lua/lunette-plugins/pacing/service/init.luau");
    let source = ownership(source_path)?;
    for target_path in [
        "lua/testing/init.luau",
        "dev/main.luau",
        "lua/lunette-plugins/pacing/service/tests/pacer.luau",
    ] {
        let target_path = Path::new(target_path);
        let target = ownership(target_path)?;
        assert!(
            check_edge(&Edge {
                source_path,
                source: &source,
                target_path,
                target: &target,
                installed: true
            })
            .is_err()
        );
    }
    Ok(())
}

#[test]
fn policy_rejects_actual_module_cycles_with_path() {
    let graph = BTreeMap::from([
        (
            PathBuf::from("lua/lunette-plugin/management.luau"),
            BTreeSet::from([PathBuf::from("lua/lunette-contracts/inspection.luau")]),
        ),
        (
            PathBuf::from("lua/lunette-contracts/inspection.luau"),
            BTreeSet::from([PathBuf::from("lua/lunette-plugin/init.luau")]),
        ),
    ]);
    assert!(cycle_diagnostics(&graph).is_empty());
    let mut graph = graph;
    graph.insert(
        PathBuf::from("lua/lunette-plugin/init.luau"),
        BTreeSet::from([PathBuf::from("lua/lunette-plugin/management.luau")]),
    );
    let errors = cycle_diagnostics(&graph);
    assert_eq!(errors.len(), 1);
    for file in ["management.luau", "inspection.luau", "init.luau"] {
        assert!(errors[0].message.contains(file));
    }
    assert!(cycle_diagnostics(&BTreeMap::new()).is_empty());
}

#[test]
fn cycles_include_self_import_and_complete_path() {
    let path = PathBuf::from("lua/lunette-plugins/pacing/service/private/pacer.luau");
    let errors = cycle_diagnostics(&BTreeMap::from([(path.clone(), BTreeSet::from([path]))]));
    assert_eq!(errors.len(), 1);
    assert!(errors[0].message.contains("pacer.luau -> lua/"));
}

#[test]
fn hierarchy_requires_exports_and_rejects_obsolete_entry_files_not_retained_names() {
    let mut files: BTreeSet<_> = public_plugin_files()
        .into_iter()
        .map(PathBuf::from)
        .collect();
    files.insert(PathBuf::from(
        "lua/lunette-plugins/theme/configuration.luau",
    ));
    files.insert(PathBuf::from("lua/lunette-plugins/theme/init.luau"));
    files.insert(PathBuf::from("lua/lunette-plugins/listeners.luau"));
    let diagnostics = hierarchy_diagnostics(&files, true);
    assert!(
        diagnostics
            .iter()
            .any(|error| error.source == Path::new("lua/lunette-plugins/theme/init.luau"))
    );
    assert!(
        diagnostics
            .iter()
            .any(|error| error.source == Path::new("lua/lunette-plugins/listeners.luau"))
    );
    assert!(
        !diagnostics
            .iter()
            .any(|error| error.source == Path::new("lua/lunette-plugins/theme/configuration.luau"))
    );
    assert!(!diagnostics.iter().any(|error| {
        error
            .source
            .extension()
            .is_some_and(|extension| extension == "md")
    }));
    files.remove(Path::new("lua/lunette-plugins/pacing/service/config.luau"));
    assert!(
        hierarchy_diagnostics(&files, true).iter().any(
            |error| error.source == Path::new("lua/lunette-plugins/pacing/service/config.luau")
        )
    );
}

#[test]
fn configured_loads_reject_stale_missing_and_wrong_configuration_targets() {
    let mut files = BTreeSet::new();
    let mut observations = BTreeMap::new();
    for load in CONFIGURED_LOADS {
        files.extend([
            PathBuf::from(load.source),
            PathBuf::from(load.target),
            PathBuf::from(load.configuration).join("main.luau"),
        ]);
        observations.insert(
            (PathBuf::from(load.source), load.literal.to_owned()),
            vec![PathBuf::from(load.target)],
        );
    }
    assert!(configured_load_diagnostics(&files, &observations).is_empty());
    let load = CONFIGURED_LOADS[0];
    let key = (PathBuf::from(load.source), load.literal.to_owned());
    observations.insert(
        key.clone(),
        vec![PathBuf::from("examples/desktop/conf.luau")],
    );
    assert!(
        configured_load_diagnostics(&files, &observations)
            .iter()
            .any(|error| error.message.contains("must resolve exactly"))
    );
    observations.remove(&key);
    assert!(
        configured_load_diagnostics(&files, &observations)
            .iter()
            .any(|error| error.message.contains("unused configured load"))
    );
    files.remove(Path::new(load.target));
    assert!(
        configured_load_diagnostics(&files, &observations)
            .iter()
            .any(|error| error.message.contains("missing source, target"))
    );
}

#[test]
fn ordinary_resolution_has_no_overlay_and_graphics_installed_are_explicit() {
    let root = Path::new("/fixture");
    let ordinary = request(root, Path::new("examples/desktop/main.luau"), &[], false);
    assert!(ordinary.aliases.is_empty());
    let graphics = request(
        root,
        Path::new("crates/lunette/tests/graphics/fixtures/support/theme.luau"),
        &[],
        false,
    );
    assert!(
        graphics
            .aliases
            .iter()
            .any(|alias| alias.name == "testing" && alias.path == root.join("lua/testing"))
    );
    assert!(
        !graphics
            .preloaded
            .iter()
            .any(|name| name == "@testing/host")
    );
    let installed = request(root, Path::new("lua/lunette-desktop/init.luau"), &[], true);
    assert!(
        !installed
            .aliases
            .iter()
            .any(|alias| alias.name == "testing")
    );
    assert_eq!(installed.preloaded, ["@lunette"]);
    let host = request(root, Path::new("lua/testing/init.luau"), &[], false);
    assert!(host.preloaded.iter().any(|name| name == "@testing/host"));
    assert_ne!(
        resolution_context(Path::new("dev/main.luau"), false),
        resolution_context(Path::new("dev/tests/startup.luau"), false)
    );
}

#[test]
fn configured_loads_use_main_file_anchor_and_relative_imports_stay_ordinary() {
    let root = Path::new("/fixture");
    for load in CONFIGURED_LOADS {
        let request = request(root, Path::new(load.source), &[], false);
        assert!(
            request
                .configured
                .iter()
                .any(|configured| configured.literal == load.literal
                    && configured.anchor == root.join(load.configuration).join("main.luau"))
        );
        assert!(
            !request
                .configured
                .iter()
                .any(|configured| configured.literal.starts_with("./")
                    || configured.literal.starts_with("../"))
        );
    }
}

#[test]
fn policy_rejects_private_alias_relative_and_transitive_library_edges() -> Result<(), String> {
    let source_path = Path::new("lua/lunette-plugins/pacing/controller/init.luau");
    let source = ownership(source_path)?;
    for requested in [
        "@lunette-plugins/pacing/service/private/pacer",
        "../service/private/pacer",
    ] {
        let observation = RequireObservation {
            line: 4,
            column: 2,
            requested: Some(requested.into()),
            outcome: RequireOutcome::Resolved(PathBuf::from(
                "lua/lunette-plugins/pacing/service/private/pacer.luau",
            )),
        };
        assert!(check_observation(source_path, &source, &observation, false).is_err());
    }
    assert!(
        permits(
            "lua/lunette-plugins/pacing/controller/init.luau",
            "lua/lunette-plugins/graphics/rounded-drawing.luau"
        )
        .is_ok()
    );
    assert!(
        permits(
            "lua/lunette-plugins/graphics/rounded-drawing.luau",
            "lua/lunette-plugins/theme/resolver/init.luau"
        )
        .is_err()
    );
    Ok(())
}

#[test]
fn canonical_sources_cannot_be_claimed_by_another_owner_or_visibility() {
    let target = PathBuf::from("lua/lunette-plugins/pacing/service/private/pacer.luau");
    let same = vec![
        (target.clone(), target.clone()),
        (
            PathBuf::from("lua/lunette-plugins/pacing/service/private/alias.luau"),
            target.clone(),
        ),
    ];
    assert!(canonical_owner_diagnostics(&same).is_empty());
    let mut other = same;
    other.push((
        PathBuf::from("lua/lunette-plugins/pacing/controller/private/alias.luau"),
        target.clone(),
    ));
    assert!(
        canonical_owner_diagnostics(&other)
            .iter()
            .any(|error| error.message.contains("conflicting declarations"))
    );
    assert!(
        !canonical_owner_diagnostics(&[(
            PathBuf::from("lua/lunette-plugins/pacing/service/init.luau"),
            target
        )])
        .is_empty()
    );
}

#[test]
fn whitebox_and_preload_declarations_must_be_used() {
    let mut edges: BTreeMap<PathBuf, BTreeSet<PathBuf>> = BTreeMap::new();
    for exception in WHITEBOX_EDGES {
        edges
            .entry(PathBuf::from(exception.source))
            .or_default()
            .insert(PathBuf::from(format!(
                "lua/lunette-plugins/{}",
                exception.target
            )));
    }
    let preloads = BTreeSet::from([
        (
            PathBuf::from("lua/testing/init.luau"),
            "@testing/host".into(),
        ),
        (
            PathBuf::from("lua/testing/native.luau"),
            "@testing/host".into(),
        ),
    ]);
    assert!(context_use_diagnostics(&edges, &preloads).is_empty());
    assert!(
        context_use_diagnostics(&BTreeMap::new(), &preloads)
            .iter()
            .any(|error| error.message.contains("unused white-box"))
    );
    assert!(
        context_use_diagnostics(&edges, &BTreeSet::new())
            .iter()
            .any(|error| error.message.contains("unused test-host"))
    );
}

#[test]
fn configuration_switches_reject_dynamic_wrong_stale_and_installed_calls() {
    let mut observations: BTreeMap<PathBuf, Vec<MemberCallObservation>> = BTreeMap::new();
    for switch in CONFIGURATION_SWITCHES {
        observations
            .entry(PathBuf::from(switch.source))
            .or_default()
            .push(MemberCallObservation {
                line: 4,
                column: 2,
                argument: Some(switch.configuration.into()),
            });
    }
    assert!(configuration_switch_diagnostics(&observations, false).is_empty());
    assert!(!configuration_switch_diagnostics(&observations, true).is_empty());
    let source = PathBuf::from(CONFIGURATION_SWITCHES[0].source);
    observations.insert(
        source.clone(),
        vec![MemberCallObservation {
            line: 8,
            column: 5,
            argument: None,
        }],
    );
    let errors = configuration_switch_diagnostics(&observations, false);
    assert!(
        errors
            .iter()
            .any(|error| error.line == 8 && error.message.contains("not declared"))
    );
    assert!(
        errors
            .iter()
            .any(|error| error.message.contains("unused configuration switch"))
    );
    observations.insert(
        source,
        vec![MemberCallObservation {
            line: 9,
            column: 3,
            argument: Some("examples/wrong".into()),
        }],
    );
    assert!(
        configuration_switch_diagnostics(&observations, false)
            .iter()
            .any(|error| error.line == 9)
    );
}

#[test]
fn installed_scanner_checks_public_exports_without_documentation()
-> Result<(), Box<dyn std::error::Error>> {
    let installation = tempfile::tempdir()?;
    for alias in lunette::aliases::INSTALLED_ALIASES {
        fs::create_dir_all(installation.path().join("lua").join(alias.name))?;
    }
    let fixture = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures/require-relative/lunette/sibling.luau");
    let paths = public_plugin_files()
        .into_iter()
        .chain(
            CONTRACT_SCHEMAS
                .iter()
                .map(|schema| format!("lua/lunette-contracts/schemas/{schema}.luau")),
        )
        .chain(
            EXTENSION_SUPPORT
                .iter()
                .map(|library| format!("lua/lunette-plugins/{}.luau", library.module)),
        );
    for path in paths {
        let destination = installation.path().join(path);
        if let Some(parent) = destination.parent() {
            fs::create_dir_all(parent)?;
        }
        fs::copy(&fixture, destination)?;
    }
    let report = installed_scan(installation.path())?;
    assert!(report.diagnostics().next().is_none(), "{report}");
    assert!(!report.sources.is_empty());
    fs::remove_file(
        installation
            .path()
            .join("lua/lunette-plugins/pacing/service/config.luau"),
    )?;
    let test = installation
        .path()
        .join("lua/lunette-plugins/pacing/service/tests/pacer.luau");
    if let Some(parent) = test.parent() {
        fs::create_dir_all(parent)?;
    }
    fs::copy(&fixture, test)?;
    let report = installed_scan(installation.path())?;
    assert!(
        report
            .hierarchy
            .iter()
            .any(|error| error.message == "missing declared module")
    );
    assert!(
        report
            .hierarchy
            .iter()
            .any(|error| error.message.contains("test or development module"))
    );
    assert!(!report.diagnostics().any(|error| {
        error
            .source
            .extension()
            .is_some_and(|extension| extension == "md")
    }));
    Ok(())
}

#[test]
fn pure_policy_accepts_explicit_library_owner_records() {
    let source = Ownership {
        owner: Owner::Library("registration/listeners", LibraryDomain::Registration),
        visibility: Visibility::Test,
        role: Role::Test,
    };
    let target = Ownership {
        owner: source.owner.clone(),
        visibility: Visibility::Private,
        role: Role::Implementation,
    };
    assert!(
        check_edge(&Edge {
            source_path: Path::new("fixture/tests/listeners.luau"),
            source: &source,
            target_path: Path::new("fixture/private/state.luau"),
            target: &target,
            installed: false
        })
        .is_ok()
    );
}
