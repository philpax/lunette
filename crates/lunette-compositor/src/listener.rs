//! Linux-only: binds a Wayland listening socket under `XDG_RUNTIME_DIR`.
//!
//! The Wayland socket the application binds before the compositor thread
//! starts, and the hook through which the thread's event loop hands each
//! accepted connection to the state.
//!
//! WayVR's `create_wayland_listener` in [`crate::wayvr::client`] picks the
//! display number. lunette's event loop owns the display and the listening
//! socket, so a connection is accepted when calloop reports it rather than
//! polled on each tick. [`listen`] writes neither the environment nor
//! `wayvr.disp`; the application entry point exports the name.

use std::{error::Error, ffi::OsString, fmt, os::unix::net::UnixStream};

use smithay::{reexports::wayland_server::BindError, wayland::socket::ListeningSocketSource};
use tracing::error;

pub use crate::wayvr::WaylandEnv;
use crate::{
    spawn::DisplayEnvironment,
    thread::LoopData,
    wayvr::client::{STARTING_WAYLAND_ADDR_IDX, create_wayland_listener},
};

/// Binds the first available display socket and returns its event source and name.
///
/// The application calls this before starting the compositor thread. It exports
/// the returned name after preserving the host display name.
///
/// # Errors
///
/// Returns [`ListenError`] when every candidate socket cannot be bound.
pub fn listen() -> Result<(WaylandSocket, WaylandEnv), ListenError> {
    let (wayland_env, listener) = create_wayland_listener()?;
    Ok((WaylandSocket { source: listener }, wayland_env))
}

/// A bound listening socket source owned by the compositor thread.
///
/// The source is moved into that thread because calloop's event loop is not
/// `Send`.
pub struct WaylandSocket {
    pub(crate) source: ListeningSocketSource,
}

impl fmt::Debug for WaylandSocket {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("WaylandSocket")
            .field("name", &self.source.socket_name())
            .finish()
    }
}

/// Every candidate display socket was taken.
#[derive(Debug)]
pub struct ListenError {
    /// The final bind failure, which preserves the underlying cause for error chaining.
    pub(crate) cause: BindError,
}

impl fmt::Display for ListenError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "compositor: could not bind a wayland socket; wayland-{} through wayland-{} are all \
             taken",
            STARTING_WAYLAND_ADDR_IDX,
            STARTING_WAYLAND_ADDR_IDX + 20
        )
    }
}

impl Error for ListenError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        Some(&self.cause)
    }
}

impl WaylandEnv {
    /// Returns the display names that lunette passes to a spawned client.
    #[must_use]
    pub fn environment(self) -> DisplayEnvironment {
        DisplayEnvironment {
            wayland_display: OsString::from(self.wayland_display_num_string()),
            x11_display: OsString::from(self.display_num_string()),
        }
    }
}

#[cfg(any(test, feature = "test-fakes"))]
impl WaylandEnv {
    /// Constructs a deterministic display name without binding a socket.
    #[must_use]
    pub fn for_test(display_num: u32) -> Self {
        Self { display_num }
    }
}

/// Inserts an accepted client and attributes it to a managed or external process.
///
/// Attribution runs before the client's initial `wl_registry` dispatch. If
/// insertion fails, the stream is dropped because no protocol object exists for
/// an error response.
pub(crate) fn accept(data: &mut LoopData, stream: UnixStream) {
    if let Err(e) = data.state.accept_connection(stream) {
        error!("Failed to accept connection: {e}");
    }
}

#[cfg(test)]
mod tests {
    use std::ffi::OsStr;

    use pretty_assertions::assert_eq;

    use super::*;

    #[test]
    fn a_display_name_has_both_forms() {
        let name = WaylandEnv { display_num: 20 };

        assert_eq!(name.wayland_display_num_string(), "wayland-20");
        assert_eq!(name.display_num_string(), ":20");
        assert_eq!(name.environment().wayland_display, OsStr::new("wayland-20"));
        assert_eq!(name.environment().x11_display, OsStr::new(":20"));
    }
}
