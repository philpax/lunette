# Storage

Storage keeps state across sessions. It has no plugin leaves, activation entry, or runtime services.

- [Saved settings](saved-settings.luau), `@lunette-plugins/storage/saved-settings`, is the file that keeps the session's saved settings, which the plugin runtime applies and records.
- [Versioned file](versioned-file.luau), `@lunette-plugins/storage/versioned-file`, reads and writes a versioned file of literal values in LÖVR's save directory. Writes go through `lunette.saveFile`, which replaces the file atomically. A file from a newer version is reported and not overwritten.

A save error before replacement leaves any previous file in place. A directory-flush error after replacement leaves the new file visible, but its survival across a crash or power loss is unconfirmed. A reported save failure therefore does not mean that the previous contents remain on disk.

## Saved settings

A saved setting is a field of an entry's configuration that the user changed during a session. The desktop passes the saved settings file to the plugin runtime, which applies each entry's saved fields over its configuration from `main.luau` when the session starts, so a saved field takes precedence over `main.luau`. A plugin receives its `Settings` as usual and does not read the file.

The runtime records a field in two ways. Configuring an entry through the composition service, as the runtime manager's Apply does, saves every field that differs from `main.luau`, and removes a field set back to its `main.luau` value. A plugin that applies a change itself saves it with `context:save(changes)`, which validates the changes against the entry's schema without restarting the entry:

```luau
setMode = function(_self: contract.Service, given: contract.Mode): ()
  mode = given
  context:save { mode = given }
  resolve()
end,
```

`context:save` answers false and saves nothing in a runtime that keeps no saved settings, such as a test session.

A saved field that fails its entry's schema, or that belongs to an entry the configuration no longer composes, is reported and not applied, and it stays in the file. If an entry fails to start with its saved fields, the runtime starts it again with its `main.luau` configuration, reports the failure, and keeps the fields until they are reset. A value that the file cannot hold, such as a callback, is reported and not saved. The runtime manager marks every saved field and resets it, and its Saved settings page lists every saved field, including those that do not apply.

[Shipped plugins](../README.md) defines public imports.
