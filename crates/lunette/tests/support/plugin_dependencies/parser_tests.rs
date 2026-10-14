//! Parser and Navigator fixtures exercise source observations without executing fixture modules.
#![expect(
    clippy::expect_used,
    reason = "a fixture fails at the first broken step"
)]

use std::{
    fs,
    path::{Path, PathBuf},
};

use lunette::aliases::{DEVELOPMENT_ALIASES, luaurc};
use lunette_lovr::analyze::{
    self, ConfiguredRequire, RequireAlias, RequireObservation, RequireOutcome, RequireRequest,
};
use tempfile::TempDir;

use crate::plugin_dependencies::{
    catalog::{CONFIGURATION_SWITCHES, CONFIGURED_LOADS, Preloaded, TEST_HOST_SOURCES},
    scan,
};

#[test]
fn parser_finds_alias_relative_self_and_typeof_imports() {
    let tree = Tree::new();
    tree.write(".luaurc", "{\"aliases\": {\"fixture\": \"./modules\"}}");
    let target = tree.write("modules/target.luau", "return {}\n");
    let nested = tree.write("modules/leaf/nested.luau", "return {}\n");
    let source = tree.write(
        "modules/leaf/init.luau",
        "local a = require '@fixture/target'\nlocal b = require('./target')\nlocal c = require '@self/nested'\nlocal d = {require '../modules/target'}\ntype T = typeof(require('@fixture/target'))\nreturn a\n",
    );
    let observed = tree.inspect(&source);
    assert_eq!(observed.len(), 5, "{observed:#?}");
    for (index, observation) in observed.iter().enumerate() {
        assert_eq!(observation.line as usize, index + 1);
        assert_eq!(
            resolved(observation),
            if index == 2 { &nested } else { &target }
        );
    }
}

#[test]
fn parser_ignores_comments_strings_shadowed_require_and_service_lookup() {
    let tree = Tree::new();
    let source = tree.write(
        "main.luau",
        "-- require './missing'\nlocal shader = [[require './missing']]\nlocal ordinary = \"require './missing'\"\nlocal context = {}\ncontext:require('service')\ndo local require = function(name) return name end; require('./missing') end\nlocal function shadow(require) return require './missing' end\nreturn ordinary\n",
    );
    assert!(tree.inspect(&source).is_empty());
    let target = tree.write("target.luau", "return {}\n");
    let source = tree.write(
        "scope.luau",
        "local require = require './target'\nrequire('./missing')\nreturn require\n",
    );
    let observed = tree.inspect(&source);
    assert_eq!(observed.len(), 1, "{observed:#?}");
    assert_eq!(resolved(&observed[0]), &target);
}

#[test]
fn parser_rejects_dynamic_escaped_and_overwritten_global_require() {
    let tree = Tree::new();
    for (body, expected) in [
        ("return require(moduleName)", "dynamic"),
        ("return require('./' .. moduleName)", "dynamic"),
        ("return require('./' .. 'target')", "dynamic"),
        ("local load = require; return load('./target')", "escaped"),
        ("return {loader = require}", "escaped"),
        ("consume(require)", "escaped"),
        ("require = function() end", "overwritten"),
        ("local x; x, require = nil, nil", "overwritten"),
        ("require += 1", "overwritten"),
        ("function require() end", "overwritten"),
        ("return _G.require('./target')", "unsupported"),
        ("return _G['require']('./target')", "unsupported"),
        ("_G.require = nil", "unsupported"),
        ("return _G['require' :: string]('./target')", "unsupported"),
        ("return (_G :: any).require('./target')", "unsupported"),
        (
            "return ((_G :: any)['require' :: string] :: any)('./target')",
            "unsupported",
        ),
        ("local load = _G['require' :: string]", "unsupported"),
        ("local load = (_G :: any).require", "unsupported"),
        ("_G['require' :: string] = nil", "unsupported"),
        ("(_G :: any).require = nil", "unsupported"),
    ] {
        let source = tree.write("main.luau", body);
        let observed = tree.inspect(&source);
        assert!(
            observed
                .iter()
                .any(|observation| outcome_name(&observation.outcome) == expected),
            "{body}: expected {expected}: {observed:#?}"
        );
        assert!(
            observed
                .iter()
                .all(|observation| !matches!(observation.outcome, RequireOutcome::Resolved(_)))
        );
    }
    let nul = tree.write("main.luau", "return require './target\\0trailing'\n");
    let nul_observed = tree.inspect(&nul);
    assert_eq!(
        nul_observed[0].requested.as_deref(),
        Some("./target\0trailing")
    );
    assert_unresolved(&nul_observed);
    let invalid_utf8 = tree.write("main.luau", "return require '\\255'\n");
    assert!(
        analyze::inspect_requires(&tree.request(&invalid_utf8)).is_err(),
        "unrepresentable literals are not silently replaced"
    );
    let target = tree.write("target.luau", "return {}\n");
    for body in [
        "return (require)('./target')\n",
        "return (require :: any)('./target' :: string)\n",
        "return (require :: typeof(require './target'))('./target')\n",
    ] {
        let source = tree.write("main.luau", body);
        let observed = tree.inspect(&source);
        let expected_count = if body.contains("typeof") { 2 } else { 1 };
        assert_eq!(observed.len(), expected_count, "{body}: {observed:#?}");
        for observation in &observed {
            assert_eq!(resolved(observation), &target);
        }
    }
    let source = tree.write(
        "main.luau",
        "local _G = {}; _G.require('./target'); return {}\n",
    );
    assert!(
        tree.inspect(&source).is_empty(),
        "local _G is not the global loader table"
    );
    let source = tree.write("main.luau", "return require('./target', 'extra')\n");
    assert!(
        tree.inspect(&source)
            .iter()
            .any(|observation| !matches!(observation.outcome, RequireOutcome::Resolved(_))),
        "loader arity is part of the supported form"
    );
}

#[test]
fn parser_fails_on_missing_ambiguous_invalid_and_escaping_modules() {
    let tree = Tree::new();
    let source = tree.write("main.luau", "return require './missing'\n");
    assert_unresolved(&tree.inspect(&source));
    tree.write("main.luau", "return require '@unknown/target'\n");
    assert_unresolved(&tree.inspect(&source));
    tree.write("main.luau", "return require '@fixture/target'\n");
    tree.write(".luaurc", "{\"aliases\": {\"fixture\": \"./wrong\"}}");
    assert_unresolved(&tree.inspect(&source));
    tree.write(".luaurc", "{invalid json");
    match analyze::inspect_requires(&tree.request(&source)) {
        Ok(observed) => assert_unresolved(&observed),
        Err(error) => assert!(
            error.to_string().contains("config") || error.to_string().contains("luaurc"),
            "{error}"
        ),
    }
    tree.write(".luaurc", "{}");
    tree.write("main.luau", "return require './ambiguous'\n");
    tree.write("ambiguous.luau", "return {}\n");
    tree.write("ambiguous/init.luau", "return {}\n");
    assert_unresolved(&tree.inspect(&source));
    tree.write("main.luau", "return require './double'\n");
    tree.write("double.luau", "return {}\n");
    tree.write("double.lua", "return {}\n");
    assert_unresolved(&tree.inspect(&source));
    tree.write("main.luau", "local unfinished = (\n");
    assert!(
        analyze::inspect_requires(&tree.request(&source)).is_err(),
        "syntax failure is not an empty dependency list"
    );
    assert!(analyze::inspect_requires(&tree.request(&tree.root().join("absent.luau"))).is_err());

    let contained = tree.write("declared/main.luau", "return require '../outside'\n");
    tree.write("outside.luau", "return {}\n");
    let mut contained_request = tree.request(&contained);
    contained_request.allowed_roots = vec![tree.root().join("declared")];
    assert_unresolved(
        &analyze::inspect_requires(&contained_request).expect("relative root escape"),
    );
    contained_request.source = tree.root().join("outside.luau");
    assert!(
        analyze::inspect_requires(&contained_request).is_err(),
        "the requesting source must also remain inside a declared root"
    );

    let outside = Tree::new();
    let target = outside.write("outside.luau", "return {}\n");
    tree.write("main.luau", "return require '@outside/outside'\n");
    let mut request = tree.request(&source);
    request.aliases.push(RequireAlias {
        name: "outside".into(),
        path: outside.root().to_path_buf(),
    });
    assert_unresolved(&analyze::inspect_requires(&request).expect("root escape observed"));
    #[cfg(unix)]
    {
        std::os::unix::fs::symlink(&target, tree.root().join("linked.luau"))
            .expect("fixture symlink");
        tree.write("main.luau", "return require './linked'\n");
        assert_unresolved(&tree.inspect(&source));
        let internal = tree.write("actual/target.luau", "return {}\n");
        std::os::unix::fs::symlink(
            tree.root().join("actual"),
            tree.root().join("linked-directory"),
        )
        .expect("internal directory symlink");
        tree.write("main.luau", "return require './linked-directory/target'\n");
        let observed = tree.inspect(&source);
        assert_eq!(resolved(&observed[0]), &internal);
    }
}

#[test]
fn declared_test_preloads_are_terminal_targets() {
    let tree = Tree::new();
    let source = tree.write(
        "main.luau",
        "local native = require '@lunette'\nreturn require '@testing/host'\n",
    );
    let mut request = tree.request(&source);
    request.preloaded = vec![
        Preloaded::Native.name().into(),
        Preloaded::TestHost.name().into(),
    ];
    let observed = analyze::inspect_requires(&request).expect("declared terminals");
    assert_eq!(observed.len(), 2);
    assert_eq!(
        observed[0].outcome,
        RequireOutcome::Preloaded("@lunette".into())
    );
    assert_eq!(
        observed[1].outcome,
        RequireOutcome::Preloaded("@testing/host".into())
    );
    let state = fs::read_to_string(repository().join("crates/lunette/tests/lua/state.rs"))
        .expect("runtime preload inventory");
    let declared = [Preloaded::Native.name(), Preloaded::TestHost.name()];
    let actual: Vec<_> = state
        .lines()
        .map(str::trim)
        .filter_map(|line| {
            line.strip_prefix('"')
                .and_then(|line| line.strip_suffix("\","))
        })
        .filter(|name| name.starts_with('@'))
        .collect();
    assert_eq!(actual, declared);
    for source in TEST_HOST_SOURCES {
        assert!(repository().join(source).is_file(), "{source}");
    }
}

#[test]
fn undeclared_preloads_still_fail() {
    let tree = Tree::new();
    for literal in [
        "@testing/host",
        "@testing/unknown",
        "@lunette/unknown",
        "@unknown",
    ] {
        let source = tree.write("main.luau", &format!("return require '{literal}'\n"));
        let mut request = tree.request(&source);
        request.preloaded = vec!["@lunette".into()];
        assert_unresolved(
            &analyze::inspect_requires(&request).expect("undeclared terminal observation"),
        );
    }
}

#[test]
fn graphics_fixture_aliases_use_declared_context() {
    let tree = Tree::new();
    for alias in DEVELOPMENT_ALIASES {
        tree.write(&format!("lua/{}/init.luau", alias.name), "return {}\n");
    }
    tree.write("lua/.luaurc", &luaurc("."));
    let source = tree.write(
        "fixtures/main.luau",
        "local plugin = require '@lunette-plugin'\nreturn require '@testing'\n",
    );
    assert_unresolved(&tree.inspect(&source));
    let mut request = tree.request(&source);
    request.aliases = DEVELOPMENT_ALIASES
        .iter()
        .map(|alias| RequireAlias {
            name: alias.name.into(),
            path: tree.root().join("lua").join(alias.name),
        })
        .collect();
    let observed = analyze::inspect_requires(&request).expect("explicit graphics alias context");
    assert_eq!(observed.len(), 2);
    assert_eq!(
        resolved(&observed[0]),
        &tree.root().join("lua/lunette-plugin/init.luau")
    );
    assert_eq!(
        resolved(&observed[1]),
        &tree.root().join("lua/testing/init.luau")
    );
    request.aliases.clear();
    assert_unresolved(&analyze::inspect_requires(&request).expect("ordinary context is unchanged"));
}

#[test]
fn scanner_test_context_matches_runtime_roots_and_exact_configuration_loads() {
    let tree = Tree::new();
    let testing = tree.write("lua/testing/init.luau", "return require '@testing/host'\n");
    let native = tree.write(
        "lua/testing/native.luau",
        "return require '@testing/host'\n",
    );
    let root = tree.root();
    let allowed = vec![root.to_path_buf()];
    tree.write("examples/audio-backdrop/main.luau", "return {}\n");
    for source in [
        "examples/audio-backdrop/tests/composition.luau",
        "examples/audio-backdrop/tests/consumer.luau",
        "lua/lunette-plugins/environment/backdrop/tests/support/fixture.luau",
    ] {
        tree.write(source, "return require '@testing'\n");
        let observed =
            analyze::inspect_requires(&scan::request(root, Path::new(source), &allowed, false))
                .expect("test runtime alias context");
        assert_eq!(resolved(&observed[0]), &testing, "{source}");
    }
    for source in [testing, native] {
        let request = scan::request(
            root,
            source.strip_prefix(root).expect("fixture-relative source"),
            &allowed,
            false,
        );
        let observed = analyze::inspect_requires(&request).expect("exact host source");
        assert_eq!(
            observed[0].outcome,
            RequireOutcome::Preloaded("@testing/host".into())
        );
    }
    for source in [
        "examples/audio-backdrop/main.luau",
        "examples/audio-backdrop/tests/undeclared.luau",
        "lua/lunette-plugins/environment/backdrop/tests/support/fixture.luau",
    ] {
        tree.write(source, "return require '@testing/host'\n");
        assert_unresolved(
            &analyze::inspect_requires(&scan::request(root, Path::new(source), &allowed, false))
                .expect("host access remains exact"),
        );
    }
    let main = tree.write("examples/audio-backdrop/main.luau", "return {}\n");
    let source = "examples/audio-backdrop/tests/composition.luau";
    let support = tree.write(
        "examples/audio-backdrop/tests/support/fixture.luau",
        "return {}\n",
    );
    tree.write(
        source,
        "local main = require 'main'\nreturn require './support/fixture'\n",
    );
    let request = scan::request(root, Path::new(source), &allowed, false);
    let observed = analyze::inspect_requires(&request).expect("runtime @main chunk configuration");
    assert_eq!(resolved(&observed[0]), &main);
    assert_eq!(resolved(&observed[1]), &support);
    let configured =
        "lua/lunette-plugins/environment/backdrop/tests/support/source-reload/main.luau";
    let lifetimes = tree.write(
        "lua/lunette-plugins/environment/backdrop/tests/support/lifetimes.luau",
        "return {}\n",
    );
    tree.write(
        configured,
        "return require '@lunette-plugins/environment/backdrop/tests/support/lifetimes'\n",
    );
    let observed =
        analyze::inspect_requires(&scan::request(root, Path::new(configured), &allowed, false))
            .expect("alias from a configuration-root chunk");
    assert_eq!(resolved(&observed[0]), &lifetimes);
    tree.write(configured, "return require '../lifetimes'\n");
    let mut runtime = scan::request(root, Path::new(configured), &allowed, false);
    runtime.allowed_roots =
        vec![root.join("lua/lunette-plugins/environment/backdrop/tests/support/source-reload")];
    assert_unresolved(
        &analyze::inspect_requires(&runtime).expect("configuration-root relative escape"),
    );
    let source = "examples/audio-backdrop/tests/undeclared.luau";
    tree.write(source, "return require 'main'\n");
    assert_unresolved(
        &analyze::inspect_requires(&scan::request(root, Path::new(source), &allowed, false))
            .expect("undeclared configuration load"),
    );
    tree.write(source, "return require '@main'\n");
    assert_unresolved(
        &analyze::inspect_requires(&scan::request(root, Path::new(source), &allowed, false))
            .expect("the runtime chunk name is not an alias"),
    );
    tree.write(
        "examples/audio-backdrop/main.luau",
        "return require '@testing'\n",
    );
    assert_unresolved(
        &analyze::inspect_requires(&scan::request(
            root,
            Path::new("examples/audio-backdrop/main.luau"),
            &allowed,
            false,
        ))
        .expect("production aliases are unchanged"),
    );
}

#[test]
fn member_call_observations_use_the_parser_and_preserve_literals() {
    let tree = Tree::new();
    let source = tree.write("main.luau", "-- host.useConfiguration 'comment'\nlocal text = [[host.useConfiguration 'string']]\nhost.useConfiguration 'one'\nhost:useConfiguration('two')\nhost['useConfiguration']('three')\nhost.useConfiguration(prefix .. '/four')\ntype T = typeof(host.useConfiguration('five'))\n");
    let observed =
        analyze::inspect_member_calls(&source, "useConfiguration").expect("member calls");
    assert_eq!(
        observed
            .iter()
            .map(|call| call.argument.as_deref())
            .collect::<Vec<_>>(),
        vec![Some("one"), Some("two"), Some("three"), None, Some("five")]
    );
    assert_eq!(
        observed.iter().map(|call| call.line).collect::<Vec<_>>(),
        vec![3, 4, 5, 6, 7]
    );
    tree.write("main.luau", "local broken = (\n");
    assert!(analyze::inspect_member_calls(&source, "useConfiguration").is_err());
}

#[test]
fn configuration_contexts_resolve_runner_loads() {
    let tree = Tree::new();
    let source = tree.write(
        "runner/case.luau",
        "local fixture = require 'fixture'\nreturn require './support'\n",
    );
    let support = tree.write("runner/support.luau", "return {}\n");
    let anchor = tree.write("config/main.luau", "return {}\n");
    let target = tree.write("config/fixture.luau", "return {}\n");
    let other_anchor = tree.write("other/main.luau", "return {}\n");
    let other = tree.write("other/fixture.luau", "return {}\n");
    assert_unresolved(&tree.inspect(&source));
    let mut request = tree.request(&source);
    request.configured.push(ConfiguredRequire {
        literal: "fixture".into(),
        anchor: anchor.clone(),
    });
    let observed = analyze::inspect_requires(&request).expect("explicit configuration context");
    assert_eq!(resolved(&observed[0]), &target);
    assert_eq!(resolved(&observed[1]), &support);
    request.configured[0].anchor = other_anchor;
    let wrong = analyze::inspect_requires(&request).expect("different configuration context");
    assert_eq!(resolved(&wrong[0]), &other);
    assert_ne!(
        resolved(&wrong[0]),
        &target,
        "a wrong context cannot silently select the declared target"
    );
    request.configured[0].literal = "unused".into();
    assert_unresolved(
        &analyze::inspect_requires(&request).expect("stale context does not exempt a bare import"),
    );
    assert_eq!(CONFIGURED_LOADS.len(), 19);
    assert_eq!(CONFIGURATION_SWITCHES.len(), 13);
    for load in CONFIGURED_LOADS {
        assert!(load.target.starts_with(load.configuration), "{load:?}");
    }
}

fn assert_unresolved(observed: &[RequireObservation]) {
    assert!(
        observed
            .iter()
            .any(|observation| matches!(observation.outcome, RequireOutcome::Unresolved(_))),
        "{observed:#?}"
    );
}

fn resolved(observation: &RequireObservation) -> &PathBuf {
    match &observation.outcome {
        RequireOutcome::Resolved(path) => path,
        other => panic!("expected file target: {other:?}"),
    }
}

fn outcome_name(outcome: &RequireOutcome) -> &'static str {
    match outcome {
        RequireOutcome::Resolved(_) => "resolved",
        RequireOutcome::Preloaded(_) => "preloaded",
        RequireOutcome::Dynamic => "dynamic",
        RequireOutcome::Escaped => "escaped",
        RequireOutcome::Overwritten => "overwritten",
        RequireOutcome::Unsupported => "unsupported",
        RequireOutcome::Unresolved(_) => "unresolved",
    }
}

fn repository() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .canonicalize()
        .expect("repository")
}

struct Tree(TempDir);

impl Tree {
    fn new() -> Self {
        Self(TempDir::with_prefix("lunette-require-inspection-").expect("isolated fixture tree"))
    }

    fn root(&self) -> &Path {
        self.0.path()
    }

    fn write(&self, relative: &str, contents: &str) -> PathBuf {
        let path = self.root().join(relative);
        fs::create_dir_all(path.parent().expect("fixture parent")).expect("fixture directories");
        fs::write(&path, contents).expect("fixture source");
        path
    }

    fn request(&self, source: &Path) -> RequireRequest {
        RequireRequest {
            source: source.to_path_buf(),
            allowed_roots: vec![self.root().to_path_buf()],
            aliases: Vec::new(),
            preloaded: Vec::new(),
            configured: Vec::new(),
        }
    }

    fn inspect(&self, source: &Path) -> Vec<RequireObservation> {
        analyze::inspect_requires(&self.request(source)).expect("source inspection")
    }
}
