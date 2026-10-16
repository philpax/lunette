//! Linux-only: renders offscreen fixtures through real LÖVR and software Vulkan.
//! All GPU work belongs to one trial because LÖVR's modules are process-global.

mod owner;
#[path = "../lua/run.rs"]
mod run;
// The shared module also constructs logic-only states; graphics owns its interpreter instead.
#[expect(dead_code, reason = "state::new is for the ordinary Lua runner")]
#[path = "../lua/state.rs"]
mod state;

use std::{env, fs, path::Path, process::ExitCode};

use libtest_mimic::{Arguments, Failed, Trial};
use lunette_lovr::raw;

use crate::{owner::Owner, state::Roots};

fn main() -> ExitCode {
    let arguments = Arguments::from_args();
    let roots = Roots::of_repository(
        Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../..")
            .canonicalize()
            .unwrap_or_else(|_| Path::new(env!("CARGO_MANIFEST_DIR")).join("../..")),
    );
    let driver = env::var_os("VK_DRIVER_FILES")
        .or_else(|| env::var_os("VK_ICD_FILENAMES"))
        .ok_or_else(|| {
            "graphics: set VK_DRIVER_FILES to Mesa's lvp ICD JSON; no driver is selected".to_owned()
        })
        .and_then(|paths| {
            for path in env::split_paths(&paths) {
                let source = fs::read_to_string(&path)
                    .map_err(|error| format!("graphics: ICD {}: {error}", path.display()))?;
                if !source.contains("libvulkan_lvp") {
                    return Err(format!(
                        "graphics: ICD {} is not the Mesa lavapipe software driver",
                        path.display()
                    ));
                }
            }
            if paths.is_empty() {
                return Err("graphics: the software ICD selection is empty".to_owned());
            }
            Ok(())
        });
    libtest_mimic::run(
        &arguments,
        vec![Trial::test("graphics", move || {
            driver?;
            serial_fixtures(&roots).map_err(Failed::from)
        })],
    )
    .exit_code()
}

fn serial_fixtures(roots: &Roots) -> Result<(), String> {
    graphics_initialization_has_no_xr_or_window(roots)?;
    graphics_harness_failure_propagation(roots)?;
    fixture(roots, "pixels")?;
    for module in [
        "aurora-baseline",
        "aurora-bands",
        "aurora-transparency",
        "aurora-reload",
        "shader-specialization",
        "ui-host",
        "ui-gallery",
    ] {
        fixture(roots, module)?;
    }
    Ok(())
}

fn fixture(roots: &Roots, module: &str) -> Result<(), String> {
    let owner = Owner::new()?;
    let outcome = owner
        .configure(roots)
        .and_then(|()| owner.initialize())
        .map_err(|error| format!("graphics: initializing {module}: {error}"))
        .and_then(|()| run::module(owner.lua(), module));
    owner.finish(outcome)
}

fn graphics_initialization_has_no_xr_or_window(roots: &Roots) -> Result<(), String> {
    let owner = Owner::new()?;
    let outcome = owner
        .configure(roots)
        .and_then(|()| owner.initialize())
        .and_then(|()| {
            owner
                .lua()
                .load(
                    "assert(lovr.graphics.isInitialized(), 'graphics is not initialized') \
                 assert(lovr.audio == nil and lovr.headset == nil and lovr.filesystem == nil \
                 and lovr.system == nil, 'a host-device module is loaded') \
                 assert(package.loaded['lovr.headset'] == nil, 'headset is cached') \
                 local device = lovr.graphics.getDevice() \
                 assert(device.name:lower():find('llvmpipe'), 'the GPU is not lavapipe')",
                )
                .exec()
        })
        .map_err(|error| format!("graphics_initialization_has_no_xr_or_window: {error}"))
        .and_then(|()| {
            // SAFETY: the platform is initialized. LÖVR's session generation
            // accessor returns zero until an XR session has been created.
            if unsafe { raw::os_window_is_open() } {
                Err("graphics_initialization_has_no_xr_or_window: a window is open".to_owned())
            } else if unsafe { raw::lovrHeadsetGetSessionGeneration() } != 0 {
                Err("graphics_initialization_has_no_xr_or_window: an XR session exists".to_owned())
            } else {
                Ok(())
            }
        });
    owner.finish(outcome)
}

fn graphics_harness_failure_propagation(roots: &Roots) -> Result<(), String> {
    // A setup error before graphics initialization must close the math finalizer too.
    let owner = Owner::new()?;
    let partial = owner
        .configure(roots)
        .and_then(|()| owner.lua().load("error('partial setup failure')").exec())
        .map_err(|error| error.to_string());
    require_failure(owner.finish(partial), "partial setup failure")?;
    fixture(roots, "pixels")?;

    for (module, marker) in [
        ("failure-assertion", "deliberate pixel assertion failure"),
        ("failure-shader", "deliberate_invalid_shader"),
        ("failure-load", "deliberate module load failure"),
    ] {
        require_failure(fixture(roots, module), marker)?;
        // A fresh state must compile, submit, and read pixels after every failure.
        fixture(roots, "pixels")?;
    }
    Ok(())
}

fn require_failure(result: Result<(), String>, marker: &str) -> Result<(), String> {
    match result {
        Err(error) if error.contains(marker) && !error.contains("graphics: closing the state:") => {
            Ok(())
        }
        Err(error) => Err(format!(
            "graphics_harness_failure_propagation: missing '{marker}' in {error}"
        )),
        Ok(()) => Err(format!(
            "graphics_harness_failure_propagation: '{marker}' incorrectly passed"
        )),
    }
}
