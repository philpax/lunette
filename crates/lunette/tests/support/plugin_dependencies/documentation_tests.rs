//! Exercises documentation boundaries with isolated files and the maintained source tree.

use std::{
    fs, io,
    path::{Path, PathBuf},
    process,
    sync::atomic::{AtomicUsize, Ordering},
};

use crate::plugin_dependencies::{
    catalog,
    documentation::{
        DocumentationDiagnostic, DocumentationIssue, check_author_exports, check_links,
        check_navigation, maintained_documentation,
    },
};

#[test]
fn documentation_checker_rejects_missing_anchor_and_private_advertisement() -> io::Result<()> {
    let fixture = Fixture::new()?;
    fixture.write("guide.md", "# Guide\n[Missing](removed.md)\n")?;
    let errors = check_links(&fixture.root, &[PathBuf::from("guide.md")]);
    assert_issue(
        &errors,
        DocumentationIssue::MissingTarget,
        "guide.md",
        2,
        "removed.md",
    );

    fixture.write("target.md", "# Existing heading\n")?;
    fixture.write("guide.md", "# Guide\n[Wrong anchor](target.md#absent)\n")?;
    let errors = check_links(&fixture.root, &[PathBuf::from("guide.md")]);
    assert_issue(
        &errors,
        DocumentationIssue::MissingAnchor,
        "guide.md",
        2,
        "target.md#absent",
    );

    let guide = "lua/lunette-plugins/audio/capture/README.md";
    fixture.write(
        "lua/lunette-plugins/audio/capture/private/reader.luau",
        "return {}\n",
    )?;
    fixture.write(guide, "# Audio capture\n[Reader](private/reader.luau)\n")?;
    assert!(check_links(&fixture.root, &[PathBuf::from(guide)]).is_empty());
    let errors = check_author_exports(&fixture.root, &[PathBuf::from(guide)]);
    assert_issue(
        &errors,
        DocumentationIssue::PrivateAdvertisement,
        guide,
        2,
        "private/reader.luau",
    );
    assert!(errors[0].message.contains("@lunette-plugins/audio/capture"));

    fixture.write(guide, "# Audio capture\n```luau\nlocal reader = require '@lunette-plugins/audio/capture/private/reader'\n```\n")?;
    let errors = check_author_exports(&fixture.root, &[PathBuf::from(guide)]);
    assert_issue(
        &errors,
        DocumentationIssue::PrivateAdvertisement,
        guide,
        3,
        "@lunette-plugins/audio/capture/private/reader",
    );
    Ok(())
}

#[test]
fn documentation_checker_accepts_implementation_and_provenance_links() -> io::Result<()> {
    let fixture = Fixture::new()?;
    let guide = "lua/lunette-plugins/audio/capture/README.md";
    fixture.write(
        "lua/lunette-plugins/audio/capture/private/reader.luau",
        "return {}\n",
    )?;
    fixture.write(
        "lua/lunette-plugins/audio/capture/fonts/OFL.txt",
        "Font licence\n",
    )?;
    fixture.write("CREDITS.md", "# Credits\n")?;
    fixture.write("crates/lunette-compositor/PROVENANCE.md", "# Provenance\n")?;
    fixture.write(guide, "# Audio capture\n## Implementation references\n[Reader][implementation]\n[implementation]: private/reader.luau\n### Resource handling\n[Reader](private/reader.luau)\n## Attribution\n[Font licence](fonts/OFL.txt)\n[Credits](../../../../CREDITS.md#credits)\n[Provenance](../../../../crates/lunette-compositor/PROVENANCE.md)\n")?;
    assert_clean(check_links(&fixture.root, &[PathBuf::from(guide)]));
    assert_clean(check_author_exports(&fixture.root, &[PathBuf::from(guide)]));

    fixture.write(guide, "# Audio capture\n## Implementation\n`require '@lunette-plugins/audio/capture/private/reader'`\n")?;
    let errors = check_author_exports(&fixture.root, &[PathBuf::from(guide)]);
    assert_issue(
        &errors,
        DocumentationIssue::PrivateAdvertisement,
        guide,
        3,
        "@lunette-plugins/audio/capture/private/reader",
    );

    fixture.write(guide, "# Audio capture\n## Implementation\n[Reader](private/reader.luau)\n### Supported imports\n[Reader](private/reader.luau)\n")?;
    let errors = check_author_exports(&fixture.root, &[PathBuf::from(guide)]);
    assert_issue(
        &errors,
        DocumentationIssue::PrivateAdvertisement,
        guide,
        5,
        "private/reader.luau",
    );
    fixture.write(
        guide,
        "# Audio capture\n[Disguised source](private/LICENSE.luau)\n",
    )?;
    assert_issue(
        &check_author_exports(&fixture.root, &[PathBuf::from(guide)]),
        DocumentationIssue::PrivateAdvertisement,
        guide,
        2,
        "private/LICENSE.luau",
    );
    Ok(())
}

#[test]
fn documentation_checker_handles_markdown_links_and_heading_anchors() -> io::Result<()> {
    let fixture = Fixture::new()?;
    fixture.write("target (copy).md", "# A `named` heading\n## A named heading\nSetext heading\n--------------\n```md\n# Not a heading\n```\n<a id=\"explicit-anchor\"></a>\n")?;
    fixture.write("guide.md", "# Guide\n[Inline](<target (copy).md#a-named-heading> \"title\")\n[Duplicate](target%20%28copy%29.md#a-named-heading-1)\n[Setext][setext]\n[setext]: <target (copy).md#setext-heading>\n[Explicit][]\n[explicit]: <target (copy).md#explicit-anchor>\n[Shortcut]\n[shortcut]: <target (copy).md#a-named-heading>\n[Remote](https://example.invalid/absent#anchor)\n[Mail](mailto:fixture@example.invalid)\n[Source](source.luau#L1-L2)\n`[Not a link](missing.md)`\n```md\n[Not a link](missing.md)\n```\n")?;
    fixture.write("source.luau", "return {}\n")?;
    assert_clean(check_links(&fixture.root, &[PathBuf::from("guide.md")]));
    fixture.write(
        "guide.md",
        "[Code heading](target%20%28copy%29.md#not-a-heading)\n[Undefined][absent]\n[Wrong Markdown anchor](target%20%28copy%29.md#L10)\n",
    )?;
    let errors = check_links(&fixture.root, &[PathBuf::from("guide.md")]);
    assert_issue(
        &errors,
        DocumentationIssue::MissingAnchor,
        "guide.md",
        1,
        "target%20%28copy%29.md#not-a-heading",
    );
    assert_issue(
        &errors,
        DocumentationIssue::MalformedMarkdown,
        "guide.md",
        2,
        "absent",
    );
    assert_issue(
        &errors,
        DocumentationIssue::MissingAnchor,
        "guide.md",
        3,
        "target%20%28copy%29.md#L10",
    );
    Ok(())
}

#[test]
fn documentation_checker_requires_exact_public_exports() -> io::Result<()> {
    let fixture = Fixture::new()?;
    let guide = "docs/plugins/author.md";
    fixture.write(guide, "# Author imports\n`@lunette-plugins/audio/capture`\n`@lunette-plugins/audio/capture/config`\n`@lunette-plugins/input/keyboard/hooks`\n`@lunette-plugins/graphics/pass-state`\n[Schema](../../lua/lunette-contracts/schemas/theme.luau)\n")?;
    assert_clean(check_author_exports(&fixture.root, &[PathBuf::from(guide)]));
    for module in [
        "audio",
        "graphics",
        "graphics/unlisted",
        "input/keyboard/legend-bounds",
        "audio/capture/config/nested",
        "audio/capture/../analysis",
    ] {
        fixture.write(
            guide,
            &format!("# Author imports\n`@lunette-plugins/{module}`\n"),
        )?;
        let errors = check_author_exports(&fixture.root, &[PathBuf::from(guide)]);
        assert_issue(
            &errors,
            DocumentationIssue::PrivateAdvertisement,
            guide,
            2,
            &format!("@lunette-plugins/{module}"),
        );
    }
    Ok(())
}

#[test]
fn documentation_navigation_requires_catalog_coverage_and_no_category_entry() -> io::Result<()> {
    let fixture = Fixture::new()?;
    fixture.write(
        "lua/lunette-plugins/README.md",
        &catalog::CATEGORIES
            .iter()
            .map(|category| format!("[{category}]({category}/README.md)\n"))
            .collect::<String>(),
    )?;
    for category in catalog::CATEGORIES {
        let mut links = String::from("# Category\n[Plugins](../README.md)\n");
        for plugin in catalog::PLUGINS
            .iter()
            .filter(|plugin| plugin.leaf.split('/').next() == Some(category))
        {
            let leaf = plugin
                .leaf
                .strip_prefix(&format!("{category}/"))
                .unwrap_or(plugin.leaf);
            links.push_str(&format!("[{leaf}]({leaf}/README.md)\n"));
            fixture.write(
                &format!("lua/lunette-plugins/{}/README.md", plugin.leaf),
                "# Plugin\n",
            )?;
        }
        for library in catalog::LIBRARIES
            .iter()
            .filter(|library| library.module.split('/').next() == Some(category))
        {
            let module = library
                .module
                .strip_prefix(&format!("{category}/"))
                .unwrap_or(library.module);
            links.push_str(&format!("[{module}]({module}.luau)\n"));
            fixture.write(
                &format!("lua/lunette-plugins/{}.luau", library.module),
                "return {}\n",
            )?;
        }
        fixture.write(&format!("lua/lunette-plugins/{category}/README.md"), &links)?;
    }
    assert_clean(check_navigation(&fixture.root));
    fixture.write(
        "lua/lunette-plugins/audio/README.md",
        "# Audio\n[Plugins](../README.md)\n",
    )?;
    let errors = check_navigation(&fixture.root);
    assert!(
        errors
            .iter()
            .any(|error| error.issue == DocumentationIssue::MissingNavigation
                && error.target == "lua/lunette-plugins/audio/capture/README.md")
    );
    fixture.write("lua/lunette-plugins/audio/init.luau", "return {}\n")?;
    assert!(
        check_navigation(&fixture.root)
            .iter()
            .any(|error| error.issue == DocumentationIssue::CategoryEntry)
    );
    Ok(())
}

#[test]
fn documentation_scope_includes_filesystem_guides_and_linked_user_workflows() -> io::Result<()> {
    let fixture = Fixture::new()?;
    fixture.write("lua/lunette-plugins/old-plugin/README.md", "# Old guide\n")?;
    fixture.write(
        "docs/plugins/nested/guide.md",
        "# Guide\n[Workflow](../../users/additional.md)\n",
    )?;
    fixture.write("docs/users/additional.md", "# Workflow\n[Next](next.md)\n")?;
    fixture.write("docs/users/next.md", "# Next workflow\n")?;
    let scope = maintained_documentation(&fixture.root)?;
    for path in [
        "lua/lunette-plugins/audio/capture/README.md",
        "lua/lunette-plugins/old-plugin/README.md",
        "docs/plugins/nested/guide.md",
        "docs/users/additional.md",
        "docs/users/next.md",
        "CONTRIBUTING.md",
    ] {
        assert!(
            scope.contains(&PathBuf::from(path)),
            "missing scope member: {path}"
        );
    }
    assert_eq!(scope, maintained_documentation(&fixture.root)?);
    Ok(())
}

#[test]
fn category_readmes_and_navigation_are_complete() {
    assert_clean(check_navigation(&repository_root()));
}

#[test]
fn maintained_documentation_links_resolve() -> io::Result<()> {
    let root = repository_root();
    assert_clean(check_links(&root, &maintained_documentation(&root)?));
    Ok(())
}

#[test]
fn author_documentation_advertises_only_public_exports() -> io::Result<()> {
    let root = repository_root();
    assert_clean(check_author_exports(
        &root,
        &maintained_documentation(&root)?,
    ));
    Ok(())
}

fn repository_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../..")
}

fn assert_clean(errors: Vec<DocumentationDiagnostic>) {
    assert!(
        errors.is_empty(),
        "{}",
        errors
            .iter()
            .map(ToString::to_string)
            .collect::<Vec<_>>()
            .join("\n")
    );
}

fn assert_issue(
    errors: &[DocumentationDiagnostic],
    issue: DocumentationIssue,
    source: &str,
    line: usize,
    target: &str,
) {
    assert!(
        errors.iter().any(|error| error.issue == issue
            && error.source == Path::new(source)
            && error.line == line
            && error.target == target),
        "expected {issue:?} at {source}:{line} for {target}; got {errors:#?}"
    );
}

static NEXT_FIXTURE: AtomicUsize = AtomicUsize::new(0);

struct Fixture {
    root: PathBuf,
}

impl Fixture {
    fn new() -> io::Result<Self> {
        let root = std::env::temp_dir().join(format!(
            "lunette-documentation-{}-{}",
            process::id(),
            NEXT_FIXTURE.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&root)?;
        Ok(Self { root })
    }

    fn write(&self, path: &str, content: &str) -> io::Result<()> {
        let path = self.root.join(path);
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        fs::write(path, content)
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        if let Err(error) = fs::remove_dir_all(&self.root) {
            assert!(
                std::thread::panicking(),
                "documentation fixture cleanup: {}: {error}",
                self.root.display()
            );
        }
    }
}
