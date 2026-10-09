//! Linux platform: builds LÖVR as `liblovr.so` and links it dynamically.
//!
//! Three jobs, in order: configure and build LÖVR through cmake, locate the
//! shared library the build produces and emit the link directives for it, and
//! generate the FFI bindings with bindgen.
//!
//! LÖVR exports no CMake interface: every compile definition and include
//! directory on the `lovr` target is `PRIVATE` except `LOVR_OMIT_MAIN`, so the
//! bindgen pass mirrors both manually from `vendor/lovr/CMakeLists.txt`.

use std::{
    env,
    error::Error,
    ffi::OsString,
    fmt, io,
    path::{Path, PathBuf},
    process::ExitCode,
};

/// The prefetched JoltPhysics tree, provided by the Nix devshell.
///
/// `vendor/lovr/deps/joltc` fetches JoltPhysics through `FetchContent`, which
/// requires the network at configure time. Pointing
/// `FETCHCONTENT_SOURCE_DIR_JOLTPHYSICS` at the prefetched tree keeps the
/// build offline.
const JOLT_SOURCE_VAR: &str = "LUNETTE_JOLTPHYSICS_SRC";

/// The LÖVR compile definitions that apply in the default configuration.
///
/// They mirror `vendor/lovr/CMakeLists.txt`: `LOVR_USE_GLSLANG`, `LOVR_VK`,
/// `LOVR_USE_GLFW`, and `LOVR_USE_PHONON`. No `LOVR_DISABLE_*` is defined,
/// because none is set by default.
const LOVR_DEFINES: [&str; 4] = [
    "-DLOVR_VK",
    "-DLOVR_USE_GLSLANG",
    "-DLOVR_USE_GLFW",
    "-DLOVR_USE_PHONON",
];

/// The private include directories of the `lovr` target, from
/// `vendor/lovr/CMakeLists.txt`, relative to `vendor/lovr`.
///
/// `lua.h` comes from `deps/luau/VM/include`, alongside the Compiler and Ast
/// headers LÖVR's own source takes from the Luau target's interface includes.
const LOVR_INCLUDE_DIRS: [&str; 4] = [
    "src",
    "src/modules",
    "etc",
    // LÖVR's `api.h` includes `<lua.h>`; under `LOVR_USE_LUAU` the Luau
    // headers are not on any include path bindgen uses, so the VM include
    // directory is added manually, mirroring the include paths the `Luau.VM`
    // target's interface gives the compiler.
    "deps/luau/VM/include",
];

fn main() -> ExitCode {
    match build() {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            // `cargo::error=` carries a single line, so the chain is flattened
            // onto one and any embedded newline is folded into it.
            let mut chain = vec![error.to_string()];
            let mut cause: Option<&dyn Error> = error.source();
            while let Some(current) = cause {
                chain.push(current.to_string());
                cause = current.source();
            }
            println!("cargo::error={}", chain.join(": ").replace('\n', "; "));
            ExitCode::FAILURE
        }
    }
}

fn build() -> Result<(), BuildError> {
    // A build script is the exception to the rule that a library never reads
    // the environment: Cargo passes OUT_DIR, CARGO_MANIFEST_DIR, and the rest
    // through no other channel, and the devshell supplies the JoltPhysics tree
    // the same way.
    let manifest_dir = PathBuf::from(required_var("CARGO_MANIFEST_DIR")?);
    let out_dir = PathBuf::from(required_var("OUT_DIR")?);
    let jolt_source = env::var_os(JOLT_SOURCE_VAR);
    if jolt_source.is_none() {
        println!(
            "cargo::warning={JOLT_SOURCE_VAR} is unset, so cmake fetches JoltPhysics over the \
             network at configure time. Set it to a checkout of the revision \
             `vendor/lovr/deps/joltc/CMakeLists.txt` declares to build offline."
        );
    }
    let lovr_dir = canonicalize(&manifest_dir.join("../../vendor/lovr"))?;

    println!("cargo::rerun-if-env-changed={JOLT_SOURCE_VAR}");
    watch_lovr_sources(&lovr_dir)?;

    let cmake_out = build_lovr(&lovr_dir, jolt_source.as_ref());
    let lovr_build = find_lovr_build(&cmake_out)?;
    // The shim's Luau references require its link directives before `liblovr.so`.
    build_analyze_shim(&lovr_dir);
    emit_link_directives(&lovr_build);
    stage_boot_lua(&lovr_dir, &out_dir)?;
    generate_bindings(&manifest_dir, &lovr_dir, &out_dir)
}

/// Declares the LÖVR files whose contents govern the cmake build.
///
/// Cargo watches the package directory, and `vendor/lovr` is two directories
/// above it. Without these lines, a patch to LÖVR does not trigger a rerun,
/// and the stale `liblovr.so` is linked.
///
/// The files are named one by one. Handing Cargo the `src` directory would not
/// work: cmake writes generated headers back into the source tree,
/// `src/api/l_math.lua.h` and the shader headers under `etc/shaders`, both of
/// which LÖVR's own `.gitignore` pattern `*.*.h` covers. The directory has a
/// newer mtime after every build, and the build reruns for ever. Excluding
/// that pattern stops the rebuilds, and Cargo has no way to express an
/// exclusion against a directory entry.
///
/// Cargo does not watch a source file added to LÖVR until the next rerun.
/// `LOVR_SRC` in `CMakeLists.txt` lists every source explicitly, and adding
/// one edits a watched file.
///
/// The optional OpenVR SDK inputs are watched individually. Its CMake
/// integration writes no generated output under the dependency source tree.
fn watch_lovr_sources(lovr_dir: &Path) -> Result<(), BuildError> {
    println!(
        "cargo::rerun-if-changed={}",
        lovr_dir.join("CMakeLists.txt").display()
    );

    println!(
        "cargo::rerun-if-changed={}",
        lovr_dir.join("etc/boot.lua").display()
    );
    for directory in ["src", "etc/openvr", "etc/shaders"] {
        walk_files(&lovr_dir.join(directory), &mut |path| {
            if !is_generated_header(path) {
                println!("cargo::rerun-if-changed={}", path.display());
            }
        })?;
    }
    for directory in ["deps/openvr/src", "deps/openvr/headers"] {
        let directory = lovr_dir.join(directory);
        if !directory
            .try_exists()
            .map_err(|cause| BuildError::ReadDirectory {
                path: directory.clone(),
                cause,
            })?
        {
            println!("cargo::rerun-if-changed={}", directory.display());
            continue;
        }
        walk_files(&directory, &mut |path| {
            println!("cargo::rerun-if-changed={}", path.display());
        })?;
    }
    Ok(())
}

/// Whether a path matches the `*.*.h` pattern cmake generates headers under.
///
/// The generated names append `.h` to the source name: `l_math.lua.h` from
/// `l_math.lua`, `fill.frag.h` from `fill.frag`, so a hand-written `.h` never
/// matches unless its stem contains a dot, which none in LÖVR does.
fn is_generated_header(path: &Path) -> bool {
    path.extension().is_some_and(|extension| extension == "h")
        && Path::new(path.file_stem().unwrap_or_default())
            .extension()
            .is_some()
}

/// Configures and builds LÖVR, returning the cmake output directory.
///
/// The build targets `all`, not `install`. LÖVR's dependencies carry install
/// rules that do not hold in this configuration: phonon's expects a split
/// `.dbg` file that a shared build does not produce. The nixpkgs derivation
/// sets `dontUseCmakeInstall` for the same reason.
fn build_lovr(lovr_dir: &Path, jolt_source: Option<&OsString>) -> PathBuf {
    let configure = || {
        let mut config = cmake::Config::new(lovr_dir);
        // mlua links the Lua C API from `liblovr.so`, and `lunette check`
        // runs the type checker from the same library.
        config
            .define("LOVR_USE_LUAU", "ON")
            .define("LOVR_USE_LUAJIT", "OFF")
            .define("LOVR_EXPORT_LUA_SYMBOLS", "ON")
            .define("LOVR_LUAU_ANALYSIS", "ON");
        config
            .define("LOVR_BUILD_SHARED", "ON")
            .define("LOVR_BUILD_WITH_SYMBOLS", "ON");
        if env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("linux") {
            config.define("LOVR_ENABLE_OPENVR", "ON");
        }
        if let Some(source) = jolt_source {
            config.define("FETCHCONTENT_SOURCE_DIR_JOLTPHYSICS", source);
        }
        config
            // `vendor/lovr/CMakeLists.txt` sets `liblovr.so`'s rpath to
            // `$ORIGIN`, which resolves to the directory holding `liblovr.so`.
            // In the packaged layout every library is in that directory. In
            // the build tree the `move_files` target stages the shared
            // dependencies one level down in `bin/`, so `$ORIGIN/bin` must be
            // on the rpath as well. It cannot be supplied from the
            // executable's own link line: a `DT_RUNPATH` is not consulted
            // when resolving a dependency's dependencies.
            //
            // The backslash is written into cmake's generated link script;
            // the shell strips it there, and the linker reads a literal
            // `$ORIGIN`.
            .define("CMAKE_SHARED_LINKER_FLAGS", "-Wl,-rpath,\\$ORIGIN/bin")
            // LÖVR sets it on the targets it links. The define applies it to
            // every target.
            .define("CMAKE_POSITION_INDEPENDENT_CODE", "ON");
        config
    };

    let cmake_out = configure().build_target("all").build();

    // `move_files` populates the staged `bin/` tree. It is an `ALL` custom
    // target with no declared dependency on the libraries it copies
    // (`vendor/lovr/CMakeLists.txt`), so a parallel build can run it while
    // those libraries do not exist yet. Building it once more, after
    // everything else, makes the staged tree deterministic: a custom target
    // is always out of date, so its copies run again.
    configure().build_target("move_files").build();

    cmake_out
}

/// Emits the search paths, the libraries, and the rpath entries LÖVR needs.
///
/// One library is named: `LOVR_USE_LUAU` links `Luau.VM`, `Luau.Compiler`, and
/// `Luau.Ast` into `liblovr.so`, and `LUAU_EXTERN_C` exports the Lua C API
/// from it, so the symbols mlua declares are resolved from there.
fn emit_link_directives(build: &LovrBuild) {
    let library_dir = build.library_dir.display();
    let staged_dir = build.staged_dir.display();

    println!("cargo::rustc-link-search=native={library_dir}");
    println!("cargo::rustc-link-search=native={staged_dir}");
    println!("cargo::rustc-link-lib=dylib=lovr");

    // `rustc-link-arg` is emitted, not `rustc-link-arg-bins`: test binaries
    // under `target/debug/deps/` resolve the library too. Cargo passes the
    // string to `rustc -C link-arg` with no shell involved, so the literal
    // `$ORIGIN` reaches the dynamic linker intact.
    //
    // The rpath arguments apply to the package's own targets and no further.
    // The directories are also emitted as `cargo::metadata` lines, so a
    // dependent that links an executable can emit its own rpath entries from
    // them.
    println!("cargo::rustc-link-arg=-Wl,-rpath,{library_dir}");
    println!("cargo::rustc-link-arg=-Wl,-rpath,{staged_dir}");
    println!("cargo::rustc-link-arg=-Wl,-rpath,$ORIGIN");

    println!("cargo::metadata=library_dir={library_dir}");
    println!("cargo::metadata=staged_dir={staged_dir}");
}

/// Compiles the C surface over Luau's frontend.
///
/// Nothing is linked beyond `liblovr.so`, which contains `Luau.Analysis`.
/// Naming the archives here would put a second copy of Luau in the process,
/// whose FFlag statics unify into a cycle that hangs static initialisation.
fn build_analyze_shim(lovr_dir: &Path) {
    let luau = lovr_dir.join("deps").join("luau");
    let shim = Path::new("src").join("analyze.cpp");

    println!("cargo::rerun-if-changed={}", shim.display());
    println!("cargo::rerun-if-changed=src/analyze_navigation.h");

    cc::Build::new()
        .cpp(true)
        .std("c++17")
        .file(&shim)
        .include(luau.join("Analysis/include"))
        .include(luau.join("Ast/include"))
        .include(luau.join("Config/include"))
        .include(luau.join("Common/include"))
        .include(luau.join("Require/include"))
        .compile("lunette_analyze");
}

/// Copies `etc/boot.lua` into `OUT_DIR` for the crate to embed.
///
/// CMake hex-dumps the same file into a generated `etc/boot.lua.h`
/// (`vendor/lovr/CMakeLists.txt`). That header is written into the source
/// tree, so letting cmake generate it would dirty the submodule. The bytes
/// are identical either way.
fn stage_boot_lua(lovr_dir: &Path, out_dir: &Path) -> Result<(), BuildError> {
    let source = lovr_dir.join("etc/boot.lua");
    let destination = out_dir.join("boot.lua");

    println!("cargo::rerun-if-changed={}", source.display());

    std::fs::copy(&source, &destination).map_err(|error| BuildError::CopyBootScript {
        source_path: source,
        destination,
        cause: error,
    })?;

    Ok(())
}

fn generate_bindings(
    manifest_dir: &Path,
    lovr_dir: &Path,
    out_dir: &Path,
) -> Result<(), BuildError> {
    let wrapper = manifest_dir.join("wrapper.h");
    println!("cargo::rerun-if-changed={}", wrapper.display());

    let include_dirs = LOVR_INCLUDE_DIRS.as_slice();
    let includes = include_dirs
        .iter()
        .map(|relative| format!("-I{}", lovr_dir.join(relative).display()));

    let bindings = bindgen::Builder::default()
        .header(wrapper.to_string_lossy())
        // The `lovr` target sets `C_STANDARD 11`
        // (`vendor/lovr/CMakeLists.txt`); bindgen parses the same dialect,
        // not whatever clang defaults to for a bare `.h`.
        .clang_args(["-x", "c", "-std=c11"])
        // Explicit clang arguments already provide headers; probing adds duplicate paths.
        .detect_include_paths(env::var_os("BINDGEN_EXTRA_CLANG_ARGS").is_none())
        .clang_args(includes)
        .clang_args(LOVR_DEFINES)
        .allowlist_function("luax_.*")
        // How a LOVR object becomes a Lua userdata with LOVR's own metatable.
        // The `luax_.*` pattern does not match `_luax_pushtype`, so the
        // allowlist names it separately. The macro callers write is
        // `luax_pushtype`, which resolves the `ObjectType` and calls this. It
        // retains the object itself (`api/api.c`), so a caller pushing a
        // texture it holds a reference to keeps the reference.
        .allowlist_function("_luax_pushtype")
        .allowlist_function("os_init")
        .allowlist_function("os_destroy")
        // The step loop calls this once per frame (`vendor/lovr/src/main.c`).
        .allowlist_function("os_sleep")
        // Whether GLFW has an open window. False when GLFW never initialised
        // (no `DISPLAY`) or when the window was never created.
        .allowlist_function("os_window_is_open")
        .allowlist_function("lovrSetLogCallback")
        // Reference counting. Every LOVR object is owned through these.
        // Calling a `lovr*Destroy` directly bypasses the count. `lovrRelease`
        // decrements the count and calls `lovr*Destroy`, the destructor.
        .allowlist_function("lovrRetain")
        .allowlist_function("lovrRelease")
        // The texture surface the import path is written against.
        .allowlist_function("lovrGraphicsIsInitialized")
        // Drains the GPU. The restart then shuts the XR session down.
        .allowlist_function("lovrGraphicsWait")
        .allowlist_function("lovrGraphicsGetFeatures")
        // Whether the device can blit a format. The layer swapchain is
        // `FORMAT_RGBA8` with sRGB and a client's window is usually
        // `FORMAT_BGRA8` without, so the copy between them uses
        // `lovrTextureBlit`, which requires `GPU_FEATURE_BLIT` on both.
        .allowlist_function("lovrGraphicsGetFormatSupport")
        .allowlist_function("lovrTextureCreate")
        .allowlist_function("lovrTextureDestroy")
        .allowlist_function("lovrTextureGetInfo")
        .allowlist_function("lovrTextureSetPixels")
        .allowlist_function("lovrTextureImportAcquire")
        .allowlist_function("lovrTextureImportRelease")
        .allowlist_function("lovrImageCreateRaw")
        .allowlist_function("lovrImageDestroy")
        .allowlist_function("lovrImageGetLayerData")
        // The single copy mechanism in the codebase: `window:stabilize()` and
        // the layer blits both call it, so the `syncStream` barriers are
        // emitted from a single place.
        .allowlist_function("lovrTextureCopy")
        // Clears the target of a copy. The size ladder rounds up, so a copy
        // usually covers part of a layer's swapchain image, and the rest of
        // that image is memory nothing has written.
        .allowlist_function("lovrTextureClear")
        // The most composition layers the runtime accepts in one `xrEndFrame`;
        // the layer pool's own budget stays below that number. It is not
        // `MAX_LAYERS`: that is LÖVR's compile-time array bound, and this is
        // the runtime's bound. Neither implies the other.
        .allowlist_function("lovrHeadsetGetLayerLimit")
        // Identifies the current session, which the layer limit does not: the
        // limit is read off the system, and the system remains valid after
        // `lovr.headset.stop()`, while every swapchain the pool holds does
        // not. The value is zero when no session exists, and otherwise a
        // generation number distinct from every earlier session's.
        // `lovrHeadsetIsActive` is not the signal, because a stop and a start
        // inside one Lua callback both return active, and the stop destroys
        // the swapchains.
        .allowlist_function("lovrHeadsetGetSessionGeneration")
        .allowlist_function("lovrHeadsetWillExit")
        // Creation and destruction of a pooled layer. `lovrLayerDestroy` is
        // allowlisted for use as the destructor `lovrRelease` calls. Calling
        // it directly bypasses the reference count; `lovrRelease` decrements
        // the count and calls the destructor. `LayerInfo` is allowlisted with
        // them, because it is the signature.
        .allowlist_function("lovrLayerCreate")
        .allowlist_function("lovrLayerDestroy")
        // The layer's current swapchain image, which the blit path copies
        // into. The call acquires, and the release at the end of every submit
        // resets the index, so the image it returns is that frame's.
        .allowlist_function("lovrLayerGetTexture")
        // The list the runtime composites. It persists across frames. The
        // pool releases the previous list, then retains the new one. The pool
        // holds a reference of its own to everything it puts here for that
        // reason.
        .allowlist_function("lovrHeadsetSetLayers")
        // How a `lun*` event reaches `lovr.handlers`. `CustomEvent`, `Event`,
        // and `EventType` are allowlisted with it, because they make up the
        // signature.
        .allowlist_function("lovrEventPush")
        // The Vulkan handles LOVR owns, declared in `wrapper.h` because no
        // LOVR header declares them.
        .allowlist_function("gpu_vk_get_.*")
        .allowlist_type("Variant")
        .allowlist_type("TextureFormat")
        // The `TEXTURE_*` usage bits and the `TEXTURE_2D` type, which are
        // anonymous and named enums respectively in `graphics.h`.
        .allowlist_type("TextureType")
        .allowlist_item("TEXTURE_.*")
        .blocklist_function("luax_vthrow")
        .blocklist_function("luax_vlog")
        .blocklist_function("lovrSetLogCallback")
        .blocklist_type("fn_log")
        .generate()
        .map_err(BuildError::GenerateBindings)?;

    let destination = out_dir.join("bindings.rs");
    bindings
        .write_to_file(&destination)
        .map_err(|error| BuildError::WriteBindings {
            destination,
            cause: error,
        })
}

/// The two directories a LÖVR build leaves its libraries in.
struct LovrBuild {
    /// The directory that holds `liblovr.so`.
    library_dir: PathBuf,
    /// The `bin/` tree LÖVR copies its shared dependencies into, LuaJIT among
    /// them.
    staged_dir: PathBuf,
}

/// Locates `liblovr.so` and the staged runtime tree beside it.
///
/// The install-prefix layout the `cmake` crate assumes does not describe the
/// build. LÖVR copies its shared dependencies into `${CMAKE_BINARY_DIR}/bin`
/// with the `move_files` target (`vendor/lovr/CMakeLists.txt`), while
/// `liblovr.so` remains at the binary directory's root, because
/// `RUNTIME_OUTPUT_DIRECTORY` does not govern a Linux shared library. The
/// function searches for the library; a guessed path produces a link error
/// far from its cause.
fn find_lovr_build(cmake_out: &Path) -> Result<LovrBuild, BuildError> {
    let mut found = Vec::new();
    collect_matches(cmake_out, "liblovr.so", &mut found)?;

    let [library] = found.as_slice() else {
        return Err(BuildError::LocateLibrary {
            searched: cmake_out.to_path_buf(),
            found,
        });
    };

    let library_dir = library.parent().ok_or(BuildError::LibraryAtRoot)?;
    let staged_dir = library_dir.join("bin");

    Ok(LovrBuild {
        library_dir: library_dir.to_path_buf(),
        staged_dir,
    })
}

fn collect_matches(dir: &Path, name: &str, found: &mut Vec<PathBuf>) -> Result<(), BuildError> {
    walk_files(dir, &mut |path| {
        if path.file_name().is_some_and(|entry| entry == name) {
            found.push(path.to_path_buf());
        }
    })
}

/// Calls `visit` for every non-directory entry below `dir`, depth first.
///
/// The function takes `visit` as a trait object, not as a generic: the
/// recursive call would otherwise instantiate the function at `&mut F` at each
/// level, and that instantiation never terminates.
fn walk_files(dir: &Path, visit: &mut dyn FnMut(&Path)) -> Result<(), BuildError> {
    let entries = std::fs::read_dir(dir).map_err(|error| BuildError::ReadDirectory {
        path: dir.to_path_buf(),
        cause: error,
    })?;

    for entry in entries {
        let entry = entry.map_err(|error| BuildError::ReadDirectory {
            path: dir.to_path_buf(),
            cause: error,
        })?;
        let path = entry.path();

        // `file_type` does not follow symlinks, so a self-referential link
        // cannot send the walk into a loop.
        let file_type = entry
            .file_type()
            .map_err(|error| BuildError::ReadDirectory {
                path: path.clone(),
                cause: error,
            })?;

        if file_type.is_dir() {
            walk_files(&path, visit)?;
        } else {
            visit(&path);
        }
    }

    Ok(())
}

fn required_var(name: &'static str) -> Result<OsString, BuildError> {
    env::var_os(name).ok_or(BuildError::MissingVariable(name))
}

fn canonicalize(path: &Path) -> Result<PathBuf, BuildError> {
    std::fs::canonicalize(path).map_err(|error| BuildError::Canonicalize {
        path: path.to_path_buf(),
        cause: error,
    })
}

#[derive(Debug)]
enum BuildError {
    MissingVariable(&'static str),
    Canonicalize {
        path: PathBuf,
        cause: io::Error,
    },
    LocateLibrary {
        searched: PathBuf,
        found: Vec<PathBuf>,
    },
    LibraryAtRoot,
    CopyBootScript {
        source_path: PathBuf,
        destination: PathBuf,
        cause: io::Error,
    },
    ReadDirectory {
        path: PathBuf,
        cause: io::Error,
    },
    GenerateBindings(bindgen::BindgenError),
    WriteBindings {
        destination: PathBuf,
        cause: io::Error,
    },
}

impl fmt::Display for BuildError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "lovr build: ")?;
        match self {
            Self::MissingVariable(name) => {
                write!(f, "{name} is unset, and Cargo is what provides it")
            }
            Self::Canonicalize { path, cause: _ } => {
                write!(f, "could not resolve {}", path.display())
            }
            Self::LocateLibrary { searched, found } => {
                write!(
                    f,
                    "expected exactly one liblovr.so under {}, found {}",
                    searched.display(),
                    found.len()
                )?;
                for path in found {
                    write!(f, "\n  {}", path.display())?;
                }
                Ok(())
            }
            Self::LibraryAtRoot => {
                write!(f, "liblovr.so has no parent directory to link against")
            }
            Self::CopyBootScript {
                source_path,
                destination,
                cause: _,
            } => write!(
                f,
                "could not copy {} to {}",
                source_path.display(),
                destination.display()
            ),
            Self::ReadDirectory { path, cause: _ } => {
                write!(f, "could not read {}", path.display())
            }
            Self::GenerateBindings(_) => write!(f, "bindgen could not parse wrapper.h"),
            Self::WriteBindings {
                destination,
                cause: _,
            } => write!(f, "could not write {}", destination.display()),
        }
    }
}

impl Error for BuildError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        match self {
            Self::Canonicalize { cause, .. }
            | Self::CopyBootScript { cause, .. }
            | Self::ReadDirectory { cause, .. }
            | Self::WriteBindings { cause, .. } => Some(cause),
            Self::GenerateBindings(cause) => Some(cause),
            Self::MissingVariable(_) | Self::LocateLibrary { .. } | Self::LibraryAtRoot => None,
        }
    }
}
