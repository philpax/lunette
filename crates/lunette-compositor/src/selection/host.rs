//! The seam between the compositor and the host desktop's clipboard.
//!
//! Two objects cross it. [`HostSelection`] is what the compositor thread calls:
//! publish what a lunette client copied, withdraw it, and ask the host to fill a
//! descriptor with what the host copied. [`HostEvents`] is what comes back: the
//! host announced a selection, cleared one, or wants the bytes behind lunette's.
//!
//! Both halves are traits rather than a concrete connection, because the
//! compositor's tests must run with no host desktop at all — this machine and
//! CI both have none — and because the production implementation owns a Wayland
//! connection on a worker thread, which no test should have to stand up.
//! [`crate::selection::DataControlSource`] is the production one.
//!
//! # Nothing here blocks
//!
//! Every method is a message onto a bounded queue, and every reply arrives as an
//! event on the compositor's own event loop. A full queue is reported rather
//! than waited on: the compositor thread is also the thread that dispatches
//! Wayland clients, so a call here that waited would stall every window in the
//! session behind a clipboard.
//!
//! # Descriptors
//!
//! A [`HostRead`] owns the descriptor it carries. When it cannot be delivered it
//! comes back inside [`Rejected`], so there is one named owner at every moment:
//! either the host connection has it, or the caller does, and closing it is a
//! deliberate act rather than something that happens because an error was
//! returned.

use std::{error::Error, fmt, os::fd::OwnedFd};

use smithay::reexports::calloop;
use tracing::debug;

use crate::selection::{HostRead, MimeType, OfferId, SelectionKind};

/// How a host desktop's clipboard is reached, before it is reached.
///
/// Separate from [`HostSelection`] because opening the connection is what fails,
/// and it fails on the compositor thread rather than in the caller that named
/// the socket. The binary constructs one of these from the host socket it read
/// before it exported its own `WAYLAND_DISPLAY`; a library never reads that
/// variable itself.
pub trait HostSelectionSource: fmt::Debug + Send {
    /// Connects, and starts whatever thread the connection needs.
    ///
    /// # Errors
    ///
    /// [`HostStartError`] when the host cannot be reached or does not implement
    /// either data-control protocol. Neither is a session-ending fault: lunette
    /// runs perfectly well with a clipboard that does not leave it.
    fn open(self: Box<Self>, events: HostEvents) -> Result<Box<dyn HostSelection>, HostStartError>;
}

/// A live connection to the host desktop's clipboard.
pub trait HostSelection: fmt::Debug + Send {
    /// Tells the host that lunette owns the selection, and what it offers.
    ///
    /// The host asks for the bytes later, through [`HostEvent::Send`].
    fn publish(&self, kind: SelectionKind, mimes: &[MimeType]);

    /// Gives up lunette's ownership of a selection.
    fn withdraw(&self, kind: SelectionKind);

    /// Asks the host to write its selection into the descriptor.
    ///
    /// # Errors
    ///
    /// [`Rejected`], carrying the request back with its descriptor, when the
    /// queue is full or the connection has ended.
    fn read(&self, request: HostRead) -> Result<(), Rejected>;
}

/// A request the host connection could not take, returned with its descriptor.
#[derive(Debug)]
pub struct Rejected {
    pub request: HostRead,
    pub reason: RejectReason,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RejectReason {
    /// The host worker is behind. The request is dropped rather than queued
    /// without bound; a clipboard that lags is better than one that grows.
    Backlogged,
    /// The worker thread has stopped, which the host session ending looks like.
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

/// What the host desktop's clipboard reports back.
#[derive(Debug)]
pub enum HostEvent {
    /// The host has a selection, offering these MIME types.
    ///
    /// The list is the host's own, unmodified. lunette re-advertises it as it
    /// stands rather than substituting types it would rather have.
    Offered {
        kind: SelectionKind,
        offer: OfferId,
        mimes: Vec<MimeType>,
    },
    /// The host has no selection of this kind any more.
    Cleared { kind: SelectionKind },
    /// The host wants the bytes of the selection lunette published.
    ///
    /// The descriptor is the host's end of a pipe, and it is handed to the
    /// lunette client that owns the selection. Nothing on lunette's side writes
    /// to it.
    Send {
        kind: SelectionKind,
        mime: MimeType,
        pipe: OwnedFd,
    },
    /// Something else on the host took the selection from lunette's source.
    Cancelled { kind: SelectionKind },
    /// The connection ended, so no selection crosses in either direction again.
    ///
    /// Not reconnected. A host Wayland session ending means the desktop lunette
    /// was overlaying is gone, and reconnecting to whatever binds the socket next
    /// would attach the clipboard to a session the user did not ask for.
    Lost { reason: String },
}

/// Where a host connection reports what it saw.
///
/// A bounded queue onto the compositor's event loop. Constructed by
/// [`crate::thread::build`], which is also what registers the reading end, so a
/// provider cannot be given a sender that nothing is listening to.
#[derive(Clone, Debug)]
pub struct HostEvents {
    pub(crate) queue: calloop::channel::SyncSender<HostEvent>,
}

impl HostEvents {
    /// Reports an event, discarding it if the compositor is behind.
    ///
    /// Never waits. The caller is a worker thread that also services the host's
    /// Wayland connection, and a wait here would stop it answering the host.
    /// A discarded [`HostEvent::Send`] closes its descriptor, which the host
    /// reads as an empty selection — the same thing it would see from a client
    /// that offered nothing.
    pub fn report(&self, event: HostEvent) {
        if let Err(error) = self.queue.try_send(event) {
            debug!(%error, "the compositor is behind; dropping a host selection event");
        }
    }
}

/// Why a host clipboard connection could not be opened.
#[derive(Debug)]
pub enum HostStartError {
    /// The socket could not be reached, or is not a Wayland connection.
    Connect {
        socket: String,
        cause: Box<dyn Error + Send + Sync>,
    },
    /// The host implements neither `ext_data_control_v1` nor
    /// `zwlr_data_control_v1`, so its clipboard cannot be read or written at
    /// all. KDE and GNOME both fall here for the wlr protocol; ext-data-control
    /// is what they are expected to gain.
    NoDataControl,
    /// The host has no `wl_seat`, so there is no device to get a selection from.
    NoSeat,
    /// The worker thread could not be started.
    Worker(Box<dyn Error + Send + Sync>),
}

impl fmt::Display for HostStartError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "selection: ")?;
        match self {
            Self::Connect { socket, cause: _ } => {
                write!(f, "could not reach the host compositor at {socket}")
            }
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
            Self::NoDataControl | Self::NoSeat => None,
        }
    }
}

#[cfg(any(test, feature = "test-fakes"))]
pub use fake::{FakeHost, FakeHostSource, HostCall};

/// A host clipboard that records what it was asked to do, for tests that must
/// run with no host desktop.
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

    /// One call the compositor made on the host.
    #[derive(Clone, Debug, PartialEq, Eq)]
    pub enum HostCall {
        Publish {
            kind: SelectionKind,
            mimes: Vec<MimeType>,
        },
        Withdraw {
            kind: SelectionKind,
        },
        /// A read, without its descriptor: the descriptor is held by the fake so
        /// a test can write to it and see what the client received.
        Read {
            kind: SelectionKind,
            mime: MimeType,
        },
    }

    /// The log and the descriptors a [`FakeHost`] has been handed.
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
        /// Every call the compositor has made, in order.
        pub fn calls(&self) -> Vec<HostCall> {
            self.lock().calls.clone()
        }

        /// The descriptors the compositor handed over, in call order.
        pub fn take_pipes(&self) -> Vec<std::os::fd::OwnedFd> {
            std::mem::take(&mut self.lock().pipes)
        }

        /// Makes every later read fail, so a test can exercise the refusal path.
        pub fn refuse(&self, reason: RejectReason) {
            self.lock().refuse = Some(reason);
        }

        /// Reports an event as the host would, once the compositor has opened
        /// this fake.
        ///
        /// # Panics
        ///
        /// If the fake has not been opened, because there is then nothing
        /// listening and a silently discarded event would look like a passing
        /// test.
        pub fn announce(&self, event: HostEvent) {
            let events = self
                .lock()
                .events
                .clone()
                .expect("the fake host has been opened by a compositor");
            events.report(event);
        }

        /// A source that opens into this fake.
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

    /// A [`HostSelectionSource`] that hands back a [`FakeHost`].
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
