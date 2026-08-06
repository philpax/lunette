//! Linux-only: the host's monitors, as the Lua surface and the frame loop reach
//! them.
//!
//! [`MirrorRegistry`] is to [`lunette_capture::mirror::MirrorSet`] what
//! [`ClaimRegistry`] is to the layer pool, and it exists for the same reason: a
//! [`Session`] holds it behind a trait object so that no second type parameter
//! has to thread through every handle. The trait's methods take `&self` because
//! that is what a Lua callback holds; the interior mutability is a [`RefCell`]
//! and not a lock because the Lua API is available in the main state alone.
//!
//! [`ClaimRegistry`]: crate::lua::ClaimRegistry
//! [`Session`]: crate::lua::Session

use std::{cell::RefCell, fmt, mem};

use lunette_capture::{
    mirror::{MirrorOutcome, MirrorSet, MonitorStreams, Progress, RosterChange},
    monitor::{LogicalGeometry, Monitor, MonitorKey, PixelExtent, Roster},
    portal::ScreenCastPortal,
    stream::CapturedFrame,
    tokens::TokenStore,
};
use tracing::warn;

/// What a monitor was, when it was last read.
///
/// A projection of `lunette-capture`'s roster and lifecycle rather than a
/// borrow of them, so that a handle can answer without holding the registry
/// borrowed across a Lua call.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MonitorState {
    pub key: MonitorKey,
    /// The identity as a user would recognise it: `Acme X24 on DP-1`.
    pub name: String,
    pub geometry: LogicalGeometry,
    /// The resolution a captured frame arrives at. Zero when the source could
    /// not read the monitor's mode.
    pub pixels: PixelExtent,
    /// Whether a capture stream is running.
    pub mirrored: bool,
    /// Whether the monitor has been asked for but has no stream yet, which is
    /// what a portal dialog awaiting the user looks like.
    pub pending: bool,
}

/// The monitors, as Lua reaches them.
pub trait MirrorRegistry: fmt::Debug {
    /// Advances the portal exchange by one frame, without blocking, and reports
    /// the monitors that have appeared since the last call.
    ///
    /// Each is announced as `lovr.lunmonitoradded`. The frame loop calls this
    /// once a frame, after the snapshot is installed, so that a handler reading
    /// `lunette.monitors()` sees the monitor it was handed.
    fn poll(&self) -> Vec<MonitorKey>;

    /// Every attached monitor, in the roster's own identity order.
    fn monitors(&self) -> Vec<MonitorState>;

    /// What is known about one monitor, or `None` once it has detached.
    fn state(&self, monitor: &MonitorKey) -> Option<MonitorState>;

    /// Starts mirroring, asking the portal if no session covers the monitor.
    fn mirror(&self, monitor: &MonitorKey) -> MirrorOutcome;

    /// Stops mirroring, keeping the session. Reports whether one was running.
    fn dismiss(&self, monitor: &MonitorKey) -> bool;

    /// Stops or restarts a mirror's stream without giving up its node.
    fn set_paused(&self, monitor: &MonitorKey, paused: bool) -> bool;
}

/// The mirror lifecycle, as the frame loop drives it.
///
/// A second trait over the same object rather than more methods on
/// [`MirrorRegistry`], because these are two audiences: [`MirrorRegistry`] is
/// what a Lua handle reads and mutates, and this is the frame's own mechanics —
/// what the host attached, what the capture produced, what has to be written to
/// disk. Keeping them apart is what stops a Lua handle reaching a capture frame.
///
/// A trait at all, rather than the concrete type, because [`HostMirrors`] is
/// generic over the portal and [`crate::frame::FrameDriver`] must not name the
/// production one — the frame loop has no business knowing whether the portal is
/// real.
pub trait MirrorFrames: fmt::Debug {
    /// Installs the source that opens capture streams.
    ///
    /// Called once, on the first frame at which LOVR has a graphics device, so
    /// the DRM formats a stream negotiates against are known.
    fn set_streams(&self, streams: Box<dyn MonitorStreams>);

    /// Replaces what lunette believes is attached, and says what changed.
    fn attach(&self, roster: Roster) -> RosterChange;

    /// The newest frame each running mirror has produced.
    fn take_frames(&self) -> Vec<(MonitorKey, CapturedFrame)>;

    /// The restore tokens to persist, once a grant has changed them.
    ///
    /// Cloned rather than borrowed, because the caller writes a file with it and
    /// the lifecycle is reachable from Lua in between.
    fn take_changed_tokens(&self) -> Option<TokenStore>;
}

/// The monitors of the machine lunette is running on.
///
/// Owns the lifecycle. The frame loop drives [`Self::poll`] once a frame and
/// Lua reaches the rest through [`MirrorRegistry`].
pub struct HostMirrors<P> {
    mirrors: RefCell<MirrorSet<P>>,
    /// Monitors attached since the last [`MirrorRegistry::poll`].
    ///
    /// Queued rather than announced from [`Self::attach`], because an event has
    /// to reach Lua at a frame boundary and a monitor may appear at any point
    /// between two.
    appeared: RefCell<Vec<MonitorKey>>,
}

impl<P: ScreenCastPortal> HostMirrors<P> {
    #[must_use]
    pub const fn new(mirrors: MirrorSet<P>) -> Self {
        Self {
            mirrors: RefCell::new(mirrors),
            appeared: RefCell::new(Vec::new()),
        }
    }

    /// Runs `body` against the lifecycle.
    ///
    /// A closure rather than a borrow guard, for the reason
    /// [`crate::lua::Session::with_textures`] takes one: the lifecycle is
    /// reachable from inside Lua callbacks, and a guard held across one would
    /// panic on the re-entry.
    pub fn with_mirrors<R>(&self, body: impl FnOnce(&mut MirrorSet<P>) -> R) -> R {
        body(&mut self.mirrors.borrow_mut())
    }
}

impl<P: ScreenCastPortal> MirrorFrames for HostMirrors<P> {
    fn set_streams(&self, streams: Box<dyn MonitorStreams>) {
        self.mirrors.borrow_mut().set_streams(streams);
    }

    /// The monitors that appeared are queued for the next
    /// [`MirrorRegistry::poll`] to announce, rather than announced here: an
    /// event reaches Lua at a frame boundary, and a monitor may appear at any
    /// point between two.
    fn attach(&self, roster: Roster) -> RosterChange {
        let change = self.mirrors.borrow_mut().attach(roster);
        self.appeared
            .borrow_mut()
            .extend(change.added.iter().cloned());
        change
    }

    fn take_frames(&self) -> Vec<(MonitorKey, CapturedFrame)> {
        self.mirrors.borrow_mut().take_frames()
    }

    fn take_changed_tokens(&self) -> Option<TokenStore> {
        self.mirrors.borrow_mut().take_changed_tokens().cloned()
    }
}

impl<P> fmt::Debug for HostMirrors<P> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("HostMirrors").finish_non_exhaustive()
    }
}

impl<P: ScreenCastPortal> MirrorRegistry for HostMirrors<P> {
    fn poll(&self) -> Vec<MonitorKey> {
        if let Progress::Failed(error) = self.mirrors.borrow_mut().poll() {
            warn!(%error, "the monitors that were asked for will not be mirrored");
        }
        mem::take(&mut self.appeared.borrow_mut())
    }

    fn monitors(&self) -> Vec<MonitorState> {
        let mirrors = self.mirrors.borrow();
        mirrors
            .roster()
            .sorted()
            .into_iter()
            .map(|monitor| describe(monitor, &mirrors))
            .collect()
    }

    fn state(&self, monitor: &MonitorKey) -> Option<MonitorState> {
        let mirrors = self.mirrors.borrow();
        let found = mirrors.roster().find(monitor)?;
        Some(describe(found, &mirrors))
    }

    fn mirror(&self, monitor: &MonitorKey) -> MirrorOutcome {
        self.mirrors.borrow_mut().mirror(monitor)
    }

    fn dismiss(&self, monitor: &MonitorKey) -> bool {
        self.mirrors.borrow_mut().dismiss(monitor)
    }

    fn set_paused(&self, monitor: &MonitorKey, paused: bool) -> bool {
        self.mirrors.borrow_mut().set_paused(monitor, paused)
    }
}

/// A registry over a machine whose monitors lunette cannot see.
///
/// What the entry point installs when the host's outputs cannot be read or the
/// screencast portal cannot be reached — no Wayland session, no session bus, a
/// container without either bound — and what a test that is not about monitors
/// uses. Distinct from a machine with no monitors only in the reason, which the
/// entry point logs where it knows it.
///
/// It implements [`MirrorRegistry`] and deliberately not [`MirrorFrames`]. A
/// session with no host desktop has no [`crate::frame::HostDesktop`] at all, so
/// there is nothing for the frame loop to drive; a no-op implementation here
/// would be a second way to spell the same absence.
#[derive(Clone, Copy, Debug, Default)]
pub struct NoMonitors;

impl MirrorRegistry for NoMonitors {
    fn poll(&self) -> Vec<MonitorKey> {
        Vec::new()
    }

    fn monitors(&self) -> Vec<MonitorState> {
        Vec::new()
    }

    fn state(&self, _monitor: &MonitorKey) -> Option<MonitorState> {
        None
    }

    fn mirror(&self, _monitor: &MonitorKey) -> MirrorOutcome {
        MirrorOutcome::NoSuchMonitor
    }

    fn dismiss(&self, _monitor: &MonitorKey) -> bool {
        false
    }

    fn set_paused(&self, _monitor: &MonitorKey, _paused: bool) -> bool {
        false
    }
}

/// Projects one roster entry, together with what the lifecycle says about it.
fn describe<P: ScreenCastPortal>(monitor: &Monitor, mirrors: &MirrorSet<P>) -> MonitorState {
    let key = monitor.key().clone();
    let mirrored = mirrors.is_mirroring(&key);
    MonitorState {
        name: monitor.name().to_string(),
        geometry: monitor.geometry(),
        pixels: monitor.pixels(),
        mirrored,
        pending: !mirrored && mirrors.is_wanted(&key),
        key,
    }
}
