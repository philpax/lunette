//! Boots the Lunette desktop.

mod boot;
mod check;
mod cli;
#[cfg(target_os = "linux")]
mod runtime_manifest;

#[cfg(test)]
mod log_capture;

#[cfg(target_os = "linux")]
mod linux_main;
#[cfg(target_os = "linux")]
pub(crate) use linux_main::PREFIX;
#[cfg(windows)]
mod windows_main;

fn main() -> std::process::ExitCode {
    #[cfg(target_os = "linux")]
    return linux_main::run();
    #[cfg(windows)]
    return windows_main::run();
}
