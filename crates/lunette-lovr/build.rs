//! Linux-only: builds LÖVR as `liblovr.so` and links it dynamically.
//!
//! Three jobs, in order: configure and build LÖVR through cmake, locate the
//! shared library the build produced and emit the link directives for it, and
//! generate the FFI bindings with bindgen.
//!
//! LÖVR exports no CMake interface — every compile definition and include
//! directory on the `lovr` target is `PRIVATE` except `LOVR_OMIT_MAIN` — so the
//! bindgen pass mirrors both by hand from `vendor/lovr/CMakeLists.txt:307-336`.

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
/// `vendor/lovr/deps/joltc` reaches JoltPhysics through `FetchContent`, which
/// wants the network at configure time. Pointing
/// `FETCHCONTENT_SOURCE_DIR_JOLTPHYSICS` at a tree fetched out of band is how
/// the build stays offline.
const JOLT_SOURCE_VAR: &str = "LUNETTE_JOLTPHYSICS_SRC";

/// The LÖVR compile definitions that apply in the default configuration.
///
/// Mirrored from `vendor/lovr/CMakeLists.txt`: `LOVR_USE_GLSLANG` (`:473`),
/// `LOVR_VK` (`:477`), `LOVR_USE_GLFW` (`:574`), and `LOVR_USE_PHONON`
/// (`:391`). No `LOVR_DISABLE_*` is defined, because none is set by default.
const LOVR_DEFINES: [&str; 4] = [
    "-DLOVR_VK",
    "-DLOVR_USE_GLSLANG",
    "-DLOVR_USE_GLFW",
    "-DLOVR_USE_PHONON",
];

/// The private include directories of the `lovr` target, from
/// `vendor/lovr/CMakeLists.txt:330-336`, relative to `vendor/lovr`.
const LOVR_INCLUDE_DIRS: [&str; 4] = ["src", "src/modules", "etc", "deps/luajit/src"];

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
    // A build script is the sanctioned exception to the rule that a library
    // never reads the environment: Cargo hands it OUT_DIR, CARGO_MANIFEST_DIR,
    // and the rest through no other channel, and the devshell supplies the
    // JoltPhysics tree the same way.
    let manifest_dir = PathBuf::from(required_var("CARGO_MANIFEST_DIR")?);
    let out_dir = PathBuf::from(required_var("OUT_DIR")?);
    let jolt_source = required_var(JOLT_SOURCE_VAR)?;
    let lovr_dir = canonicalize(&manifest_dir.join("../../vendor/lovr"))?;

    println!("cargo::rerun-if-env-changed={JOLT_SOURCE_VAR}");
    watch_lovr_sources(&lovr_dir)?;

    let cmake_out = build_lovr(&lovr_dir, &jolt_source);
    let lovr_build = find_lovr_build(&cmake_out)?;
    emit_link_directives(&lovr_build);
    stage_boot_lua(&lovr_dir, &out_dir)?;
    generate_bindings(&manifest_dir, &lovr_dir, &out_dir)
}

/// Declares the LÖVR files whose contents govern the cmake build.
///
/// Cargo watches only the package directory, and `vendor/lovr` sits two
/// directories above it, so without these lines a patch to LÖVR leaves this
/// script Fresh and the stale `liblovr.so` is linked.
///
/// The files are named one by one rather than by handing Cargo the `src`
/// directory, because cmake writes generated headers back into the source tree
/// — `src/api/l_math.lua.h` and the shader headers under `etc/shaders`, both
/// covered by LÖVR's own `.gitignore:2` pattern `*.*.h`. Watching the directory
/// therefore sees a newer mtime after every build and rebuilds for ever.
/// Excluding that pattern is what breaks the cycle, and Cargo has no way to
/// express an exclusion against a directory entry.
///
/// A source file added to LÖVR is not itself watched until the next rerun, but
/// `LOVR_SRC` in `CMakeLists.txt:255-304` lists every source explicitly, so
/// adding one edits a watched file.
///
/// `deps/` is deliberately absent. It is a tree of submodules whose recursive
/// walk costs far more than it returns, and a submodule bump shows up as a
/// change to `CMakeLists.txt` or to the gitlink rather than to a file under
/// `src/`.
fn watch_lovr_sources(lovr_dir: &Path) -> Result<(), BuildError> {
    println!(
        "cargo::rerun-if-changed={}",
        lovr_dir.join("CMakeLists.txt").display()
    );

    walk_files(&lovr_dir.join("src"), &mut |path| {
        if !is_generated_header(path) {
            println!("cargo::rerun-if-changed={}", path.display());
        }
    })
}

/// Whether a path matches the `*.*.h` pattern cmake generates headers under.
///
/// The generated names carry the source extension before `.h` — `l_math.lua.h`
/// from `l_math.lua`, `fill.frag.h` from `fill.frag` — so a hand-written `.h`
/// never matches unless its stem contains a dot, which none in LÖVR does.
fn is_generated_header(path: &Path) -> bool {
    path.extension().is_some_and(|extension| extension == "h")
        && Path::new(path.file_stem().unwrap_or_default())
            .extension()
            .is_some()
}

/// Configures and builds LÖVR, returning the cmake output directory.
///
/// The `all` target rather than `install`: LÖVR's dependencies carry install
/// rules that do not hold in this configuration — phonon's expects a split
/// `.dbg` file that a shared build does not produce — which is why the nixpkgs
/// derivation sets `dontUseCmakeInstall`.
fn build_lovr(lovr_dir: &Path, jolt_source: &OsString) -> PathBuf {
    let configure = || {
        let mut config = cmake::Config::new(lovr_dir);
        config
            .define("LOVR_BUILD_SHARED", "ON")
            .define("LOVR_BUILD_WITH_SYMBOLS", "ON")
            .define("FETCHCONTENT_SOURCE_DIR_JOLTPHYSICS", jolt_source)
            // `vendor/lovr/CMakeLists.txt:908-909` gives `liblovr.so` an rpath
            // of `$ORIGIN`, which is right for the packaged layout where every
            // library sits in one directory. In the build tree the `move_files`
            // target (`:912-938`) stages the siblings one level down in `bin/`,
            // so `$ORIGIN/bin` has to be on the rpath as well. It cannot be
            // supplied from the executable's own link line: a `DT_RUNPATH` is
            // not consulted when resolving a dependency's dependencies.
            //
            // The backslash survives into cmake's generated link script, where
            // the shell strips it and hands the linker a literal `$ORIGIN`.
            .define("CMAKE_SHARED_LINKER_FLAGS", "-Wl,-rpath,\\$ORIGIN/bin");
        config
    };

    let cmake_out = configure().build_target("all").build();

    // `move_files` is what populates the staged `bin/` tree, and it is an `ALL`
    // custom target with no declared dependency on the libraries it copies
    // (`vendor/lovr/CMakeLists.txt:682`), so a parallel build is free to run it
    // before they exist. Building it once more, after everything else, makes the
    // staged tree deterministic: a custom target is always out of date, so its
    // copies run again.
    configure().build_target("move_files").build();

    cmake_out
}

/// Emits the search paths, the libraries, and the rpath entries LÖVR needs.
///
/// LuaJIT is a separate shared library (`vendor/lovr/CMakeLists.txt:151`), and
/// the Lua C API symbols mlua declares need a link-time provider, so it is named
/// alongside LÖVR itself. Its `SONAME` is plain `libluajit.so`, not the
/// versioned `libluajit-5.1.so` a distribution package would carry.
fn emit_link_directives(build: &LovrBuild) {
    let library_dir = build.library_dir.display();
    let staged_dir = build.staged_dir.display();

    println!("cargo::rustc-link-search=native={library_dir}");
    println!("cargo::rustc-link-search=native={staged_dir}");
    println!("cargo::rustc-link-lib=dylib=lovr");
    println!("cargo::rustc-link-lib=dylib=luajit");

    // `rustc-link-arg` rather than `rustc-link-arg-bins`, so test binaries under
    // `target/debug/deps/` resolve the library too. Cargo passes the string to
    // `rustc -C link-arg` with no shell involved, so the literal `$ORIGIN`
    // reaches the dynamic linker intact.
    //
    // These apply to this package's own targets and no further, which is why the
    // directories are also published below. A dependent that links an executable
    // has to emit its own rpath entries from them.
    println!("cargo::rustc-link-arg=-Wl,-rpath,{library_dir}");
    println!("cargo::rustc-link-arg=-Wl,-rpath,{staged_dir}");
    println!("cargo::rustc-link-arg=-Wl,-rpath,$ORIGIN");

    println!("cargo::metadata=library_dir={library_dir}");
    println!("cargo::metadata=staged_dir={staged_dir}");
}

/// Copies `etc/boot.lua` into `OUT_DIR` for the crate to embed.
///
/// CMake hex-dumps the same file into a generated `etc/boot.lua.h`
/// (`vendor/lovr/CMakeLists.txt:647-663`), but it writes that header into the
/// source tree rather than the build directory, so generating it dirties the
/// submodule. The bytes are identical either way.
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

    let includes = LOVR_INCLUDE_DIRS
        .iter()
        .map(|relative| format!("-I{}", lovr_dir.join(relative).display()));

    let bindings = bindgen::Builder::default()
        .header(wrapper.to_string_lossy())
        // The `lovr` target sets `C_STANDARD 11`
        // (`vendor/lovr/CMakeLists.txt:328`); bindgen parses the same dialect
        // rather than whatever clang defaults to for a bare `.h`.
        .clang_args(["-x", "c", "-std=c11"])
        // The devshell hands bindgen a complete clang search path through
        // BINDGEN_EXTRA_CLANG_ARGS. Letting bindgen probe the `clang` on PATH
        // as well lists clang's builtin include directory a second time under a
        // different path, and `#include_next <stdatomic.h>` inside clang's own
        // `<stdatomic.h>` then re-enters that header, whose include guard is
        // already set — so it expands to nothing and `atomic_uint` in
        // `vendor/lovr/src/util.h:42` becomes an unknown type.
        .detect_include_paths(false)
        .clang_args(includes)
        .clang_args(LOVR_DEFINES)
        .allowlist_function("luax_.*")
        // How a LOVR object becomes a Lua userdata with LOVR's own metatable.
        // The leading underscore is why it needs naming separately: the macro
        // callers write is `luax_pushtype`, which resolves the `ObjectType` and
        // calls this. It retains the object itself (`api/api.c:262`), so a
        // caller pushing a texture it holds a reference to hands over nothing.
        .allowlist_function("_luax_pushtype")
        .allowlist_function("os_init")
        .allowlist_function("os_destroy")
        // The step loop calls this once per frame; see `main.c:66`.
        .allowlist_function("os_sleep")
        .allowlist_function("lovrSetLogCallback")
        // Reference counting. Every LOVR object is owned through these, and
        // calling a `lovr*Destroy` directly would bypass the count rather than
        // decrement it; `lovr*Destroy` is the destructor `lovrRelease` calls.
        .allowlist_function("lovrRetain")
        .allowlist_function("lovrRelease")
        // The texture surface the import path is written against.
        .allowlist_function("lovrGraphicsIsInitialized")
        .allowlist_function("lovrGraphicsGetFeatures")
        .allowlist_function("lovrTextureCreate")
        .allowlist_function("lovrTextureDestroy")
        .allowlist_function("lovrTextureGetInfo")
        .allowlist_function("lovrTextureSetPixels")
        .allowlist_function("lovrTextureImportAcquire")
        .allowlist_function("lovrTextureImportRelease")
        .allowlist_function("lovrImageCreateRaw")
        .allowlist_function("lovrImageDestroy")
        .allowlist_function("lovrImageGetLayerData")
        // How a `lun*` event reaches `lovr.handlers`. `CustomEvent`, `Event`,
        // and `EventType` arrive with it, because they are the signature.
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
    /// The directory holding `liblovr.so` itself.
    library_dir: PathBuf,
    /// The `bin/` tree LÖVR copies its shared dependencies into, LuaJIT among
    /// them.
    staged_dir: PathBuf,
}

/// Locates `liblovr.so` and the staged runtime tree beside it.
///
/// The install-prefix layout the `cmake` crate assumes does not describe where
/// these land: LÖVR copies its shared dependencies into `${CMAKE_BINARY_DIR}/bin`
/// with the `move_files` target (`vendor/lovr/CMakeLists.txt:912-938`), while
/// `liblovr.so` stays at the binary directory's root, because
/// `RUNTIME_OUTPUT_DIRECTORY` (`:907`) does not govern a Linux shared library.
/// Searching for the library is the honest way to find it; guessing a path
/// produces a link error far from its cause.
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
    let luajit = staged_dir.join("libluajit.so");
    if !luajit.is_file() {
        return Err(BuildError::MissingStagedLibrary { expected: luajit });
    }

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
/// `visit` is a trait object rather than a generic, because the recursive call
/// would otherwise instantiate the function at `&mut F` at each level and never
/// terminate.
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
    MissingStagedLibrary {
        expected: PathBuf,
    },
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
            Self::MissingVariable(name) if *name == JOLT_SOURCE_VAR => write!(
                f,
                "{name} is unset. It names a prefetched JoltPhysics source tree, and the Nix \
                 devshell is what provides it — build from inside `nix develop`, or set it to a \
                 checkout of the revision `vendor/lovr/deps/joltc/CMakeLists.txt` declares"
            ),
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
            Self::MissingStagedLibrary { expected } => write!(
                f,
                "expected LÖVR's staged runtime tree to hold {}; the move_files target at \
                 vendor/lovr/CMakeLists.txt:912-938 is what populates it",
                expected.display()
            ),
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
            Self::MissingVariable(_)
            | Self::LocateLibrary { .. }
            | Self::LibraryAtRoot
            | Self::MissingStagedLibrary { .. } => None,
        }
    }
}
