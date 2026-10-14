//! Gathers maintained sources and applies ownership policy to parser observations.

use std::{
    collections::{BTreeMap, BTreeSet},
    error::Error,
    fmt, fs, io,
    path::{Path, PathBuf},
};

use lunette::aliases::{Alias, DEVELOPMENT_ALIASES, INSTALLED_ALIASES, Resolution};
use lunette_lovr::analyze::{
    self, ConfiguredRequire, RequireAlias, RequireObservation, RequireOutcome, RequireRequest,
};

use crate::plugin_dependencies::{
    catalog::{
        AliasContext, CONFIGURATION_SWITCHES, CONFIGURED_LOADS, GRAPHICS_CONTEXT,
        INSTALLED_CONTEXT, PRODUCTION_CONTEXT, Preloaded, ResolutionContext, SOURCE_ROOTS,
        TEST_CONTEXT, TEST_HOST_SOURCES, WHITEBOX_EDGES,
    },
    ownership::{Ownership, ownership},
    policy::{
        Diagnostic, check_observation, configuration_switch_diagnostics,
        configured_load_diagnostics, cycle_diagnostics, hierarchy_diagnostics,
    },
};

#[derive(Debug, Default)]
pub struct ScanReport {
    pub sources: BTreeSet<PathBuf>,
    pub hierarchy: Vec<Diagnostic>,
    pub dependencies: Vec<Diagnostic>,
    pub observation_count: usize,
}

impl ScanReport {
    pub fn diagnostics(&self) -> impl Iterator<Item = &Diagnostic> {
        self.hierarchy.iter().chain(&self.dependencies)
    }
}

impl fmt::Display for ScanReport {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        for diagnostic in self.diagnostics() {
            writeln!(formatter, "{diagnostic}")?;
        }
        Ok(())
    }
}

#[derive(Debug)]
pub struct ScanError {
    pub path: PathBuf,
    pub cause: io::Error,
}

impl fmt::Display for ScanError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            formatter,
            "plugin dependencies: reading {}: {}",
            self.path.display(),
            self.cause
        )
    }
}

impl Error for ScanError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        Some(&self.cause)
    }
}

/// Scans every maintained catalog root, including tests and graphics support.
pub fn repository_scan(root: &Path) -> Result<ScanReport, ScanError> {
    scan(root, false)
}

/// Accepts the installation prefix containing `lua/`; it does not require Markdown.
pub fn installed_scan(root: &Path) -> Result<ScanReport, ScanError> {
    scan(root, true)
}

pub fn resolution_context(source: &Path, installed: bool) -> ResolutionContext {
    if installed {
        return INSTALLED_CONTEXT;
    }
    if source.starts_with("crates/lunette/tests/graphics/fixtures") {
        return GRAPHICS_CONTEXT;
    }
    if source.starts_with("lua/testing")
        || source.components().any(|part| part.as_os_str() == "tests")
    {
        return TEST_CONTEXT;
    }
    PRODUCTION_CONTEXT
}

pub fn request(
    root: &Path,
    source: &Path,
    allowed_roots: &[PathBuf],
    installed: bool,
) -> RequireRequest {
    let context = resolution_context(source, installed);
    let aliases = match context.aliases {
        AliasContext::SourceConfiguration => Vec::new(),
        AliasContext::DevelopmentRoots => alias_overlay(root, DEVELOPMENT_ALIASES),
        AliasContext::InstalledRoots => alias_overlay(root, INSTALLED_ALIASES),
    };
    let preloaded = context
        .preloads
        .iter()
        .filter(|preload| {
            **preload != Preloaded::TestHost
                || (!installed
                    && TEST_HOST_SOURCES
                        .iter()
                        .any(|path| source == Path::new(path)))
        })
        .map(|preload| preload.name().to_owned())
        .collect();
    let configured = if installed {
        Vec::new()
    } else {
        CONFIGURED_LOADS
            .iter()
            .filter(|load| source == Path::new(load.source))
            .map(|load| ConfiguredRequire {
                literal: load.literal.into(),
                anchor: root.join(load.configuration).join("main.luau"),
            })
            .collect()
    };
    RequireRequest {
        source: root.join(source),
        allowed_roots: allowed_roots.to_vec(),
        aliases,
        preloaded,
        configured,
    }
}

fn scan(root: &Path, installed: bool) -> Result<ScanReport, ScanError> {
    let root = read_at(root, || root.canonicalize())?;
    let roots: Vec<_> = if installed {
        INSTALLED_ALIASES
            .iter()
            .map(|alias| root.join("lua").join(alias.name))
            .collect()
    } else {
        SOURCE_ROOTS.iter().map(|path| root.join(path)).collect()
    };
    let mut files = BTreeSet::new();
    let mut discovery = Vec::new();
    for source_root in &roots {
        let canonical = read_at(source_root, || source_root.canonicalize())?;
        if !canonical.starts_with(&root) {
            discovery.push(diagnostic(
                relative(&root, source_root),
                "source root escapes the scan root",
            ));
            continue;
        }
        collect(
            &root,
            source_root,
            &roots,
            &mut BTreeSet::new(),
            &mut files,
            &mut discovery,
        )?;
    }
    let mut identities = Vec::new();
    for path in files.iter().filter(|path| {
        path.extension()
            .is_some_and(|extension| extension == "luau")
    }) {
        let canonical = read_at(&root.join(path), || root.join(path).canonicalize())?;
        identities.push((path.clone(), relative(&root, &canonical)));
    }
    discovery.extend(canonical_owner_diagnostics(&identities));
    let mut report = ScanReport {
        sources: identities
            .iter()
            .map(|(_, canonical)| canonical.clone())
            .collect(),
        hierarchy: hierarchy_diagnostics(&files, installed),
        dependencies: discovery,
        observation_count: 0,
    };
    let mut edges: BTreeMap<PathBuf, BTreeSet<PathBuf>> = BTreeMap::new();
    let mut configured: BTreeMap<(PathBuf, String), Vec<PathBuf>> = BTreeMap::new();
    let mut preloads: BTreeSet<(PathBuf, String)> = BTreeSet::new();
    let mut switches = BTreeMap::new();
    for source in &report.sources {
        match analyze::inspect_member_calls(&root.join(source), "useConfiguration") {
            Ok(observations) => {
                switches.insert(source.clone(), observations);
            }
            Err(error) => report.dependencies.push(diagnostic(
                source.clone(),
                &format!("configuration switch parser error: {error}"),
            )),
        }
        let owned = ownership(source);
        let observations =
            match analyze::inspect_requires(&request(&root, source, &roots, installed)) {
                Ok(observations) => observations,
                Err(error) => {
                    report.dependencies.push(diagnostic(
                        source.clone(),
                        &format!("parser/navigation error: {error}"),
                    ));
                    continue;
                }
            };
        report.observation_count += observations.len();
        for mut observation in observations {
            normalize_target(&root, &roots, &mut observation);
            if let RequireOutcome::Preloaded(name) = &observation.outcome {
                preloads.insert((source.clone(), name.clone()));
            }
            if let (Some(literal), RequireOutcome::Resolved(target)) =
                (&observation.requested, &observation.outcome)
            {
                configured
                    .entry((source.clone(), literal.clone()))
                    .or_default()
                    .push(target.clone());
                edges
                    .entry(source.clone())
                    .or_default()
                    .insert(target.clone());
            }
            let Ok(owned) = &owned else {
                if !matches!(observation.outcome, RequireOutcome::Resolved(_)) {
                    report.dependencies.push(Diagnostic {
                        source: source.clone(),
                        line: observation.line,
                        column: observation.column,
                        target: None,
                        message: format!(
                            "loader observation in an unowned source: {:?}",
                            observation.outcome
                        ),
                    });
                }
                continue;
            };
            match check_observation(source, owned, &observation, installed) {
                Ok(Some(target)) if !report.sources.contains(&target) => {
                    report.dependencies.push(Diagnostic {
                        source: source.clone(),
                        line: observation.line,
                        column: observation.column,
                        target: Some(target),
                        message: "resolved target is not in the maintained source inventory".into(),
                    })
                }
                Ok(_) => {}
                Err(error) => report.dependencies.push(error),
            }
        }
    }
    report.dependencies.extend(cycle_diagnostics(&edges));
    report
        .dependencies
        .extend(configuration_switch_diagnostics(&switches, installed));
    if !installed {
        report
            .dependencies
            .extend(configured_load_diagnostics(&files, &configured));
        validate_context_paths(&files, &mut report.dependencies);
        report
            .dependencies
            .extend(context_use_diagnostics(&edges, &preloads));
    }
    Ok(report)
}

pub fn canonical_owner_diagnostics(identities: &[(PathBuf, PathBuf)]) -> Vec<Diagnostic> {
    let mut owners: BTreeMap<PathBuf, (PathBuf, Ownership)> = BTreeMap::new();
    let mut diagnostics = Vec::new();
    for (lexical, canonical) in identities {
        let (Ok(lexical_owner), Ok(canonical_owner)) = (ownership(lexical), ownership(canonical))
        else {
            diagnostics.push(diagnostic(
                lexical.clone(),
                "canonical or lexical module has no declared owner",
            ));
            continue;
        };
        if lexical_owner != canonical_owner {
            diagnostics.push(diagnostic(
                lexical.clone(),
                &format!(
                    "source symlink changes ownership to {}: {:?} -> {:?}",
                    canonical.display(),
                    lexical_owner,
                    canonical_owner
                ),
            ));
        }
        if let Some((previous, previous_owner)) = owners.get(canonical) {
            if previous_owner != &lexical_owner {
                diagnostics.push(diagnostic(
                    lexical.clone(),
                    &format!(
                        "canonical source {} has conflicting declarations at {} and {}",
                        canonical.display(),
                        previous.display(),
                        lexical.display()
                    ),
                ));
            }
        } else {
            owners.insert(canonical.clone(), (lexical.clone(), lexical_owner));
        }
    }
    diagnostics
}

pub fn context_use_diagnostics(
    edges: &BTreeMap<PathBuf, BTreeSet<PathBuf>>,
    preloads: &BTreeSet<(PathBuf, String)>,
) -> Vec<Diagnostic> {
    let mut diagnostics = Vec::new();
    for exception in WHITEBOX_EDGES {
        let target = PathBuf::from(format!("lua/lunette-plugins/{}", exception.target));
        if !edges
            .get(Path::new(exception.source))
            .is_some_and(|targets| targets.contains(&target))
        {
            diagnostics.push(diagnostic(
                PathBuf::from(exception.source),
                &format!(
                    "unused white-box edge to {}; remove stale declarations",
                    target.display()
                ),
            ));
        }
    }
    for source in TEST_HOST_SOURCES {
        if !preloads.contains(&(PathBuf::from(source), Preloaded::TestHost.name().to_owned())) {
            diagnostics.push(diagnostic(
                PathBuf::from(source),
                "unused test-host preload declaration",
            ));
        }
    }
    diagnostics
}

fn alias_overlay(root: &Path, descriptors: &[Alias]) -> Vec<RequireAlias> {
    descriptors
        .iter()
        .filter(|alias| alias.resolution == Resolution::Mounted)
        .map(|alias| RequireAlias {
            name: alias.name.into(),
            path: root.join("lua").join(alias.name),
        })
        .collect()
}

fn normalize_target(root: &Path, allowed_roots: &[PathBuf], observation: &mut RequireObservation) {
    let RequireOutcome::Resolved(target) = &observation.outcome else {
        return;
    };
    let canonical = match target.canonicalize() {
        Ok(canonical) => canonical,
        Err(error) => {
            observation.outcome = RequireOutcome::Unresolved(format!(
                "reading resolved target {}: {error}",
                target.display()
            ));
            return;
        }
    };
    if !allowed_roots
        .iter()
        .any(|allowed| canonical.starts_with(allowed))
    {
        observation.outcome = RequireOutcome::Unresolved(format!(
            "resolved target {} escapes the declared source roots",
            canonical.display()
        ));
        return;
    }
    observation.outcome = RequireOutcome::Resolved(relative(root, &canonical));
}

fn collect(
    root: &Path,
    path: &Path,
    declared_roots: &[PathBuf],
    active: &mut BTreeSet<PathBuf>,
    files: &mut BTreeSet<PathBuf>,
    diagnostics: &mut Vec<Diagnostic>,
) -> Result<(), ScanError> {
    let canonical = read_at(path, || path.canonicalize())?;
    if !canonical.starts_with(root) {
        diagnostics.push(diagnostic(
            relative(root, path),
            "source symlink escapes the scan root",
        ));
        return Ok(());
    }
    let metadata = read_at(path, || fs::metadata(path))?;
    if metadata.is_file() {
        files.insert(relative(root, path));
        return Ok(());
    }
    if !metadata.is_dir() {
        diagnostics.push(diagnostic(
            relative(root, path),
            "source inventory contains a non-file entry",
        ));
        return Ok(());
    }
    // A symlink to a declared root is another view, not a second ownership declaration.
    if canonical != path && declared_roots.contains(&canonical) {
        return Ok(());
    }
    if !active.insert(canonical.clone()) {
        diagnostics.push(diagnostic(
            relative(root, path),
            "source inventory contains a directory symlink cycle",
        ));
        return Ok(());
    }
    let entries = read_at(path, || fs::read_dir(path))?;
    for entry in entries {
        let entry = read_at(path, || entry)?;
        collect(
            root,
            &entry.path(),
            declared_roots,
            active,
            files,
            diagnostics,
        )?;
    }
    active.remove(&canonical);
    Ok(())
}

fn validate_context_paths(files: &BTreeSet<PathBuf>, diagnostics: &mut Vec<Diagnostic>) {
    for exception in WHITEBOX_EDGES {
        for path in [
            PathBuf::from(exception.source),
            PathBuf::from(format!("lua/lunette-plugins/{}", exception.target)),
        ] {
            if !files.contains(&path) {
                diagnostics.push(diagnostic(
                    path,
                    "white-box edge references a missing source or target",
                ));
            }
        }
    }
    for source in TEST_HOST_SOURCES {
        if !files.contains(Path::new(source)) {
            diagnostics.push(diagnostic(
                PathBuf::from(source),
                "test-host declaration references a missing source",
            ));
        }
    }
    for switch in CONFIGURATION_SWITCHES {
        for path in [
            PathBuf::from(switch.source),
            PathBuf::from(switch.configuration).join("main.luau"),
        ] {
            if !files.contains(&path) {
                diagnostics.push(diagnostic(
                    path,
                    "configuration switch references a missing source or anchor",
                ));
            }
        }
    }
}

fn relative(root: &Path, path: &Path) -> PathBuf {
    path.strip_prefix(root).unwrap_or(path).into()
}

fn diagnostic(source: PathBuf, message: &str) -> Diagnostic {
    Diagnostic {
        source,
        line: 0,
        column: 0,
        target: None,
        message: message.into(),
    }
}

fn read_at<T>(path: &Path, read: impl FnOnce() -> io::Result<T>) -> Result<T, ScanError> {
    read().map_err(|cause| ScanError {
        path: path.into(),
        cause,
    })
}
