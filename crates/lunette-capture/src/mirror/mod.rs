//! Linux-only: coordinates portal sessions and PipeWire streams for monitor mirrors.
//!
//! Capture starts when a monitor is first mirrored and stops when it is dismissed.
//! Pausing deactivates the existing PipeWire stream while retaining its resources.
//! Dismissing drops the stream and keeps the granted portal session, so re-adding
//! the monitor does not prompt again.
//!
//! # Non-blocking lifecycle
//!
//! [`MirrorSet::mirror`] records the requested monitor and returns.
//! [`MirrorSet::poll`] advances the portal exchange once per frame. Portal
//! progress, including a dialog awaiting the user's response, does not block the
//! frame loop.
//!
//! # External monitor roster
//!
//! [`MirrorSet`] receives attached monitors through [`MirrorSet::attach`]. The
//! [`crate::monitor::outputs`] watcher enumerates them from the host compositor.
//! Keeping enumeration outside this lifecycle lets callers supply a roster
//! independently in tests.
//!
//! # Deferred stream source
//!
//! A PipeWire stream negotiates against the DRM formats accepted by the importer.
//! Those formats are unavailable until LOVR creates a graphics device, so a
//! [`MirrorSet`] starts with [`NoStreams`]. The entry point installs the source
//! through [`MirrorSet::set_streams`] after the device exists. A monitor requested
//! before then remains wanted and opens on the first subsequent
//! [`MirrorSet::poll`].

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

/// Tracks attached monitors, requested mirrors, and their capture streams.
pub struct MirrorSet<P> {
    portal: P,
    streams: Box<dyn MonitorStreams>,
    cursor: CursorPolicy,
    roster: Roster,
    session: SessionState,
    /// Monitors requested for mirroring, whether or not a stream is running.
    ///
    /// This differs from [`Self::active`] while a session or stream is pending.
    wanted: Vec<MonitorKey>,
    active: Vec<Mirror>,
    tokens: TokenStore,
    tokens_changed: bool,
}

impl<P: ScreenCastPortal> MirrorSet<P> {
    /// Creates an empty lifecycle with no capture source installed.
    ///
    /// `tokens` contains restore tokens from a previous run. Without one, the
    /// next request does not include a restore token.
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
    /// The entry point calls this after the graphics device exposes the DRM
    /// formats accepted by the importer. Monitors requested before installation
    /// remain wanted until [`Self::poll`] can open their streams.
    pub fn set_streams(&mut self, streams: Box<dyn MonitorStreams>) {
        debug!(
            wanted = self.wanted.len(),
            "capture streams can now be opened"
        );
        self.streams = streams;
    }

    /// Replaces the attached monitors and reports additions and removals.
    ///
    /// A removed monitor loses its stream and its pending request. Keeping the
    /// request would mirror a different monitor if it later reused the same key.
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

    #[must_use]
    pub const fn portal(&self) -> &P {
        &self.portal
    }

    /// Returns the last portal error, if the last request failed.
    ///
    /// The error remains available to callers instead of existing only in the log.
    #[must_use]
    pub const fn last_failure(&self) -> Option<&PortalError> {
        match &self.session {
            SessionState::Failed(error) => Some(error),
            SessionState::Idle | SessionState::Requested(_) | SessionState::Held(_) => None,
        }
    }

    /// Requests mirroring for an attached monitor.
    ///
    /// Repeating the request for an active monitor changes nothing. A monitor not
    /// covered by the held session starts a portal request, which may prompt.
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
                // A source that cannot open yet leaves the monitor wanted until
                // the source becomes available.
                Some(node) => match self.open(key.clone(), node) {
                    true => MirrorOutcome::Mirroring,
                    false => MirrorOutcome::Requested,
                },
                // The held session does not cover this monitor, so request a new
                // session that can include it.
                None => self.request(),
            },
            SessionState::Requested(_) => MirrorOutcome::Requested,
            SessionState::Idle | SessionState::Failed(_) => self.request(),
        }
    }

    /// Stops mirroring a monitor while keeping the granted session.
    ///
    /// Returns whether a stream was running. Repeated dismissal returns `false`.
    pub fn dismiss(&mut self, key: &MonitorKey) -> bool {
        self.wanted.retain(|wanted| wanted != key);
        self.stop(key)
    }

    #[must_use]
    pub fn is_mirroring(&self, key: &MonitorKey) -> bool {
        self.active.iter().any(|mirror| &mirror.key == key)
    }

    /// Returns whether a monitor has been requested, whether or not it is running.
    #[must_use]
    pub fn is_wanted(&self, key: &MonitorKey) -> bool {
        self.wanted.iter().any(|wanted| wanted == key)
    }

    /// Pauses or resumes a mirror without giving up its node.
    ///
    /// Returns whether a stream was running for the monitor.
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

    /// Advances the portal exchange without blocking.
    ///
    /// Call once per frame. Queued, negotiating, and user-facing dialog states
    /// return [`Progress::Waiting`].
    pub fn poll(&mut self) -> Progress {
        let SessionState::Requested(request) = self.session else {
            // Retry wanted monitors whose source was unavailable when the session arrived.
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

                // Store the token for every matched monitor because one token
                // restores the complete granted session.
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

    /// Drops the held session and stops every mirror.
    ///
    /// If monitors remain wanted, this starts a new session request immediately.
    /// The request may prompt if the portal does not restore it.
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

    /// Returns the newest frame produced by each running mirror.
    ///
    /// Each stream discards older frames so callers receive the current picture
    /// rather than a backlog.
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

    /// Returns the restore tokens after a portal grant changes them.
    ///
    /// The caller persists the returned store because this library does not own
    /// the token file.
    pub fn take_changed_tokens(&mut self) -> Option<&TokenStore> {
        mem::take(&mut self.tokens_changed).then_some(&self.tokens)
    }

    /// Requests a portal session covering the wanted monitors.
    fn request(&mut self) -> MirrorOutcome {
        // One token restores the complete session, so any wanted monitor's token
        // can seed the request.
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

struct Mirror {
    key: MonitorKey,
    node: NodeId,
    stream: Box<dyn MonitorStream>,
    paused: bool,
}

enum SessionState {
    /// No request has started.
    Idle,
    /// A request is in flight; [`MirrorSet::poll`] advances it.
    Requested(RequestId),
    Held(Held),
    /// A failed request is not retried by [`MirrorSet::poll`]; a later
    /// [`MirrorSet::mirror`] call starts another request.
    Failed(PortalError),
}

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

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum MirrorOutcome {
    /// A stream is running because the held session covers this monitor.
    Mirroring,
    /// The monitor was already mirrored, and nothing changed.
    AlreadyMirroring,
    /// A portal request is in flight; [`MirrorSet::poll`] advances it.
    Requested,
    /// The portal could not be asked at all.
    Refused(PortalError),
    /// No attached monitor carries that identity. This includes a key restored
    /// from a previous run after its monitor was unplugged.
    NoSuchMonitor,
}

/// The result of advancing the portal exchange.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Progress {
    /// Nothing is in flight.
    Idle,
    /// A request is in flight, possibly showing a dialog.
    Waiting,
    /// These monitors began mirroring during this poll.
    ///
    /// The list is empty when no wanted monitor could start a stream, including
    /// when the session covers none of them or the source is not ready.
    Started(Vec<MonitorKey>),
    Failed(PortalError),
}

/// Changes reported when the attached monitors are replaced.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct RosterChange {
    /// Monitors that were not present before. The frame layer announces each as
    /// `lunmonitoradded`.
    pub added: Vec<MonitorKey>,
    /// Monitors that are no longer attached. Their mirrors are already stopped.
    pub removed: Vec<MonitorKey>,
}
