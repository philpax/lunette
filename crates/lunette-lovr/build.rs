//! Linux platform: builds LÖVR as `liblovr.so`, links it dynamically, and
//! generates its FFI bindings.
//!
//! LÖVR exports no CMake interface, so the bindgen pass mirrors its private
//! definitions and include directories from `vendor/lovr/CMakeLists.txt`.

use std::{
    env,
    error::Error,
    ffi::OsString,
    fmt, io,
    path::{Path, PathBuf},
    process::ExitCode,
};

/// An optional prefetched JoltPhysics tree.
///
/// `deps/joltc` fetches JoltPhysics at configure time, so a prefetched tree
/// keeps the build offline.
const JOLT_SOURCE_VAR: &str = "LUNETTE_JOLTPHYSICS_SRC";

/// The LÖVR compile definitions that apply in the default configuration,
/// mirroring `vendor/lovr/CMakeLists.txt`.
const LOVR_DEFINES: [&str; 4] = [
    "-DLOVR_VK",
    "-DLOVR_USE_GLSLANG",
    "-DLOVR_USE_GLFW",
    "-DLOVR_USE_PHONON",
];

/// The private include directories of the `lovr` target, relative to
/// `vendor/lovr`.
const LOVR_INCLUDE_DIRS: [&str; 4] = [
    "src",
    "src/modules",
    "etc",
    // Under `LOVR_USE_LUAU` the Luau headers are on no include path bindgen
    // uses, so the VM include directory is added here.
    "deps/luau/VM/include",
];

fn main() -> ExitCode {
    match build() {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            // `cargo::error=` carries a single line, so the chain is flattened
            // onto one.
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
    // the environment: Cargo and the devshell pass their inputs through no
    // other channel.
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
    // The shim's Luau references require its link directives before
    // `liblovr.so`.
    build_analyze_shim(&lovr_dir);
    emit_link_directives(&lovr_build);
    stage_boot_lua(&lovr_dir, &out_dir)?;
    generate_bindings(&manifest_dir, &lovr_dir, &out_dir)
}

/// Declares the LÖVR files whose contents govern the cmake build.
///
/// `vendor/lovr` is outside the package directory, so without these a patch to
/// LÖVR does not rerun the build. Files are named one by one because cmake
/// writes generated headers into `src`, and watching the directory would rerun
/// the build for ever.
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
    for file in ["deps/luau/CMakeLists.txt", "deps/luau/Sources.cmake"] {
        println!("cargo::rerun-if-changed={}", lovr_dir.join(file).display());
    }
    for directory in [
        "deps/openvr/src",
        "deps/openvr/headers",
        "deps/luau/Analysis",
        "deps/luau/Ast",
        "deps/luau/Bytecode",
        "deps/luau/CodeGen",
        "deps/luau/Common",
        "deps/luau/Compiler",
        "deps/luau/Config",
        "deps/luau/Inliner",
        "deps/luau/Require",
        "deps/luau/VM",
        "deps/luau/extern",
    ] {
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
fn is_generated_header(path: &Path) -> bool {
    path.extension().is_some_and(|extension| extension == "h")
        && Path::new(path.file_stem().unwrap_or_default())
            .extension()
            .is_some()
}

/// Configures and builds LÖVR, returning the cmake output directory.
///
/// The build targets `all`, not `install`, because phonon's install rule
/// expects a `.dbg` file that a shared build does not produce.
fn build_lovr(lovr_dir: &Path, jolt_source: Option<&OsString>) -> PathBuf {
    let configure = || {
        let mut config = cmake::Config::new(lovr_dir);
        // mlua links the Lua C API from `liblovr.so`, and `lunette check` runs
        // the type checker from it.
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
            // In the build tree `move_files` stages the shared dependencies in
            // `bin/`, so `$ORIGIN/bin` must be on `liblovr.so`'s rpath. The
            // executable cannot supply it, because a `DT_RUNPATH` is not
            // consulted for a dependency's dependencies. The shell strips the
            // backslash in cmake's link script, leaving a literal `$ORIGIN`.
            .define("CMAKE_SHARED_LINKER_FLAGS", "-Wl,-rpath,\\$ORIGIN/bin")
            // LÖVR sets it only on the targets it links, and the define applies
            // it to every target.
            .define("CMAKE_POSITION_INDEPENDENT_CODE", "ON");
        config
    };

    let cmake_out = configure().build_target("all").build();

    // `move_files` declares no dependency on the libraries it copies, so a
    // parallel build can run it too early. A custom target is always out of
    // date, so building it again afterwards makes the staged tree
    // deterministic.
    configure().build_target("move_files").build();

    cmake_out
}

/// Emits the search paths, the libraries, and the rpath entries LÖVR needs.
///
/// Only `liblovr.so` is named, because it contains Luau and exports the Lua C
/// API mlua declares.
fn emit_link_directives(build: &LovrBuild) {
    let library_dir = build.library_dir.display();
    let staged_dir = build.staged_dir.display();

    println!("cargo::rustc-link-search=native={library_dir}");
    println!("cargo::rustc-link-search=native={staged_dir}");
    println!("cargo::rustc-link-lib=dylib=lovr");

    // `rustc-link-arg`, not `rustc-link-arg-bins`, so test binaries resolve the
    // library too. The directories are also emitted as `cargo::metadata`,
    // because the rpath arguments do not reach dependents.
    println!("cargo::rustc-link-arg=-Wl,-rpath,{library_dir}");
    println!("cargo::rustc-link-arg=-Wl,-rpath,{staged_dir}");
    println!("cargo::rustc-link-arg=-Wl,-rpath,$ORIGIN");

    println!("cargo::metadata=library_dir={library_dir}");
    println!("cargo::metadata=staged_dir={staged_dir}");
}

/// Compiles the C surface over Luau's frontend.
///
/// Nothing beyond `liblovr.so` is linked, because a second copy of Luau hangs
/// static initialisation on its FFlag statics.
fn build_analyze_shim(lovr_dir: &Path) {
    let luau = lovr_dir.join("deps").join("luau");
    let shim = Path::new("src").join("analyze.cpp");

    println!("cargo::rerun-if-changed={}", shim.display());
    println!("cargo::rerun-if-changed=src/analyze_navigation.h");

    let mut build = cc::Build::new();
    build.cpp(true).std("c++17").file(&shim);

    // Fortify requires optimisation, even when Cargo's debug profile requests none.
    if env::var("OPT_LEVEL").as_deref() == Ok("0") {
        build.opt_level(1);
    }

    // System includes suppress third-party header warnings without hiding shim warnings.
    for directory in [
        "Analysis/include",
        "Ast/include",
        "Config/include",
        "Common/include",
        "Require/include",
    ] {
        build.flag("-isystem").flag(luau.join(directory));
    }
    build.compile("lunette_analyze");
}

/// Copies `etc/boot.lua` into `OUT_DIR` for the crate to embed.
///
/// Letting cmake generate `etc/boot.lua.h` would write into the source tree and
/// dirty the submodule.
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
        // The `lovr` target sets `C_STANDARD 11`, and bindgen parses the same
        // dialect.
        .clang_args(["-x", "c", "-std=c11"])
        // Explicit clang arguments already provide headers; probing adds
        // duplicate paths.
        .detect_include_paths(env::var_os("BINDGEN_EXTRA_CLANG_ARGS").is_none())
        .clang_args(includes)
        .clang_args(LOVR_DEFINES)
        .allowlist_function("luax_.*")
        // The `luax_.*` pattern does not match `_luax_pushtype`, so it is named
        // separately. It retains the object, so a caller keeps its own
        // reference.
        .allowlist_function("_luax_pushtype")
        .allowlist_function("os_init")
        .allowlist_function("os_destroy")
        .allowlist_function("os_sleep")
        // False when GLFW never initialised or the window was never created.
        .allowlist_function("os_window_is_open")
        .allowlist_function("lovrSetLogCallback")
        // Calling a `lovr*Destroy` directly bypasses the reference count.
        .allowlist_function("lovrRelease")
        .allowlist_function("lovrGraphicsIsInitialized")
        .allowlist_function("lovrGraphicsWait")
        .allowlist_function("lovrGraphicsGetFeatures")
        // The layer swapchain is RGBA8 sRGB and a window is usually BGRA8, so
        // the copy needs `GPU_FEATURE_BLIT` on both.
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
        // `window:stabilize()` and the layer blits both copy through this, so
        // the `syncStream` barriers come from one place.
        .allowlist_function("lovrTextureCopy")
        // The size ladder rounds up, so a copy usually leaves part of the
        // swapchain image unwritten.
        .allowlist_function("lovrTextureClear")
        // The runtime's layer bound per `xrEndFrame`, which is distinct from
        // LÖVR's compile-time `MAX_LAYERS`.
        .allowlist_function("lovrHeadsetGetLayerLimit")
        // Identifies the current session, which is zero when none exists. The
        // system and its layer limit survive `lovr.headset.stop()` while the
        // swapchains do not, and `lovrHeadsetIsActive` misses a stop and start
        // inside one callback.
        .allowlist_function("lovrHeadsetGetSessionGeneration")
        .allowlist_function("lovrHeadsetWillExit")
        // `lovrLayerDestroy` is the destructor `lovrRelease` calls, and
        // `LayerInfo` is the signature.
        .allowlist_function("lovrLayerCreate")
        .allowlist_function("lovrLayerDestroy")
        // The release at the end of every submit resets the index, so the image
        // returned is that frame's.
        .allowlist_function("lovrLayerGetTexture")
        // The list persists across frames, so the pool holds its own reference
        // to everything in it.
        .allowlist_function("lovrHeadsetSetLayers")
        // `CustomEvent`, `Event`, and `EventType` make up the signature.
        .allowlist_function("lovrEventPush")
        // Declared in `wrapper.h` because no LÖVR header declares them.
        .allowlist_function("gpu_vk_get_.*")
        .allowlist_type("Variant")
        .allowlist_type("TextureFormat")
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
    /// The `bin/` tree LÖVR copies its shared dependencies into.
    staged_dir: PathBuf,
}

/// Locates `liblovr.so` and the staged runtime tree beside it.
///
/// The build does not follow the `cmake` crate's install-prefix layout, and a
/// guessed path produces a link error far from its cause, so the library is
/// searched for.
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
/// `visit` is a trait object because a generic would instantiate the recursion
/// at `&mut F` without end.
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
