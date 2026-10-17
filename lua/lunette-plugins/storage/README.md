# Storage

Storage provides settings files for callers that keep a few settings across sessions. It has no plugin leaves, activation entry, or runtime services.

- [Settings file](settings-file.luau), `@lunette-plugins/storage/settings-file`, reads and writes a versioned settings file in LÖVR's save directory. Each known setting has a check, an invalid value falls back to its default and is reported, and fields the caller does not know are kept and written back. A file from a newer version is reported and never overwritten, so a newer version's settings survive a session of an older one. The file runs as Lua in an empty environment, because its contents are untrusted.

The caller owns its file path, its version, and when it saves. [Shipped plugins](../README.md) defines public imports.
