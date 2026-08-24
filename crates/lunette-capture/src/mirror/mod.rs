//! Linux-only: when a monitor's capture starts, and when it really stops.
//!
//! Capture starts when a monitor is mirrored and stops when it is dismissed.
//!
//! # Pause is not stop
//!
//! A temporarily hidden monitor is paused and keeps its stream. A dismissed
//! monitor is stopped, which drops the stream and closes its resources.
//!
//! The portal session survives a dismissal. Re-adding the monitor opens a
//! stream on the node the session already granted, so it does not prompt.
//!
//! # Nothing here blocks
//!
//! [`MirrorSet::mirror`] records what is wanted and returns.
//! [`MirrorSet::poll`] advances the portal exchange without blocking, including
//! while a user dialog is open.
//!
//! # The roster arrives from outside
//!
//! [`MirrorSet`] does not enumerate the host's monitors;
//! [`crate::monitor::outputs`] does, against the host compositor's Wayland
//! socket, and [`MirrorSet::attach`] is how the result reaches the lifecycle.
//! The separation is what lets every transition below be tested with a roster
//! built by hand.
//!
//! # The stream source arrives later still
//!
//! A PipeWire stream negotiates against the DRM formats the importer accepts,
//! and those are not known until LOVR has created a graphics device — several
//! steps into the boot sequence. So a
//! [`MirrorSet`] starts with [`NoStreams`] and installs the real source through
//! [`MirrorSet::set_streams`] once the device exists.
//!
//! A monitor mirrored before then stays wanted, and [`MirrorSet::poll`] opens it
//! when the source arrives.

pub mod source;

#[cfg(any(test, feature = "test-fakes"))]
pub mod fake;
#[cfg(test)]
mod tests;

use std::mem;

use tracing::{debug, info, warn};

pub use crate::mirror::source::{MonitorStream, MonitorStreams, NoStreams, PipewireStreams};
use crate::{
    monitor::{name::MonitorKey, roster::Roster},
    portal::{
        CursorPolicy, NodeId, PortalError, RequestId, RequestProgress, ScreenCastPortal,
        SessionRequest, correlate,
    },
    stream::CapturedFrame,
    tokens::TokenStore,
};

/// Every monitor lunette knows about, and the capture of the mirrored ones.
///
/// Generic over the portal alone. The stream source is boxed because a test
/// asserts on the portal it handed in — the requests it recorded, the scripts it
/// has left — and cannot do that through a `Box<dyn ScreenCastPortal>`, whereas
/// nothing needs the source back.
pub struct MirrorSet<P> {
    portal: P,
    streams: Box<dyn MonitorStreams>,
    cursor: CursorPolicy,
    roster: Roster,
    session: SessionState,
    /// The monitors Lua has asked to mirror, whether or not one is running.
    ///
    /// Kept apart from [`Self::active`] because the two diverge whenever a
    /// session has not arrived yet: a monitor is wanted from the moment
    /// [`Self::mirror`] is called, and mirrored only once a stream exists.
    wanted: Vec<MonitorKey>,
    active: Vec<Mirror>,
    tokens: TokenStore,
    tokens_changed: bool,
}

impl<P: ScreenCastPortal> MirrorSet<P> {
    /// Builds a set that knows no monitors, holds no session, and cannot open a
    /// stream yet.
    ///
    /// `tokens` is what a previous run stored, so that the first request can
    /// offer one and skip the dialog. An empty store is the ordinary first-run
    /// case rather than an error.
    ///
    /// [`Self::set_streams`] is what makes the set able to capture. Until then
    /// every mirror is remembered and none is running; see the module note.
    #[must_use]
    pub fn new(portal: P, cursor: CursorPolicy, tokens: TokenStore) -> Self {
        Self {
            portal,
            streams: Box::new(NoStreams),
            cursor,
            roster: Roster::new(),
            session: SessionState::Idle,
            wanted: Vec::new(),
            active: Vec::new(),
            tokens,
            tokens_changed: false,
        }
    }

    /// Installs the source that opens capture streams.
    ///
    /// Installs the source once the graphics device exists and the DRM formats
    /// accepted by the importer are known. Replacing the source does not disturb
    /// streams already open:
    /// there are none, because a source that could open one is exactly what was
    /// missing.
    pub fn set_streams(&mut self, streams: Box<dyn MonitorStreams>) {
        debug!(
            wanted = self.wanted.len(),
            "capture streams can now be opened"
        );
        self.streams = streams;
    }

    /// Replaces what lunette believes is attached, and says what changed.
    ///
    /// A monitor that has gone loses its mirror and stops being wanted: a stream
    /// on a detached screen produces nothing, and leaving the request standing
    /// would silently re-mirror it if an unrelated monitor later landed on the
    /// same key.
    pub fn attach(&mut self, roster: Roster) -> RosterChange {
        let added = roster
            .monitors()
            .iter()
            .filter(|monitor| self.roster.find(monitor.key()).is_none())
            .map(|monitor| monitor.key().clone())
            .collect();
        let removed: Vec<MonitorKey> = self
            .roster
            .monitors()
            .iter()
            .filter(|monitor| roster.find(monitor.key()).is_none())
            .map(|monitor| monitor.key().clone())
            .collect();

        self.roster = roster;
        for key in &removed {
            self.stop(key);
            self.wanted.retain(|wanted| wanted != key);
        }

        RosterChange { added, removed }
    }

    #[must_use]
    pub const fn roster(&self) -> &Roster {
        &self.roster
    }

    /// The portal used by this set.
    #[must_use]
    pub const fn portal(&self) -> &P {
        &self.portal
    }

    /// Why the last request failed, if the last one did.
    ///
    /// Held rather than logged and discarded, so that a configuration asking why
    /// nothing is mirroring can be told, rather than being left to read the
    /// process's log.
    #[must_use]
    pub const fn last_failure(&self) -> Option<&PortalError> {
        match &self.session {
            SessionState::Failed(error) => Some(error),
            SessionState::Idle | SessionState::Requested(_) | SessionState::Held(_) => None,
        }
    }

    /// Asks for a monitor to be mirrored.
    ///
    /// Idempotent: mirroring a monitor already mirrored changes nothing and says
    /// so. The first call for a monitor no held session covers is what asks the
    /// portal, which may prompt.
    pub fn mirror(&mut self, key: &MonitorKey) -> MirrorOutcome {
        if self.roster.find(key).is_none() {
            return MirrorOutcome::NoSuchMonitor;
        }
        if self.active.iter().any(|mirror| &mirror.key == key) {
            return MirrorOutcome::AlreadyMirroring;
        }
        if !self.wanted.iter().any(|wanted| wanted == key) {
            self.wanted.push(key.clone());
        }

        match &self.session {
            SessionState::Held(held) => match held.node_for(key) {
                // A source that cannot open one yet leaves the monitor wanted
                // and reports the same thing a pending dialog does: the request
                // was made, and it has not landed.
                Some(node) => match self.open(key.clone(), node) {
                    true => MirrorOutcome::Mirroring,
                    false => MirrorOutcome::Requested,
                },
                // The session was granted without this screen in it, so the only
                // way to reach it is another dialog.
                None => self.request(),
            },
            SessionState::Requested(_) => MirrorOutcome::Requested,
            SessionState::Idle | SessionState::Failed(_) => self.request(),
        }
    }

    /// Stops mirroring a monitor, keeping the session that granted it.
    ///
    /// Reports whether a stream was actually running. Dismissing twice is not an
    /// error: the second call finds nothing to stop and says so.
    pub fn dismiss(&mut self, key: &MonitorKey) -> bool {
        self.wanted.retain(|wanted| wanted != key);
        self.stop(key)
    }

    /// Whether a stream is running for a monitor.
    #[must_use]
    pub fn is_mirroring(&self, key: &MonitorKey) -> bool {
        self.active.iter().any(|mirror| &mirror.key == key)
    }

    /// Whether a monitor has been asked for, whether or not it is running yet.
    #[must_use]
    pub fn is_wanted(&self, key: &MonitorKey) -> bool {
        self.wanted.iter().any(|wanted| wanted == key)
    }

    /// Stops or restarts a mirror's stream without giving up its node.
    ///
    /// For a panel that has left the user's view. Reports whether a mirror was
    /// there to pause.
    pub fn set_paused(&mut self, key: &MonitorKey, paused: bool) -> bool {
        let Some(mirror) = self.active.iter_mut().find(|mirror| &mirror.key == key) else {
            return false;
        };

        if mirror.paused == paused {
            return true;
        }
        mirror.paused = paused;
        if paused {
            mirror.stream.pause();
        } else {
            mirror.stream.resume();
        }
        true
    }

    /// Advances the portal exchange, without blocking.
    ///
    /// Advances the exchange without blocking. Every non-terminal progress,
    /// including an unanswered dialog, is [`Progress::Waiting`].
    pub fn poll(&mut self) -> Progress {
        let SessionState::Requested(request) = self.session else {
            // A held session still has work on most frames only in one case:
            // a wanted monitor whose stream could not be opened when the grant
            // arrived, because the source was not ready. Retried here rather
            // than at the moment the source is installed, so there is one place
            // that opens streams.
            let started = self.open_wanted();
            return if started.is_empty() {
                Progress::Idle
            } else {
                Progress::Started(started)
            };
        };

        match self.portal.poll(request) {
            RequestProgress::Queued
            | RequestProgress::Negotiating
            | RequestProgress::AwaitingUser => Progress::Waiting,
            RequestProgress::Ready(response) => {
                let correlation = correlate(&response.streams, &self.roster);

                for unmatched in &correlation.unmatched {
                    warn!(
                        node = %unmatched.node,
                        reason = %unmatched.reason,
                        "the portal granted a stream lunette could not tie to a monitor",
                    );
                }

                let held = Held {
                    nodes: correlation
                        .matched
                        .iter()
                        .map(|matched| (matched.monitor.clone(), matched.node))
                        .collect(),
                };

                // Every matched monitor, not only the ones wanted: the token
                // restores the whole session, so whichever monitor is mirrored
                // first on the next run has to be able to offer it.
                for (key, _) in &held.nodes {
                    self.tokens.record(
                        key.clone(),
                        response.restore_token.clone(),
                        response.granted_persist_mode,
                    );
                }
                self.tokens_changed = true;

                info!(
                    monitors = held.nodes.len(),
                    persistence = %response.granted_persist_mode,
                    "the portal granted a screencast session",
                );
                self.session = SessionState::Held(held);
                Progress::Started(self.open_wanted())
            }
            RequestProgress::Failed(error) => {
                warn!(%error, "no screencast session was granted");
                self.session = SessionState::Failed(error.clone());
                Progress::Failed(error)
            }
        }
    }

    /// Gives up the held session, stopping every mirror.
    ///
    /// For a session the portal has closed — the user revoked it in their
    /// settings, or the backend restarted. The monitors stay wanted, so the next
    /// [`Self::poll`] asks for a fresh session, which may prompt.
    pub fn revoke_session(&mut self) {
        if matches!(self.session, SessionState::Idle) {
            return;
        }

        debug!(
            mirrors = self.active.len(),
            "the screencast session is gone"
        );
        self.active.clear();
        self.session = SessionState::Idle;

        if !self.wanted.is_empty() {
            let _ = self.request();
        }
    }

    /// The newest frame each running mirror has produced.
    ///
    /// Frames not taken are dropped by the stream's own bounded queue, which is
    /// the behaviour an overlay wants: the newest picture, never a backlog.
    #[must_use]
    pub fn take_frames(&mut self) -> Vec<(MonitorKey, CapturedFrame)> {
        self.active
            .iter_mut()
            .filter_map(|mirror| {
                mirror
                    .stream
                    .latest()
                    .map(|frame| (mirror.key.clone(), frame))
            })
            .collect()
    }

    /// The tokens to persist, once something has changed them.
    ///
    /// Reported rather than written from here: this is a library, and where the
    /// file location belongs to the application layer.
    pub fn take_changed_tokens(&mut self) -> Option<&TokenStore> {
        mem::take(&mut self.tokens_changed).then_some(&self.tokens)
    }

    /// Asks the portal for a session covering the wanted monitors.
    fn request(&mut self) -> MirrorOutcome {
        // Any wanted monitor's token will do, and they are all the same token:
        // one dialog covers every screen, so one token restores the session and
        // `poll` records it under every monitor the session matched.
        let restore = self
            .wanted
            .iter()
            .find_map(|key| self.tokens.token_for(key))
            .cloned();

        match self.portal.begin(SessionRequest::new(restore, self.cursor)) {
            Ok(request) => {
                self.session = SessionState::Requested(request);
                MirrorOutcome::Requested
            }
            Err(error) => {
                warn!(%error, "the screencast portal could not be asked for a session");
                self.session = SessionState::Failed(error.clone());
                MirrorOutcome::Refused(error)
            }
        }
    }

    /// Opens a stream for every wanted monitor the session covers.
    fn open_wanted(&mut self) -> Vec<MonitorKey> {
        let SessionState::Held(held) = &self.session else {
            return Vec::new();
        };

        let pending: Vec<(MonitorKey, NodeId)> = self
            .wanted
            .iter()
            .filter(|key| !self.active.iter().any(|mirror| &&mirror.key == key))
            .filter_map(|key| held.node_for(key).map(|node| (key.clone(), node)))
            .collect();

        let mut started = Vec::with_capacity(pending.len());
        for (key, node) in pending {
            if self.open(key.clone(), node) {
                started.push(key);
            }
        }
        started
    }

    /// Opens a stream for one monitor. Reports whether the source could.
    fn open(&mut self, key: MonitorKey, node: NodeId) -> bool {
        let Some(stream) = self.streams.open(&key.to_string(), node) else {
            return false;
        };

        self.active.push(Mirror {
            key,
            node,
            stream,
            paused: false,
        });
        true
    }

    /// Drops a monitor's stream. Reports whether one was running.
    fn stop(&mut self, key: &MonitorKey) -> bool {
        let Some(index) = self.active.iter().position(|mirror| &mirror.key == key) else {
            return false;
        };

        let mirror = self.active.remove(index);
        info!(
            monitor = %mirror.key,
            node = %mirror.node,
            "stopped mirroring; the session is kept, so re-adding does not prompt",
        );
        true
    }
}

/// One running mirror.
struct Mirror {
    key: MonitorKey,
    node: NodeId,
    stream: Box<dyn MonitorStream>,
    paused: bool,
}

/// What a session is, at any moment.
enum SessionState {
    /// Nothing has asked for one.
    Idle,
    /// A request is in flight. [`MirrorSet::poll`] advances it.
    Requested(RequestId),
    Held(Held),
    /// The last request failed.
    ///
    /// Kept rather than falling back to [`Self::Idle`] so a monitor on a host
    /// without a portal does not retry automatically.
    Failed(PortalError),
}

/// A granted session, and the node each monitor's stream connects to.
struct Held {
    nodes: Vec<(MonitorKey, NodeId)>,
}

impl Held {
    fn node_for(&self, key: &MonitorKey) -> Option<NodeId> {
        self.nodes
            .iter()
            .find_map(|(monitor, node)| (monitor == key).then_some(*node))
    }
}

/// What asking for a mirror did.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum MirrorOutcome {
    /// A stream is running, because the session already covered this monitor.
    Mirroring,
    /// The monitor was already mirrored, and nothing changed.
    AlreadyMirroring,
    /// The portal was asked. A dialog may be on the user's screen;
    /// [`MirrorSet::poll`] is what carries it forward.
    Requested,
    /// The portal could not be asked at all.
    Refused(PortalError),
    /// No attached monitor carries that identity. Ordinary for a key stored by a
    /// previous run whose monitor is unplugged.
    NoSuchMonitor,
}

/// How far the portal exchange has got.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Progress {
    /// Nothing is in flight.
    Idle,
    /// A request is in flight, possibly showing a dialog. Ordinary.
    Waiting,
    /// A session arrived, and these monitors began mirroring.
    ///
    /// Empty when the session covered none of the wanted monitors, which is what
    /// the user selecting the wrong screens looks like.
    Started(Vec<MonitorKey>),
    Failed(PortalError),
}

/// What changed when the attached monitors were replaced.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct RosterChange {
    /// Monitors not present before. Each is announced as `lunmonitoradded`.
    pub added: Vec<MonitorKey>,
    /// Monitors that have gone. Their mirrors are already stopped.
    pub removed: Vec<MonitorKey>,
}
