//! Linux-only: binding the control socket, and the directory that secures it.
//!
//! The socket evaluates arbitrary Lua in the user's session. Reaching it is
//! equivalent to reaching everything the user can reach
//! ([the Lua API](../../../docs/lua-api.md#lunctl)). Filesystem permissions
//! are the whole of the boundary. There is no authentication behind them.
//!
//! # Private directory for the socket
//!
//! `UnixListener::bind` creates the inode with `0777 & ~umask` and has no
//! pre-creation hook. Three ways to narrow a listener's mode after the bind
//! fail:
//!
//! - `fchmod` on the listener fd changes nothing on Linux. The descriptor
//!   refers to the socket object, not to the filesystem inode. The call
//!   succeeds without effect.
//! - Binding and then `set_permissions` leaves a window in which the socket
//!   is world-accessible. A connection accepted in that window stays valid
//!   after the mode is corrected.
//! - `umask` is process-global and not thread-safe. Another thread creating
//!   a file concurrently would get the wrong mode.
//!
//! The bind creates a private directory at 0700 and binds the socket inside
//! it. No other uid can traverse the directory regardless of the socket's
//! own mode. The socket is then set 0600 as well. The directory mode is the
//! boundary; the socket mode is a second layer of it.
//!
//! The documented path is `$XDG_RUNTIME_DIR/lunette/lunette-0.sock`. The
//! socket is bound inside the private directory, not directly in the runtime
//! directory.
//!
//! # Never a network address
//!
//! [`ControlSocket`] holds a [`UnixListener`]. The module accepts no host
//! or port. No configuration makes the socket listen on a network address.

use std::{
    error::Error,
    fmt, fs, io,
    os::unix::{
        fs::{DirBuilderExt, MetadataExt, PermissionsExt},
        net::{UnixListener, UnixStream},
    },
    path::{Path, PathBuf},
};

use tracing::{debug, info};

/// The directory the socket is bound inside, relative to `$XDG_RUNTIME_DIR`.
pub const DIRECTORY_NAME: &str = "lunette";

/// The socket's own name, inside [`DIRECTORY_NAME`].
///
/// One per user session. A second lunette on the same runtime directory is
/// refused, not given a second number. Two sessions competing for one headset
/// is not a configuration worth supporting, and a `lunctl` that reaches the
/// wrong session is worse than one that cannot start.
pub const SOCKET_NAME: &str = "lunette-0.sock";

/// The mode the private directory is created with, and required to have.
const DIRECTORY_MODE: u32 = 0o700;

/// The mode the socket is set to once it is bound.
const SOCKET_MODE: u32 = 0o600;

/// The permission bits that must be clear on every directory in the socket's path.
const OTHERS: u32 = 0o077;

/// A bound control socket, and the path it unlinks on drop.
#[derive(Debug)]
pub struct ControlSocket {
    listener: UnixListener,
    path: PathBuf,
}

impl ControlSocket {
    /// Creates the private directory under `runtime_directory` and binds the
    /// socket inside it.
    ///
    /// The entry point resolves `runtime_directory` from `$XDG_RUNTIME_DIR`.
    /// `CONTRIBUTING.md` confines environment reads to the entry point, and
    /// the validation functions take a path, not an environment variable.
    ///
    /// # Errors
    ///
    /// If the runtime directory is missing, is not the caller's, or is readable
    /// by anyone else; if the private directory cannot be created or secured; if
    /// another lunette is already listening; or if the bind itself fails.
    pub fn bind(runtime_directory: &Path) -> Result<Self, BindError> {
        // The XDG specification mandates 0700 and user ownership, but a
        // specification is not enforcement. A runtime directory anyone can
        // traverse exposes everything inside it, so the call verifies both
        // conditions.
        private_directory(runtime_directory, Created::No)?;

        let directory = runtime_directory.join(DIRECTORY_NAME);
        match fs::DirBuilder::new()
            .mode(DIRECTORY_MODE)
            .create(&directory)
        {
            Ok(()) => {}
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {}
            Err(error) => {
                return Err(BindError::Directory {
                    path: directory,
                    cause: error,
                });
            }
        }
        private_directory(&directory, Created::Yes)?;

        let path = directory.join(SOCKET_NAME);
        clear_stale(&path)?;

        let listener = UnixListener::bind(&path).map_err(|cause| BindError::Bind {
            path: path.clone(),
            cause,
        })?;

        // For a socket, the descriptor refers to the socket object, not to
        // the inode, so `fchmod` on it succeeds and changes nothing. The call
        // sets the mode by path. The directory mode keeps the socket
        // unreachable until the call narrows it.
        fs::set_permissions(&path, fs::Permissions::from_mode(SOCKET_MODE)).map_err(|cause| {
            BindError::Mode {
                path: path.clone(),
                cause,
            }
        })?;

        info!(path = %path.display(), "listening for lunctl");
        Ok(Self { listener, path })
    }

    /// The path a client connects to.
    #[must_use]
    pub fn path(&self) -> &Path {
        &self.path
    }

    #[must_use]
    pub(crate) fn listener(&self) -> &UnixListener {
        &self.listener
    }
}

impl Drop for ControlSocket {
    /// Unlinks the socket, so the next bind finds no file at the path.
    ///
    /// Best-effort. A session that exits without the unlink leaves the file
    /// behind; [`clear_stale`] removes it on the next bind.
    fn drop(&mut self) {
        if let Err(error) = fs::remove_file(&self.path) {
            debug!(path = %self.path.display(), %error, "the control socket could not be unlinked");
        }
    }
}

/// Why no control socket could be bound.
#[derive(Debug)]
pub enum BindError {
    /// A directory the socket depends on is missing or unreadable.
    Missing { path: PathBuf, cause: io::Error },
    /// A directory the socket depends on is not the caller's.
    NotOurs { path: PathBuf, owner: u32, us: u32 },
    /// A directory the socket depends on can be reached by another user.
    Exposed { path: PathBuf, mode: u32 },
    /// The private directory could not be created.
    Directory { path: PathBuf, cause: io::Error },
    /// Something is already listening on the socket.
    AlreadyRunning { path: PathBuf },
    /// A stale socket could not be removed.
    Stale { path: PathBuf, cause: io::Error },
    /// The bind failed.
    Bind { path: PathBuf, cause: io::Error },
    /// The socket could not be narrowed to 0600.
    Mode { path: PathBuf, cause: io::Error },
}

impl fmt::Display for BindError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("lunctl: ")?;
        match self {
            Self::Missing { path, cause } => write!(
                formatter,
                "{} could not be read, so there is nowhere private to put the control socket: \
                 {cause}",
                path.display()
            ),
            Self::NotOurs { path, owner, us } => write!(
                formatter,
                "{} belongs to uid {owner} and this session is uid {us}, so a socket inside it \
                 would not be under this user's control",
                path.display()
            ),
            Self::Exposed { path, mode } => write!(
                formatter,
                "{} is mode {mode:04o}, which lets another user reach into it; the control socket \
                 evaluates lua and needs a directory only this user can traverse",
                path.display()
            ),
            Self::Directory { path, cause } => write!(
                formatter,
                "{} could not be created: {cause}",
                path.display()
            ),
            Self::AlreadyRunning { path } => write!(
                formatter,
                "something is already listening on {}, so this session would have to steal the \
                 path from it",
                path.display()
            ),
            Self::Stale { path, cause } => write!(
                formatter,
                "{} is left over from an earlier session and could not be removed: {cause}",
                path.display()
            ),
            Self::Bind { path, cause } => {
                write!(formatter, "{} could not be bound: {cause}", path.display())
            }
            Self::Mode { path, cause } => write!(
                formatter,
                "{} could not be set to {SOCKET_MODE:04o}: {cause}",
                path.display()
            ),
        }
    }
}

impl Error for BindError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        match self {
            Self::Missing { cause, .. }
            | Self::Directory { cause, .. }
            | Self::Stale { cause, .. }
            | Self::Bind { cause, .. }
            | Self::Mode { cause, .. } => Some(cause),
            Self::NotOurs { .. } | Self::Exposed { .. } | Self::AlreadyRunning { .. } => None,
        }
    }
}

/// Whether this bind created the directory being checked. How a wrong
/// mode is handled depends on it: a created directory is narrowed back
/// to 0700; an existing one is reported. A `umask` outside the process's
/// control can make a created directory's mode wrong. Changing the mode
/// of `$XDG_RUNTIME_DIR` would alter part of the user's session that
/// this process does not own.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Created {
    Yes,
    No,
}

/// Refuses a directory another user could reach into.
fn private_directory(path: &Path, created: Created) -> Result<(), BindError> {
    let metadata = fs::metadata(path).map_err(|cause| BindError::Missing {
        path: path.to_owned(),
        cause,
    })?;

    // SAFETY: `geteuid` reads the calling process's effective uid and cannot
    // fail. It takes no arguments and touches nothing.
    let us = unsafe { libc::geteuid() };
    if metadata.uid() != us {
        return Err(BindError::NotOurs {
            path: path.to_owned(),
            owner: metadata.uid(),
            us,
        });
    }

    let mode = metadata.permissions().mode() & 0o7777;
    if mode & OTHERS == 0 {
        return Ok(());
    }

    if created == Created::No {
        return Err(BindError::Exposed {
            path: path.to_owned(),
            mode,
        });
    }

    // `DirBuilder::mode` is masked by `umask`, so a permissive umask can
    // produce a directory wider than the mode the process requested.
    // Narrowing the mode is safe for a directory this process created;
    // such a directory holds nothing but the socket.
    fs::set_permissions(path, fs::Permissions::from_mode(DIRECTORY_MODE)).map_err(|cause| {
        BindError::Mode {
            path: path.to_owned(),
            cause,
        }
    })
}

/// Removes a socket left behind by a crashed session, and nothing else.
///
/// Unlinking unconditionally would let a second instance take a running
/// instance's path. `lunctl` would then talk to the wrong session. No
/// visible failure appears until an assertion fails elsewhere.
/// The check is a connection attempt. A refusal means nothing is accepting
/// connections on the path, and the file is stale.
fn clear_stale(path: &Path) -> Result<(), BindError> {
    if !path.exists() {
        return Ok(());
    }

    match UnixStream::connect(path) {
        Ok(_) => Err(BindError::AlreadyRunning {
            path: path.to_owned(),
        }),
        Err(error)
            if matches!(
                error.kind(),
                io::ErrorKind::ConnectionRefused | io::ErrorKind::NotFound
            ) =>
        {
            debug!(path = %path.display(), "replacing a control socket nothing is listening on");
            fs::remove_file(path).map_err(|cause| BindError::Stale {
                path: path.to_owned(),
                cause,
            })
        }
        Err(cause) => Err(BindError::Stale {
            path: path.to_owned(),
            cause,
        }),
    }
}

#[cfg(test)]
#[expect(
    clippy::expect_used,
    reason = "a failed expectation is how a test reports a failure; the ban is on production code"
)]
mod tests {
    use tempfile::TempDir;

    use super::*;

    /// A runtime directory of the shape the XDG specification requires.
    ///
    /// Binding a real socket is the narrow exception `CONTRIBUTING.md` records
    /// for the compositor's listener, and it applies for the same reason: mode
    /// and path selection of a listener cannot be exercised over a
    /// `UnixStream::pair`. Every bind is inside a per-test temporary directory.
    fn runtime() -> TempDir {
        let directory = TempDir::new().expect("a temporary directory can be created");
        fs::set_permissions(directory.path(), fs::Permissions::from_mode(0o700))
            .expect("the mode can be set");
        directory
    }

    fn mode_of(path: &Path) -> u32 {
        fs::metadata(path).expect("it exists").permissions().mode() & 0o7777
    }

    #[test]
    fn the_directory_is_0700_and_the_socket_is_0600() {
        // The directory mode enforces the security property; the socket
        // mode is a second layer.
        let runtime = runtime();

        let socket = ControlSocket::bind(runtime.path()).expect("it binds");

        assert_eq!(mode_of(&runtime.path().join(DIRECTORY_NAME)), 0o700);
        assert_eq!(mode_of(socket.path()), 0o600);
    }

    #[test]
    fn the_socket_lives_inside_the_private_directory() {
        let runtime = runtime();

        let socket = ControlSocket::bind(runtime.path()).expect("it binds");

        assert_eq!(
            socket.path(),
            runtime.path().join(DIRECTORY_NAME).join(SOCKET_NAME),
        );
    }

    /// The type is the guarantee: no host and no port. The test asserts that
    /// the bound listener has a filesystem path.
    #[test]
    fn the_listener_is_on_a_path_and_not_on_an_address() {
        let runtime = runtime();

        let socket = ControlSocket::bind(runtime.path()).expect("it binds");

        let address = socket.listener().local_addr().expect("it has an address");
        assert_eq!(address.as_pathname(), Some(socket.path()));
    }

    #[test]
    fn a_runtime_directory_another_user_can_reach_is_refused() {
        let runtime = runtime();
        fs::set_permissions(runtime.path(), fs::Permissions::from_mode(0o755))
            .expect("the mode can be set");

        let error = ControlSocket::bind(runtime.path()).expect_err("it is world-readable");

        assert!(matches!(error, BindError::Exposed { .. }), "{error}");
    }

    #[test]
    fn a_private_directory_left_too_wide_is_narrowed_rather_than_refused() {
        // A permissive umask produces such a directory. It is this process's
        // own directory and holds nothing but the socket.
        let runtime = runtime();
        let directory = runtime.path().join(DIRECTORY_NAME);
        fs::create_dir(&directory).expect("it can be created");
        fs::set_permissions(&directory, fs::Permissions::from_mode(0o755))
            .expect("the mode can be set");

        let socket = ControlSocket::bind(runtime.path()).expect("it binds");

        assert_eq!(mode_of(&directory), 0o700);
        assert_eq!(mode_of(socket.path()), 0o600);
    }

    #[test]
    fn a_missing_runtime_directory_is_reported() {
        let runtime = runtime();

        let error = ControlSocket::bind(&runtime.path().join("absent"))
            .expect_err("there is no such directory");

        assert!(matches!(error, BindError::Missing { .. }), "{error}");
    }

    #[test]
    fn binding_twice_reports_rather_than_stealing_the_path() {
        let runtime = runtime();
        let first = ControlSocket::bind(runtime.path()).expect("the first binds");

        let error = ControlSocket::bind(runtime.path()).expect_err("the second does not");

        assert!(matches!(error, BindError::AlreadyRunning { .. }), "{error}");
        assert!(
            first.path().exists(),
            "the running session keeps its socket"
        );
    }

    #[test]
    fn a_socket_with_no_listener_behind_it_is_replaced() {
        let runtime = runtime();
        let path = {
            let socket = ControlSocket::bind(runtime.path()).expect("it binds");
            let path = socket.path().to_owned();
            // The control socket's drop unlinks the file, then a bare
            // listener recreates it. A session that exits without the
            // unlink leaves the same shape.
            drop(socket);
            UnixListener::bind(&path).expect("a bare socket can be made");
            path
        };
        // The dropped listener has closed without unlinking, so the path still
        // exists and no process accepts connections on it.
        assert!(path.exists());

        let socket = ControlSocket::bind(runtime.path()).expect("the stale socket is replaced");

        assert_eq!(socket.path(), path);
    }

    #[test]
    fn a_plain_file_where_the_socket_goes_is_removed() {
        // Not a socket. `connect` reports that as a refusal, not as a live
        // listener.
        let runtime = runtime();
        let directory = runtime.path().join(DIRECTORY_NAME);
        fs::create_dir(&directory).expect("it can be created");
        fs::write(directory.join(SOCKET_NAME), b"not a socket").expect("it can be written");

        let socket = ControlSocket::bind(runtime.path()).expect("it binds");

        assert_eq!(mode_of(socket.path()), 0o600);
    }

    #[test]
    fn the_socket_is_unlinked_when_the_session_lets_go_of_it() {
        let runtime = runtime();
        let path = {
            let socket = ControlSocket::bind(runtime.path()).expect("it binds");
            socket.path().to_owned()
        };

        assert!(!path.exists());
    }

    #[test]
    fn an_error_names_its_subsystem() {
        let error = BindError::AlreadyRunning {
            path: PathBuf::from("/run/user/1000/lunette/lunette-0.sock"),
        };
        assert!(error.to_string().starts_with("lunctl: "), "{error}");
    }
}
