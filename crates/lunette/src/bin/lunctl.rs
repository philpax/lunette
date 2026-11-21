//! Sends commands to Lunette's control socket.

#[cfg(any(target_os = "linux", windows))]
#[path = "lunctl/client.rs"]
mod client;

#[cfg(any(target_os = "linux", windows))]
fn main() -> std::process::ExitCode {
    client::run()
}
