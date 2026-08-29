//! Traits and events for the compositor's host clipboard connection.
//!
//! The application supplies the host socket before it exports lunette's own
//! `WAYLAND_DISPLAY`; this module does not read the environment. Production
//! connections run their Wayland client on a worker thread, while tests use the
//! fake implementation.

use std::{error::Error, fmt, os::fd::OwnedFd, time::Duration};

use smithay::reexports::calloop;
use tracing::debug;

use crate::selection::{HostRead, MimeType, OfferId, SelectionKind};

/// Creates a host clipboard connection from application-supplied configuration.
///
/// The binary resolves the host socket before exporting lunette's own
/// `WAYLAND_DISPLAY`; implementations do not read that variable. Failure to open
/// leaves the compositor usable without host clipboard bridging.
pub trait HostSelectionSource: fmt::Debug + Send {
    /// Opens the connection and starts any worker it requires.
    ///
    /// # Errors
    ///
    /// Returns [`HostStartError`] when connection, protocol, seat, or worker
    /// startup fails. The caller can continue without host clipboard bridging.
    fn open(self: Box<Self>, events: HostEvents) -> Result<Box<dyn HostSelection>, HostStartError>;
}

/// Accesses an opened host clipboard connection.
///
/// Production implementations send commands to a worker without waiting for the
/// host socket or the worker queue.
pub trait HostSelection: fmt::Debug + Send {
    /// Publishes `mimes` for `kind`. The host requests the bytes later through
    /// [`HostEvent::Send`].
    fn publish(&self, kind: SelectionKind, mimes: &[MimeType]);

    fn withdraw(&self, kind: SelectionKind);

    /// Queues a request for a host-owned selection.
    ///
    /// The production connection does not wait for the worker. A failed send
    /// returns [`Rejected`] with the same request and descriptor.
    fn read(&self, request: HostRead) -> Result<(), Rejected>;
}

/// A rejected read request returned with its descriptor.
#[derive(Debug)]
pub struct Rejected {
    pub request: HostRead,
    pub reason: RejectReason,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RejectReason {
    /// The bounded worker command queue is full.
    Backlogged,
    /// The worker command channel is closed.
    Disconnected,
}

impl fmt::Display for Rejected {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "selection: the host could not be asked for the ")?;
        write!(f, "{} selection: ", self.request.kind)?;
        match self.reason {
            RejectReason::Backlogged => write!(f, "its request queue is full"),
            RejectReason::Disconnected => write!(f, "the connection has ended"),
        }
    }
}

impl Error for Rejected {}

/// Events emitted by the host clipboard connection.
#[derive(Debug)]
pub enum HostEvent {
    /// The host's MIME list, in advertised order and without substitution.
    Offered {
        kind: SelectionKind,
        offer: OfferId,
        mimes: Vec<MimeType>,
    },
    Cleared {
        kind: SelectionKind,
    },
    /// The host requests bytes from a lunette-owned selection.
    ///
    /// The host supplies `pipe`; the compositor passes it to the owning lunette
    /// client, which writes the requested bytes for the host to read.
    Send {
        kind: SelectionKind,
        mime: MimeType,
        pipe: OwnedFd,
    },
    /// The host cancelled a source that lunette owns.
    Cancelled {
        kind: SelectionKind,
    },
    /// The host connection ended. No further selection events or reads cross it.
    ///
    /// The connection does not reconnect because a replacement socket may belong
    /// to a different host session.
    Lost {
        reason: String,
    },
}

/// The bounded event queue from the host worker to the compositor thread.
///
/// Accepted events remain in send order. A full queue drops the new event.
/// [`crate::thread::build`] creates and registers the receiving end before it
/// passes this sender to a host provider.
#[derive(Clone, Debug)]
pub struct HostEvents {
    pub(crate) queue: calloop::channel::SyncSender<HostEvent>,
}

impl HostEvents {
    /// Tries to report an event without waiting for the compositor thread.
    ///
    /// The worker also services the host Wayland connection, so waiting here would
    /// stop it reading that connection. Dropping a discarded [`HostEvent::Send`]
    /// closes the host-supplied descriptor, and the host observes an empty read.
    pub fn report(&self, event: HostEvent) {
        if let Err(error) = self.queue.try_send(event) {
            debug!(%error, "the compositor is behind; dropping a host selection event");
        }
    }
}

/// Why opening the host clipboard connection failed.
#[derive(Debug)]
pub enum HostStartError {
    /// The host socket could not be connected or its registry could not be set up.
    Connect {
        socket: String,
        cause: Box<dyn Error + Send + Sync>,
    },
    /// The socket accepted a connection but did not answer the startup handshake.
    ///
    /// This remains separate from [`HostStartError::Connect`] so logs distinguish
    /// an unreachable socket from an unresponsive peer.
    Unresponsive { socket: String, waited: Duration },
    /// The host implements neither `ext_data_control_v1` nor `zwlr_data_control_v1`.
    NoDataControl,
    /// The host advertises no `wl_seat` for the clipboard device.
    NoSeat,
    /// The host clipboard worker could not be started.
    Worker(Box<dyn Error + Send + Sync>),
}

impl fmt::Display for HostStartError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "selection: ")?;
        match self {
            Self::Connect { socket, cause: _ } => {
                write!(f, "could not reach the host compositor at {socket}")
            }
            Self::Unresponsive { socket, waited } => write!(
                f,
                "the socket at {socket} accepted a connection and did not answer within {waited:?}"
            ),
            Self::NoDataControl => write!(
                f,
                "the host compositor implements neither ext-data-control nor wlr-data-control, so \
                 its clipboard cannot be bridged"
            ),
            Self::NoSeat => write!(
                f,
                "the host compositor advertises no seat, so it has no selection to bridge"
            ),
            Self::Worker(_) => write!(f, "could not start the host clipboard worker"),
        }
    }
}

impl Error for HostStartError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        match self {
            Self::Connect { cause, .. } | Self::Worker(cause) => Some(cause.as_ref()),
            Self::NoDataControl | Self::NoSeat | Self::Unresponsive { .. } => None,
        }
    }
}

#[cfg(any(test, feature = "test-fakes"))]
pub use fake::{FakeHost, FakeHostSource, HostCall};

/// A host clipboard fake for tests that do not run a host desktop.
#[cfg(any(test, feature = "test-fakes"))]
#[expect(
    clippy::expect_used,
    reason = "test scaffolding: a failed expectation is how a test reports a failure, and this \
              module is gated behind `cfg(test)` or the `test-fakes` feature"
)]
mod fake {
    use std::{
        fmt,
        sync::{Arc, Mutex},
    };

    use super::{
        HostEvent, HostEvents, HostRead, HostSelection, HostSelectionSource, HostStartError,
        MimeType, RejectReason, Rejected, SelectionKind,
    };

    #[derive(Clone, Debug, PartialEq, Eq)]
    pub enum HostCall {
        Publish {
            kind: SelectionKind,
            mimes: Vec<MimeType>,
        },
        Withdraw {
            kind: SelectionKind,
        },
        /// A read; the fake retains its descriptor separately for the test.
        Read {
            kind: SelectionKind,
            mime: MimeType,
        },
    }

    #[derive(Clone, Debug, Default)]
    pub struct FakeHost {
        inner: Arc<Mutex<Inner>>,
    }

    #[derive(Debug, Default)]
    struct Inner {
        calls: Vec<HostCall>,
        pipes: Vec<std::os::fd::OwnedFd>,
        refuse: Option<RejectReason>,
        events: Option<HostEvents>,
    }

    impl FakeHost {
        /// Returns recorded calls in invocation order.
        pub fn calls(&self) -> Vec<HostCall> {
            self.lock().calls.clone()
        }

        /// Takes descriptors retained by successful reads, in call order.
        pub fn take_pipes(&self) -> Vec<std::os::fd::OwnedFd> {
            std::mem::take(&mut self.lock().pipes)
        }

        /// Causes subsequent reads to return `reason` with their descriptors.
        pub fn refuse(&self, reason: RejectReason) {
            self.lock().refuse = Some(reason);
        }

        /// Reports an event through the queue installed by [`Self::source`].
        ///
        /// # Panics
        ///
        /// Panics if the source has not been opened, so a test cannot silently
        /// discard an event without a registered receiver.
        pub fn announce(&self, event: HostEvent) {
            let events = self
                .lock()
                .events
                .clone()
                .expect("the fake host has been opened by a compositor");
            events.report(event);
        }

        pub fn source(&self) -> Box<dyn HostSelectionSource> {
            Box::new(FakeHostSource { host: self.clone() })
        }

        fn lock(&self) -> std::sync::MutexGuard<'_, Inner> {
            self.inner
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
        }
    }

    impl HostSelection for FakeHost {
        fn publish(&self, kind: SelectionKind, mimes: &[MimeType]) {
            self.lock().calls.push(HostCall::Publish {
                kind,
                mimes: mimes.to_vec(),
            });
        }

        fn withdraw(&self, kind: SelectionKind) {
            self.lock().calls.push(HostCall::Withdraw { kind });
        }

        fn read(&self, request: HostRead) -> Result<(), Rejected> {
            let mut inner = self.lock();
            if let Some(reason) = inner.refuse {
                drop(inner);
                return Err(Rejected { request, reason });
            }
            inner.calls.push(HostCall::Read {
                kind: request.kind,
                mime: request.mime.clone(),
            });
            inner.pipes.push(request.pipe);
            Ok(())
        }
    }

    #[derive(Clone, Debug)]
    pub struct FakeHostSource {
        host: FakeHost,
    }

    impl HostSelectionSource for FakeHostSource {
        fn open(
            self: Box<Self>,
            events: HostEvents,
        ) -> Result<Box<dyn HostSelection>, HostStartError> {
            self.host.lock().events = Some(events);
            Ok(Box::new(self.host))
        }
    }

    impl fmt::Display for HostCall {
        fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
            match self {
                Self::Publish { kind, mimes } => write!(f, "publish {kind} {mimes:?}"),
                Self::Withdraw { kind } => write!(f, "withdraw {kind}"),
                Self::Read { kind, mime } => write!(f, "read {kind} {mime}"),
            }
        }
    }
}
