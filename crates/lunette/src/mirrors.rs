//! Linux-only: the host's monitors, as the Lua surface and the frame loop reach
//! them.
//!
//! [`MirrorRegistry`] relates to [`lunette_capture::mirror::MirrorSet`] the way
//! [`ClaimRegistry`] relates to the layer pool. Both exist for one reason: a
//! [`Session`] holds them behind trait objects, which keeps a second type
//! parameter off every handle. The trait methods take `&self` because a Lua
//! callback holds a shared reference. Interior mutability is a [`RefCell`],
//! not a lock, because the Lua API is available in the main state alone.
//!
//! [`ClaimRegistry`]: crate::lua::ClaimRegistry
//! [`Session`]: crate::lua::Session

use std::{cell::RefCell, fmt, mem};

use lunette_capture::{
    mirror::{
        MirrorOutcome, MirrorSet, MonitorStreams, Progress, RosterChange, SelectionOutcome,
        SelectionState,
    },
    monitor::{LogicalGeometry, Monitor, MonitorKey, PixelExtent, Roster},
    portal::ScreenCastPortal,
    stream::CapturedFrame,
    tokens::TokenStore,
};
use tracing::warn;

/// A monitor's state as of its last read.
///
/// A projection of `lunette-capture`'s roster and lifecycle, not a borrow of
/// them. A handle then answers without holding the registry borrowed across a
/// Lua call.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MonitorState {
    pub key: MonitorKey,
    /// The identity a user recognises, such as `Acme X24 on DP-1`.
    pub name: String,
    pub geometry: LogicalGeometry,
    /// The resolution a captured frame arrives at. Zero when the source cannot
    /// read the monitor's mode.
    pub pixels: PixelExtent,
    /// Whether a capture stream is running.
    pub mirrored: bool,
    /// Whether the monitor has been requested but has no stream yet. A portal
    /// dialog awaiting the user's choice is in this state.
    pub pending: bool,
}

/// The monitors, as Lua reaches them.
pub trait MirrorRegistry: fmt::Debug {
    /// Advances the portal exchange by one frame, without blocking, and reports
    /// the monitors that appeared after the last call.
    ///
    /// Each appears as `lovr.lunmonitoradded`. The frame loop calls this once a
    /// frame, after the snapshot is installed. A handler reading
    /// `lunette.monitors()` then sees that monitor.
    fn poll(&self) -> Vec<MonitorKey>;

    /// Every attached monitor, in the roster's own identity order.
    fn monitors(&self) -> Vec<MonitorState>;

    /// What is known about one monitor, or `None` once it has detached.
    fn state(&self, monitor: &MonitorKey) -> Option<MonitorState>;

    /// Starts mirroring, asking the portal if no session covers the monitor.
    fn mirror(&self, monitor: &MonitorKey) -> MirrorOutcome;

    /// Stops mirroring, keeping the session. Reports whether the call stopped
    /// a running mirror.
    fn dismiss(&self, monitor: &MonitorKey) -> bool;

    /// Stops or restarts a mirror's stream without releasing its node.
    fn set_paused(&self, monitor: &MonitorKey, paused: bool) -> bool;

    /// Requests a fresh selection without restoring the previous grant.
    fn select_monitors(&self) -> SelectionOutcome;

    /// The latest explicit selection's state, independent of existing capture.
    fn selection_state(&self) -> SelectionState;

    /// Reports whether an active monitor uses direct capture.
    fn is_direct(&self, _monitor: &MonitorKey) -> bool {
        false
    }

    /// Defers dismissal while a replacement configuration acquires its mirrors.
    fn begin_reload(&self) -> bool {
        true
    }

    /// Releases mirrors not reused by the replacement configuration.
    fn finish_reload(&self) {}
}

/// The mirror lifecycle, as the frame loop advances it.
///
/// A second trait over the same object keeps the two audiences apart. A Lua
/// handle reads and mutates [`MirrorRegistry`]. The frame's own mechanics use
/// this trait: the host's attachments, the capture's frames, the tokens to
/// write to disk. The separation stops a Lua handle reaching a capture frame.
///
/// The trait exists because [`HostMirrors`] is generic over the portal and
/// [`crate::frame::FrameDriver`] must not name the production one. The frame
/// loop does not need to know whether the portal is real.
pub trait MirrorFrames: fmt::Debug {
    /// Installs the source that opens capture streams.
    ///
    /// Called once, on the first frame at which LOVR has a graphics device.
    /// A stream negotiates its DRM formats against that device.
    fn set_streams(&self, streams: Box<dyn MonitorStreams>);

    /// Replaces the roster lunette tracks and reports what changed.
    fn attach(&self, roster: Roster) -> RosterChange;

    /// The newest frame each running mirror has produced.
    fn take_frames(&self) -> Vec<(MonitorKey, CapturedFrame)>;

    /// Drains identities whose previous streams have been replaced.
    fn take_replaced_monitors(&self) -> Vec<MonitorKey>;

    /// The restore tokens to persist, once a grant has changed them.
    ///
    /// Cloned because the caller writes a file with it and the lifecycle is
    /// reachable from Lua in between.
    fn take_changed_tokens(&self) -> Option<TokenStore>;
}

/// The monitors of the machine lunette is running on.
///
/// Owns the lifecycle. The frame loop calls [`Self::poll`] once a frame, and
/// Lua reaches the rest through [`MirrorRegistry`].
pub struct HostMirrors<P> {
    mirrors: RefCell<MirrorSet<P>>,
    /// Monitors attached since the last [`MirrorRegistry::poll`].
    ///
    /// Queued, not announced from [`Self::attach`]. An event has to reach Lua
    /// at a frame boundary, and a monitor may appear at any point between
    /// two.
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
    /// A closure, not a borrow guard, for the reason
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
    /// [`MirrorRegistry::poll`] to announce, not announced here. An event
    /// reaches Lua at a frame boundary, and a monitor may appear at any
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

    fn take_replaced_monitors(&self) -> Vec<MonitorKey> {
        self.mirrors.borrow_mut().take_replaced_monitors()
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

    fn select_monitors(&self) -> SelectionOutcome {
        self.mirrors.borrow_mut().select_monitors()
    }

    fn selection_state(&self) -> SelectionState {
        self.mirrors.borrow().selection_state()
    }

    fn is_direct(&self, monitor: &MonitorKey) -> bool {
        self.mirrors.borrow().is_direct(monitor)
    }

    fn begin_reload(&self) -> bool {
        self.mirrors.borrow_mut().begin_reload()
    }

    fn finish_reload(&self) {
        self.mirrors.borrow_mut().finish_reload();
    }
}

/// A registry over a machine whose monitors lunette cannot see.
///
/// What the entry point installs when the host's outputs cannot be read or the
/// screencast portal cannot be reached: no Wayland session, no session bus, a
/// container without either bound. What a test that is not about monitors
/// uses. It differs from a machine with no monitors only in the reason, which
/// the entry point logs where it knows it.
///
/// It implements [`MirrorRegistry`] and not [`MirrorFrames`]. A session with
/// no host desktop has no [`crate::frame::HostDesktop`], so there is nothing
/// for the frame loop to advance; a no-op implementation here would be a
/// second way to spell the same absence.
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

    fn select_monitors(&self) -> SelectionOutcome {
        SelectionOutcome::NoMonitors
    }

    fn selection_state(&self) -> SelectionState {
        SelectionState::Idle
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
