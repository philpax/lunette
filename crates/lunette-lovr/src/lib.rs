//! The FFI surface for the lunette fork of LÖVR.
//!
//! This crate owns the boundary between Rust and LÖVR. Its build script drives
//! LÖVR's cmake build, generates bindings with bindgen, and emits the link
//! directives for `liblovr.so` and the LuaJIT it ships. Everything the rest of
//! the workspace needs from LÖVR — the `luax_*` entry points, the platform
//! hooks, and the embedded `boot.lua` — is reached through here.
//!
//! Orchestration is not this crate's job. The boot sequence, the frame loop,
//! and the Lua state's lifetime belong to the `lunette` binary; this crate
//! exposes the mechanism those are written against.
