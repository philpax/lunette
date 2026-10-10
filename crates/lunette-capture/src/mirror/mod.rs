//! Linux-only: tracks mirrored monitors, preferring direct monitor capture with a portal and
//! PipeWire fallback.
//!
//! A [`MirrorSet`] starts with [`NoStreams`] because the importer's DRM formats exist only once
//! LÖVR has a graphics device. A monitor requested before then opens on the first
//! [`MirrorSet::poll`] after [`MirrorSet::set_streams`].
//!
//! A portal session ends when its PipeWire nodes are removed, which a [`NodeWatch`] reports.
//! [`MirrorSet::poll`] stops the streams on removed nodes and revokes the session once none of its
//! nodes remain.

pub mod nodes;
pub mod screencopy;
pub mod source;

#[cfg(test)]
pub mod fake;
#[cfg(test)]
mod tests;

use std::mem;

use tracing::{debug, info, warn};

pub use crate::mirror::{
    nodes::{NoNodeWatch, NodeWatch, NodeWatchError, PipewireNodeWatch},
    source::{DirectOpen, MonitorStream, MonitorStreams, NoStreams, PipewireStreams},
};
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
    nodes: Box<dyn NodeWatch>,
    cursor: CursorPolicy,
    roster: Roster,
    session: SessionState,
    selection: SelectionRequest,
    replaced: Vec<MonitorKey>,
    /// Monitors requested for mirroring, whether or not a stream is running.
    wanted: Vec<MonitorKey>,
    active: Vec<Mirror>,
    tokens: TokenStore,
    tokens_changed: bool,
    reload_dismissed: Option<Vec<MonitorKey>>,
}

impl<P: ScreenCastPortal> MirrorSet<P> {
    /// Creates an empty lifecycle with no capture source installed.
    ///
    /// `tokens` contains restore tokens from a previous run.
    #[must_use]
    pub fn new(portal: P, cursor: CursorPolicy, tokens: TokenStore) -> Self {
        Self {
            portal,
            streams: Box::new(NoStreams),
            nodes: Box::new(NoNodeWatch),
            cursor,
            roster: Roster::new(),
            session: SessionState::Idle,
            selection: SelectionRequest::Idle,
            replaced: Vec::new(),
            wanted: Vec::new(),
            active: Vec::new(),
            tokens,
            tokens_changed: false,
            reload_dismissed: None,
        }
    }

    /// Installs the watch that reports when a portal session's nodes are removed.
    ///
    /// Without one, a session the user stops keeps its mirrors marked as running with no frames.
    #[must_use]
    pub fn with_node_watch(mut self, nodes: Box<dyn NodeWatch>) -> Self {
        self.nodes = nodes;
        self
    }

    /// Installs the source that opens capture streams.
    ///
    /// Monitors requested before installation remain wanted until [`Self::poll`] can open their
    /// streams.
    pub fn set_streams(&mut self, streams: Box<dyn MonitorStreams>) {
        debug!(
            wanted = self.wanted.len(),
            "capture streams can now be opened"
        );
        self.replaced
            .extend(self.active.iter().map(|mirror| mirror.key.clone()));
        self.active.clear();
        self.streams = streams;
    }

    /// Replaces the attached monitors and reports additions and removals.
    ///
    /// A removed monitor loses its pending request, because a later monitor could reuse its key.
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

    /// Requests mirroring for an attached monitor.
    ///
    /// A monitor not covered by the held session starts a portal request, which may prompt.
    pub fn mirror(&mut self, key: &MonitorKey) -> MirrorOutcome {
        if self.roster.find(key).is_none() {
            return MirrorOutcome::NoSuchMonitor;
        }
        if let Some(dismissed) = &mut self.reload_dismissed {
            dismissed.retain(|monitor| monitor != key);
        }
        if self.active.iter().any(|mirror| &mirror.key == key) {
            return MirrorOutcome::AlreadyMirroring;
        }
        if let SelectionRequest::Pending { dismissed, .. } = &mut self.selection {
            dismissed.retain(|monitor| monitor != key);
            if !self.wanted.contains(key) {
                self.wanted.push(key.clone());
            }
            return MirrorOutcome::Requested;
        }
        if !self.wanted.iter().any(|wanted| wanted == key) {
            self.wanted.push(key.clone());
        }

        if self.try_direct(key) {
            return if self.is_mirroring(key) {
                MirrorOutcome::Mirroring
            } else {
                MirrorOutcome::Requested
            };
        }

        match &self.session {
            SessionState::Held(held) => match held.node_for(key) {
                Some(node) => match self.open(key.clone(), node) {
                    true => MirrorOutcome::Mirroring,
                    false => MirrorOutcome::Requested,
                },
                None => self.request(),
            },
            SessionState::Requested(_) => MirrorOutcome::Requested,
            SessionState::Idle => self.request(),
            SessionState::Failed(error) => MirrorOutcome::Refused(error.clone()),
        }
    }

    /// Requests a fresh monitor selection without restoring the previous grant.
    /// Existing streams continue until the request succeeds, and a failure retains them.
    pub fn select_monitors(&mut self) -> SelectionOutcome {
        if self.roster.monitors().is_empty() {
            return SelectionOutcome::NoMonitors;
        }
        if matches!(self.session, SessionState::Requested(_))
            || matches!(self.selection, SelectionRequest::Pending { .. })
        {
            return SelectionOutcome::Busy;
        }
        match self.portal.begin(SessionRequest::new(None, self.cursor)) {
            Ok(request) => {
                self.selection = SelectionRequest::Pending {
                    request,
                    dismissed: Vec::new(),
                };
                SelectionOutcome::Requested
            }
            Err(error) => {
                if matches!(self.session, SessionState::Idle | SessionState::Failed(_)) {
                    self.session = SessionState::Failed(error.clone());
                }
                self.selection = SelectionRequest::Failed(error.clone());
                SelectionOutcome::Refused(error)
            }
        }
    }

    /// Reports the latest explicit selection request, independently of active capture.
    #[must_use]
    pub fn selection_state(&self) -> SelectionState {
        match &self.selection {
            SelectionRequest::Idle => SelectionState::Idle,
            SelectionRequest::Pending { .. } => SelectionState::Pending,
            SelectionRequest::Ready => SelectionState::Ready,
            SelectionRequest::Failed(error) => SelectionState::Failed(error.clone()),
        }
    }

    /// Stops mirroring a monitor while keeping the granted session.
    ///
    /// Returns whether a stream was running.
    pub fn dismiss(&mut self, key: &MonitorKey) -> bool {
        if let Some(dismissed) = &mut self.reload_dismissed {
            if !dismissed.contains(key) {
                dismissed.push(key.clone());
            }
            return self.is_mirroring(key);
        }
        self.wanted.retain(|wanted| wanted != key);
        if let SelectionRequest::Pending { dismissed, .. } = &mut self.selection
            && !dismissed.contains(key)
        {
            dismissed.push(key.clone());
        }
        self.stop(key)
    }

    #[must_use]
    pub fn is_mirroring(&self, key: &MonitorKey) -> bool {
        self.active.iter().any(|mirror| &mirror.key == key)
    }

    /// Defers plugin-owned dismissal until the replacement configuration requests its monitors.
    pub fn begin_reload(&mut self) -> bool {
        if self.reload_dismissed.is_some() {
            return false;
        }
        self.reload_dismissed = Some(Vec::new());
        true
    }

    /// Stops streams not reused by the replacement configuration, including a failed reload.
    pub fn finish_reload(&mut self) {
        for key in self.reload_dismissed.take().unwrap_or_default() {
            self.dismiss(&key);
        }
    }

    /// Reports whether the running stream uses direct screencopy rather than the portal.
    #[must_use]
    pub fn is_direct(&self, key: &MonitorKey) -> bool {
        self.active
            .iter()
            .any(|mirror| &mirror.key == key && mirror.node.is_none())
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
    /// Queued, negotiating, and dialog states return [`Progress::Waiting`]. Node removals the
    /// watch has reported are handled before a grant is taken, so they cannot end that grant.
    pub fn poll(&mut self) -> Progress {
        self.end_removed_nodes();
        if let SelectionRequest::Pending { request, .. } = &self.selection {
            return self.poll_selection(*request);
        }
        let SessionState::Requested(request) = self.session else {
            // Retries wanted monitors whose source was unavailable when the session arrived.
            let started = self.open_wanted();
            return if !started.is_empty() {
                Progress::Started(started)
            } else if matches!(self.session, SessionState::Requested(_)) {
                Progress::Waiting
            } else {
                Progress::Idle
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

                // One token restores the complete granted session, so every matched monitor stores
                // it.
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

    /// Stops the streams whose nodes were removed, and revokes the session once it holds none.
    ///
    /// A monitor whose node alone is removed stays wanted and waits for a later grant, because
    /// the rest of the session is still live. A removal of a node the session does not hold, such
    /// as one from a session already replaced, changes nothing.
    fn end_removed_nodes(&mut self) {
        let removed = self.nodes.take_removed();
        if removed.is_empty() {
            return;
        }
        let SessionState::Held(held) = &mut self.session else {
            return;
        };
        let before = held.nodes.len();
        held.nodes.retain(|(_, node)| !removed.contains(node));
        if held.nodes.len() == before {
            return;
        }

        if held.nodes.is_empty() {
            info!("every stream of the screencast session ended, so the session was revoked");
            self.revoke_session();
            return;
        }
        for mirror in &self.active {
            if mirror.node.is_some_and(|node| removed.contains(&node)) {
                info!(monitor = %mirror.key, "the portal ended this monitor's stream");
            }
        }
        self.active
            .retain(|mirror| mirror.node.is_none_or(|node| !removed.contains(&node)));
    }

    /// Drops the held portal session and stops its PipeWire mirrors.
    ///
    /// Direct streams continue. Wanted monitors that still need the portal start
    /// a new request, which may prompt if the portal does not restore it.
    fn revoke_session(&mut self) {
        if matches!(self.session, SessionState::Idle) {
            return;
        }

        debug!(
            mirrors = self.active.len(),
            "the screencast session is gone"
        );
        self.active.retain(|mirror| mirror.node.is_none());
        self.session = SessionState::Idle;

        if !matches!(self.selection, SelectionRequest::Pending { .. }) {
            let _ = self.open_wanted();
        }
    }

    /// Returns the newest frame produced by each running mirror.
    ///
    /// Each stream discards older frames, so callers receive the current picture.
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
    /// The caller persists the store because this library does not own the token file.
    pub fn take_changed_tokens(&mut self) -> Option<&TokenStore> {
        mem::take(&mut self.tokens_changed).then_some(&self.tokens)
    }

    /// Monitors whose old streams were replaced by a successful selection.
    /// The frame loop discards their stale textures before importing new frames.
    pub fn take_replaced_monitors(&mut self) -> Vec<MonitorKey> {
        mem::take(&mut self.replaced)
    }

    fn poll_selection(&mut self, request: RequestId) -> Progress {
        match self.portal.poll(request) {
            RequestProgress::Queued
            | RequestProgress::Negotiating
            | RequestProgress::AwaitingUser => Progress::Waiting,
            RequestProgress::Failed(error) => {
                if matches!(self.session, SessionState::Idle | SessionState::Failed(_)) {
                    self.session = SessionState::Failed(error.clone());
                }
                self.selection = SelectionRequest::Failed(error.clone());
                Progress::Failed(error)
            }
            RequestProgress::Ready(response) => {
                let correlation = correlate(&response.streams, &self.roster);
                for unmatched in &correlation.unmatched {
                    warn!(node = %unmatched.node, reason = %unmatched.reason, "monitor selection: unmatched stream");
                }
                if correlation.matched.is_empty() {
                    let error =
                        PortalError::Malformed("monitor selection matching an attached monitor");
                    self.selection = SelectionRequest::Failed(error.clone());
                    return Progress::Failed(error);
                }
                let dismissed = match &self.selection {
                    SelectionRequest::Pending { dismissed, .. } => dismissed,
                    _ => return Progress::Idle,
                };
                self.replaced.extend(
                    self.active
                        .iter()
                        .filter(|mirror| mirror.node.is_some())
                        .map(|mirror| mirror.key.clone()),
                );
                self.active.retain(|mirror| mirror.node.is_none());
                self.tokens = TokenStore::new();
                let nodes: Vec<_> = correlation
                    .matched
                    .into_iter()
                    .map(|matched| (matched.monitor, matched.node))
                    .collect();
                self.wanted = self
                    .active
                    .iter()
                    .map(|mirror| mirror.key.clone())
                    .collect();
                for (key, _) in &nodes {
                    if !dismissed.contains(key) && !self.wanted.contains(key) {
                        self.wanted.push(key.clone());
                    }
                }
                for (key, _) in &nodes {
                    self.tokens.record(
                        key.clone(),
                        response.restore_token.clone(),
                        response.granted_persist_mode,
                    );
                }
                self.tokens_changed = true;
                self.session = SessionState::Held(Held { nodes });
                self.selection = SelectionRequest::Ready;
                Progress::Started(self.open_wanted())
            }
        }
    }

    /// Requests a portal session covering the wanted monitors.
    fn request(&mut self) -> MirrorOutcome {
        // One token restores the complete session, so any wanted monitor's token can seed the
        // request.
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

    fn try_direct(&mut self, key: &MonitorKey) -> bool {
        let Some(monitor) = self.roster.find(key) else {
            return false;
        };
        match self.streams.open_direct(monitor) {
            DirectOpen::Opened(stream) => {
                self.active.push(Mirror {
                    key: key.clone(),
                    node: None,
                    stream,
                    paused: false,
                });
                true
            }
            DirectOpen::Deferred => true,
            DirectOpen::Unavailable => false,
        }
    }

    fn open_wanted(&mut self) -> Vec<MonitorKey> {
        let pending: Vec<_> = self
            .wanted
            .iter()
            .filter(|key| !self.active.iter().any(|mirror| &&mirror.key == key))
            .cloned()
            .collect();
        let mut started = Vec::new();
        let mut needs_portal = false;
        for key in pending {
            let node = match &self.session {
                SessionState::Held(held) => held.node_for(&key),
                _ => None,
            };
            if self.try_direct(&key) {
                if self.is_mirroring(&key) {
                    started.push(key);
                }
            } else if let Some(node) = node {
                if self.open(key.clone(), node) {
                    started.push(key);
                }
            } else {
                needs_portal = true;
            }
        }
        if needs_portal && matches!(self.session, SessionState::Idle) {
            let _ = self.request();
        }
        started
    }

    fn open(&mut self, key: MonitorKey, node: NodeId) -> bool {
        let Some(stream) = self.streams.open(&key.to_string(), node) else {
            return false;
        };

        self.active.push(Mirror {
            key,
            node: Some(node),
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
            node = ?mirror.node,
            "stopped mirroring; the session is kept, so re-adding does not prompt",
        );
        true
    }
}

struct Mirror {
    key: MonitorKey,
    node: Option<NodeId>,
    stream: Box<dyn MonitorStream>,
    paused: bool,
}

enum SessionState {
    /// No request has started.
    Idle,
    /// A request is in flight; [`MirrorSet::poll`] advances it.
    Requested(RequestId),
    Held(Held),
    /// A failed request stays refused until explicit [`MirrorSet::select_monitors`].
    Failed(PortalError),
}

enum SelectionRequest {
    Idle,
    Pending {
        request: RequestId,
        dismissed: Vec<MonitorKey>,
    },
    Ready,
    Failed(PortalError),
}

/// The result of starting an explicit fresh selection.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SelectionOutcome {
    Requested,
    Busy,
    NoMonitors,
    Refused(PortalError),
}

/// The latest explicit selection's state. Existing capture remains live while it is pending or
/// failed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SelectionState {
    Idle,
    Pending,
    Ready,
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
    /// No attached monitor carries that identity, as with a restored key whose monitor was
    /// unplugged.
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
    /// Empty when no wanted monitor could start a stream.
    Started(Vec<MonitorKey>),
    Failed(PortalError),
}

/// Changes reported when the attached monitors are replaced.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct RosterChange {
    /// Monitors that were not present before, each announced as `lunmonitoradded`.
    pub added: Vec<MonitorKey>,
    /// Monitors that are no longer attached. Their mirrors are already stopped.
    pub removed: Vec<MonitorKey>,
}
