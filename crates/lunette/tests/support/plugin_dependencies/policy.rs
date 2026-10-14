//! Pure dependency, inventory, and file-cycle decisions.

use std::{
    collections::{BTreeMap, BTreeSet},
    fmt,
    path::{Path, PathBuf},
};

use lunette_lovr::analyze::{MemberCallObservation, RequireObservation, RequireOutcome};

use crate::plugin_dependencies::{
    catalog::{
        CATEGORIES, CONFIGURATION_SWITCHES, CONFIGURED_LOADS, CONTRACT_SCHEMAS, EXTENSION_SUPPORT,
        LibraryDomain, PLUGINS, Preloaded, REMOVED_HELPERS, TEST_HOST_SOURCES, WHITEBOX_EDGES,
    },
    ownership::{Owner, Ownership, Role, Visibility, ownership, public_plugin_files},
};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Diagnostic {
    pub source: PathBuf,
    pub line: u32,
    pub column: u32,
    pub target: Option<PathBuf>,
    pub message: String,
}

impl fmt::Display for Diagnostic {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            formatter,
            "plugin dependencies: {}:{}:{}: {}",
            self.source.display(),
            self.line,
            self.column,
            self.message
        )?;
        if let Some(target) = &self.target {
            write!(formatter, " (target {})", target.display())?;
        }
        Ok(())
    }
}

pub struct Edge<'a> {
    pub source_path: &'a Path,
    pub source: &'a Ownership,
    pub target_path: &'a Path,
    pub target: &'a Ownership,
    pub installed: bool,
}

pub fn check_edge(edge: &Edge<'_>) -> Result<(), String> {
    let Edge {
        source_path,
        source,
        target_path,
        target,
        installed,
    } = edge;
    if source.role == Role::Config
        && matches!(target.owner, Owner::Plugin(_))
        && target.visibility == Visibility::Private
        && source.owner != target.owner
    {
        return Err("public config schemas cannot import another plugin's private implementation; use neutral schemas".into());
    }
    if *installed
        && (development_owner(&source.owner)
            || development_owner(&target.owner)
            || source.visibility == Visibility::Test
            || target.visibility == Visibility::Test)
    {
        return Err("installed modules cannot use development or test sources".into());
    }
    if source.visibility == Visibility::Test
        && !installed
        && WHITEBOX_EDGES.iter().any(|exception| {
            *source_path == Path::new(exception.source)
                && *target_path == Path::new(&format!("lua/lunette-plugins/{}", exception.target))
        })
    {
        return Ok(());
    }
    let same_owner = source.owner == target.owner;
    let configured = !installed
        && source.visibility == Visibility::Test
        && CONFIGURED_LOADS.iter().any(|load| {
            *source_path == Path::new(load.source) && *target_path == Path::new(load.target)
        });
    if configured {
        return Ok(());
    }
    if target.visibility == Visibility::Test {
        if source.visibility == Visibility::Test && (same_owner || configured) {
            return Ok(());
        }
        return Err("test files are owner-local; cross-owner imports must use public exports or an exact configured load".into());
    }
    if development_owner(&target.owner) {
        let development_entry = matches!(&source.owner, Owner::Development(name) if name == "configuration")
            && !source_path.starts_with("dev/plugins")
            && matches!(&target.owner, Owner::Development(_))
            && target_path.starts_with("dev/plugins")
            && matches!(target.role, Role::Entry | Role::Config);
        if same_owner
            || development_entry
            || (source.visibility == Visibility::Test && target.owner == Owner::Testing)
        {
            return Ok(());
        }
        return Err("shipped sources cannot import testing or development modules".into());
    }
    if source.visibility != Visibility::Test
        && matches!(
            source.owner,
            Owner::Contracts | Owner::Native | Owner::Facade
        )
    {
        if matches!(
            target.owner,
            Owner::Native | Owner::Facade | Owner::Contracts
        ) {
            return Ok(());
        }
        return Err("neutral contracts and facade/schema modules use only contracts, facade, and native API".into());
    }
    if let Owner::Library(_, domain) = source.owner
        && source.visibility != Visibility::Test
        && !library_target(domain, target)
    {
        return Err(format!(
            "{domain:?} library cannot depend on provider, desktop, or unrelated policy; use neutral contracts and mechanism libraries"
        ));
    }
    if matches!(source.owner, Owner::Extension(_))
        && source.visibility != Visibility::Test
        && matches!(target.owner, Owner::Plugin(_))
    {
        return Err(
            "public extensions cannot depend on plugin implementation or activation entries".into(),
        );
    }
    if target.visibility == Visibility::Private {
        let extension_support = matches!((&source.owner, &target.owner),
            (Owner::Plugin(plugin), Owner::Extension(extension)) if plugin == extension);
        if same_owner || extension_support {
            return Ok(());
        }
        return Err(format!(
            "{:?} cannot import private {:?}; use its entry, config, or an explicitly supported extension",
            source.owner, target.owner
        ));
    }
    if same_owner {
        return Ok(());
    }
    match &target.owner {
        Owner::Native
        | Owner::Facade
        | Owner::Contracts
        | Owner::Library(_, _)
        | Owner::Extension(_) => Ok(()),
        Owner::Plugin(_)
            if !matches!(source.owner, Owner::Library(_, _) | Owner::Extension(_))
                || source.visibility == Visibility::Test =>
        {
            Ok(())
        }
        Owner::Desktop
            if matches!(
                source.owner,
                Owner::Desktop
                    | Owner::Configuration
                    | Owner::Example(_)
                    | Owner::Development(_)
                    | Owner::Testing
            ) || source.visibility == Visibility::Test =>
        {
            Ok(())
        }
        _ => Err(format!(
            "{:?} cannot depend on {:?}; use public plugin exports, contracts, and libraries",
            source.owner, target.owner
        )),
    }
}

pub fn check_observation(
    source_path: &Path,
    source: &Ownership,
    observation: &RequireObservation,
    installed: bool,
) -> Result<Option<PathBuf>, Diagnostic> {
    let error = |message: String, target: Option<PathBuf>| Diagnostic {
        source: source_path.into(),
        line: observation.line,
        column: observation.column,
        target,
        message,
    };
    match &observation.outcome {
        RequireOutcome::Resolved(target_path) => {
            let target = ownership(target_path).map_err(|message| error(message, Some(target_path.clone())))?;
            check_edge(&Edge { source_path, source, target_path, target: &target, installed })
                .map_err(|message| error(message, Some(target_path.clone())))?;
            Ok(Some(target_path.clone()))
        }
        RequireOutcome::Preloaded(name) => {
            check_preloaded(source_path, source, name, installed).map_err(|message| error(message, None))?;
            Ok(None)
        }
        RequireOutcome::Dynamic => Err(error("dynamic module loads are not declared; use a literal import or explicit built-in registry".into(), None)),
        RequireOutcome::Escaped => Err(error("global require escapes as a value; call the loader directly with a literal".into(), None)),
        RequireOutcome::Overwritten => Err(error("global require is overwritten".into(), None)),
        RequireOutcome::Unsupported => Err(error("unsupported global loader form; call require directly".into(), None)),
        RequireOutcome::Unresolved(reason) => Err(error(format!("module {:?} does not resolve: {reason}", observation.requested), None)),
    }
}

pub fn check_preloaded(
    source_path: &Path,
    source: &Ownership,
    name: &str,
    installed: bool,
) -> Result<(), String> {
    if name == Preloaded::Native.name() {
        return Ok(());
    }
    if name == Preloaded::TestHost.name()
        && !installed
        && source.owner == Owner::Testing
        && TEST_HOST_SOURCES
            .iter()
            .any(|path| source_path == Path::new(path))
    {
        return Ok(());
    }
    Err(format!(
        "preloaded module {name:?} is not permitted for {:?}; native @lunette is public, @testing/host is restricted to its exact support sources",
        source.owner
    ))
}

pub fn hierarchy_diagnostics(files: &BTreeSet<PathBuf>, installed: bool) -> Vec<Diagnostic> {
    let mut diagnostics = Vec::new();
    for expected in public_plugin_files()
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
        )
    {
        if !files.contains(Path::new(&expected)) {
            diagnostics.push(inventory_error(
                Path::new(&expected),
                "missing declared module",
            ));
        }
    }
    for category in CATEGORIES {
        let init = format!("lua/lunette-plugins/{category}/init.luau");
        if files.contains(Path::new(&init)) {
            diagnostics.push(inventory_error(
                Path::new(&init),
                "categories do not have activation entries",
            ));
        }
        if !installed {
            let readme = format!("lua/lunette-plugins/{category}/README.md");
            if !files.contains(Path::new(&readme)) {
                diagnostics.push(inventory_error(
                    Path::new(&readme),
                    "missing category README",
                ));
            }
        }
    }
    if !installed {
        for guide in ["lua/lunette-plugins/README.md".to_owned()]
            .into_iter()
            .chain(
                PLUGINS
                    .iter()
                    .map(|plugin| format!("lua/lunette-plugins/{}/README.md", plugin.leaf)),
            )
        {
            if !files.contains(Path::new(&guide)) {
                diagnostics.push(inventory_error(
                    Path::new(&guide),
                    "missing plugin boundary guide",
                ));
            }
        }
    }
    for plugin in PLUGINS {
        if plugin.previous != plugin.leaf {
            for suffix in [".luau", "/init.luau"] {
                let previous = format!("lua/lunette-plugins/{}{suffix}", plugin.previous);
                if files.contains(Path::new(&previous)) {
                    diagnostics.push(inventory_error(
                        Path::new(&previous),
                        "obsolete plugin entry; remove it rather than forwarding",
                    ));
                }
            }
        }
    }
    for helper in REMOVED_HELPERS {
        let previous = format!("lua/lunette-plugins/{helper}.luau");
        if files.contains(Path::new(&previous)) {
            diagnostics.push(inventory_error(
                Path::new(&previous),
                "obsolete helper path; use its declared library",
            ));
        }
    }
    for path in files.iter().filter(|path| {
        path.extension()
            .is_some_and(|extension| extension == "luau")
    }) {
        match ownership(path) {
            Err(message) => diagnostics.push(inventory_error(path, &message)),
            Ok(owned)
                if installed
                    && (owned.visibility == Visibility::Test
                        || development_owner(&owned.owner)) =>
            {
                diagnostics.push(inventory_error(
                    path,
                    "installed source inventory contains a test or development module",
                ));
            }
            Ok(_) => {}
        }
    }
    diagnostics
}

pub fn configured_load_diagnostics(
    files: &BTreeSet<PathBuf>,
    observed: &BTreeMap<(PathBuf, String), Vec<PathBuf>>,
) -> Vec<Diagnostic> {
    let mut diagnostics = Vec::new();
    for load in CONFIGURED_LOADS {
        for path in [
            load.source.to_owned(),
            load.target.to_owned(),
            format!("{}/main.luau", load.configuration),
        ] {
            if !files.contains(Path::new(&path)) {
                diagnostics.push(inventory_error(
                    Path::new(&path),
                    "configured load references a missing source, target, or configuration anchor",
                ));
            }
        }
        let key = (PathBuf::from(load.source), load.literal.to_owned());
        match observed.get(&key) {
            None => diagnostics.push(inventory_error(
                Path::new(load.source),
                &format!(
                    "unused configured load {:?} under {}",
                    load.literal, load.configuration
                ),
            )),
            Some(targets)
                if targets.is_empty()
                    || targets
                        .iter()
                        .any(|target| target != Path::new(load.target)) =>
            {
                diagnostics.push(inventory_error(
                    Path::new(load.source),
                    &format!(
                        "configured load {:?} must resolve exactly to {}, observed {targets:?}",
                        load.literal, load.target
                    ),
                ));
            }
            Some(_) => {}
        }
    }
    diagnostics
}

pub fn configuration_switch_diagnostics(
    observed: &BTreeMap<PathBuf, Vec<MemberCallObservation>>,
    installed: bool,
) -> Vec<Diagnostic> {
    let mut diagnostics = Vec::new();
    let mut used = BTreeSet::new();
    for (source, observations) in observed {
        for observation in observations {
            let declared = observation.argument.as_ref().is_some_and(|argument| {
                CONFIGURATION_SWITCHES.iter().any(|switch| {
                    source == Path::new(switch.source) && argument == switch.configuration
                })
            });
            if installed || !declared {
                diagnostics.push(Diagnostic {
                    source: source.clone(), line: observation.line, column: observation.column,
                    target: None, message: format!("configuration switch {:?} is not declared for this source; use an exact literal configuration from the catalog", observation.argument),
                });
            } else if let Some(argument) = &observation.argument {
                used.insert((source.clone(), argument.clone()));
            }
        }
    }
    if !installed {
        for switch in CONFIGURATION_SWITCHES {
            if !used.contains(&(
                PathBuf::from(switch.source),
                switch.configuration.to_owned(),
            )) {
                diagnostics.push(inventory_error(
                    Path::new(switch.source),
                    &format!(
                        "unused configuration switch declaration for {}",
                        switch.configuration
                    ),
                ));
            }
        }
    }
    diagnostics
}

pub fn cycle_diagnostics(edges: &BTreeMap<PathBuf, BTreeSet<PathBuf>>) -> Vec<Diagnostic> {
    let mut complete = BTreeSet::new();
    let mut stack = Vec::new();
    let mut diagnostics = Vec::new();
    for source in edges.keys() {
        visit(source, edges, &mut complete, &mut stack, &mut diagnostics);
    }
    diagnostics
}

fn library_target(domain: LibraryDomain, target: &Ownership) -> bool {
    if matches!(
        target.owner,
        Owner::Native | Owner::Facade | Owner::Contracts
    ) {
        return true;
    }
    let Owner::Library(_, target_domain) = target.owner else {
        return false;
    };
    match domain {
        LibraryDomain::Graphics => target_domain == LibraryDomain::Graphics,
        LibraryDomain::Registration => matches!(
            target_domain,
            LibraryDomain::Registration | LibraryDomain::Diagnostics | LibraryDomain::Lifecycle
        ),
        LibraryDomain::Lifecycle => target_domain == LibraryDomain::Lifecycle,
        LibraryDomain::Diagnostics => target_domain == LibraryDomain::Diagnostics,
        LibraryDomain::ThemeConfiguration => target_domain == LibraryDomain::ThemeConfiguration,
        LibraryDomain::UiConfiguration => matches!(
            target_domain,
            LibraryDomain::UiConfiguration | LibraryDomain::ThemeConfiguration
        ),
        LibraryDomain::Picking => target_domain == LibraryDomain::Picking,
        LibraryDomain::KeyboardHooks => target_domain == LibraryDomain::KeyboardHooks,
    }
}

fn development_owner(owner: &Owner) -> bool {
    matches!(
        owner,
        Owner::Testing | Owner::Development(_) | Owner::GraphicsTests
    )
}

fn inventory_error(path: &Path, message: &str) -> Diagnostic {
    Diagnostic {
        source: path.into(),
        line: 0,
        column: 0,
        target: None,
        message: message.into(),
    }
}

fn visit(
    node: &PathBuf,
    edges: &BTreeMap<PathBuf, BTreeSet<PathBuf>>,
    complete: &mut BTreeSet<PathBuf>,
    stack: &mut Vec<PathBuf>,
    diagnostics: &mut Vec<Diagnostic>,
) {
    if let Some(start) = stack.iter().position(|active| active == node) {
        let cycle: Vec<_> = stack[start..]
            .iter()
            .chain([node])
            .map(|path| path.display().to_string())
            .collect();
        diagnostics.push(inventory_error(
            node,
            &format!("file import cycle: {}", cycle.join(" -> ")),
        ));
        return;
    }
    if complete.contains(node) {
        return;
    }
    stack.push(node.clone());
    if let Some(targets) = edges.get(node) {
        for target in targets {
            visit(target, edges, complete, stack, diagnostics);
        }
    }
    stack.pop();
    complete.insert(node.clone());
}
