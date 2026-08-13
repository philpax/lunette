# Evolve `lunette --dump-config` into `lunette init`

Labels: enhancement

## Current state

`lunette --dump-config` copies the shipped configuration from `etc/xdg/lunette` into the user's configuration directory and refuses to overwrite what is there. It writes nothing else.

A configuration is Luau, and `lunette check` typechecks one against `etc/lunette/definitions.luau`. An editor does the same through luau-lsp, which needs a `.luaurc` naming the aliases the configuration requires through, and a client setting naming the definitions file. The user writes both by hand. Without the `.luaurc`, a require does not resolve and the file is skipped whole. Without `"languageMode": "strict"` in that `.luaurc`, luau-lsp reports nothing for errors `lunette check` reports, so the editor is laxer than the check the user will fail later.

The definitions are also not installed. `lunette check` looks for `$PREFIX/share/lunette/definitions.luau` when no path is given, and the Makefile installs no such file.

## Change

`--dump-config` becomes `lunette init`, keeping what it does and writing the editor files with it.

`lua/.luaurc` and `etc/xdg/lunette/.luaurc` are checked in rather than generated: they carry relative paths, so the tree resolves where it stands. The files `lunette init` writes carry absolute paths, because a configuration directory is not inside the tree: `<config>/.luaurc`, and `<config>/.vscode/settings.json` naming `"luau-lsp.platform.type": "standard"` and `"luau-lsp.types.definitionFiles"`. Both keys were confirmed through `luau-lsp analyze --settings=`, which takes what a client sends.

Re-running merges rather than writing only what is absent. The existing JSON is read, every key that is not lunette's is kept, and lunette's are replaced. That is what lets an upgrade correct the definitions path without discarding the user's own settings, and it is what lune does.

The settings name the install path rather than a versioned copy of the definitions, so the definitions travel with the binary and cannot go stale against the runtime they describe. A configuration that is out of date against the runtime still reports as type errors in the user's own file.

Installing the definitions is a prerequisite. Nothing installs `etc/lunette/definitions.luau`, and both the generated settings and `lunette check`'s fallback name a path under the prefix.

`lunette init --force-regenerate` replaces the Lua as well. It destroys work, so it names the files it will replace and asks first.

Neovim cannot be configured by a dropped file, so the lspconfig snippet is documented rather than written.

## Done when

Running `lunette init` into an empty directory produces a configuration that luau-lsp reports the same diagnostics for as `lunette check` does, including the case where the two would disagree without `"languageMode": "strict"`.
