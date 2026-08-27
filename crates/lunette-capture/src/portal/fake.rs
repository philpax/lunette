//! A scripted [`ScreenCastPortal`] for tests.
//!
//! The portal is an unmanaged dependency, so the tests substitute an
//! implementation of lunette's own seam and do not mock D-Bus. Nothing here
//! opens a bus, spawns a thread, or waits. A test states what the portal will
//! answer and then polls, so a session that takes a user several seconds to
//! approve takes a test one call.
//!
//! [`ScreenCastPortal`]: crate::portal::ScreenCastPortal

use std::collections::{HashMap, VecDeque};

use crate::portal::{
    PortalError, RequestId, RequestProgress, ScreenCastPortal, SessionRequest, SessionResponse,
};

/// A portal that answers from a script.
///
/// Each call to [`ScreenCastPortal::begin`] takes the next script in the queue.
/// A script is a list of progressions, one per [`ScreenCastPortal::poll`]; the
/// last one repeats until it is terminal, and a terminal one is delivered once.
///
/// A request made when no script is left answers
/// [`RequestProgress::AwaitingUser`] until the portal is dropped. That progress
/// stands in for a dialog that nobody clicks, so the test ends without a
/// timeout when the session never reaches a terminal progress.
#[derive(Debug, Default)]
pub struct FakePortal {
    scripts: VecDeque<Vec<RequestProgress>>,
    in_flight: HashMap<RequestId, VecDeque<RequestProgress>>,
    /// Every request made, in order. A test reads this to assert on what was
    /// asked for.
    pub requests: Vec<SessionRequest>,
    begin_failure: Option<PortalError>,
    next: u64,
}

impl FakePortal {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Queues a session that succeeds after one poll spent awaiting the user.
    pub fn will_grant(&mut self, response: SessionResponse) -> &mut Self {
        self.scripts.push_back(vec![
            RequestProgress::AwaitingUser,
            RequestProgress::Ready(response),
        ]);
        self
    }

    /// Queues a session that fails.
    pub fn will_fail(&mut self, error: PortalError) -> &mut Self {
        self.scripts.push_back(vec![RequestProgress::Failed(error)]);
        self
    }

    /// Makes every subsequent [`ScreenCastPortal::begin`] fail outright, as a
    /// portal that cannot be reached on the session bus does.
    pub fn will_refuse_to_begin(&mut self, error: PortalError) -> &mut Self {
        self.begin_failure = Some(error);
        self
    }

    /// Polls until the request reports a terminal progress.
    ///
    /// Bounded. A script that never terminates is a defect in the test, so the
    /// method panics and the suite does not hang.
    #[must_use]
    pub fn drive(&mut self, request: RequestId) -> RequestProgress {
        for _ in 0..16 {
            let progress = self.poll(request);
            if matches!(
                progress,
                RequestProgress::Ready(_) | RequestProgress::Failed(_)
            ) {
                return progress;
            }
        }
        panic!("the scripted portal never reached a terminal progress");
    }

    /// Polls until the request is granted, and returns what it granted.
    #[must_use]
    pub fn grant(&mut self, request: RequestId) -> SessionResponse {
        match self.drive(request) {
            RequestProgress::Ready(response) => response,
            other => panic!("the scripted portal answered {other:?} rather than granting"),
        }
    }
}

impl ScreenCastPortal for FakePortal {
    fn begin(&mut self, request: SessionRequest) -> Result<RequestId, PortalError> {
        if let Some(error) = &self.begin_failure {
            return Err(error.clone());
        }

        self.requests.push(request);
        self.next += 1;
        let id = RequestId::from_raw(self.next);

        let script = self
            .scripts
            .pop_front()
            .unwrap_or_else(|| vec![RequestProgress::AwaitingUser]);
        self.in_flight.insert(id, script.into());

        Ok(id)
    }

    fn poll(&mut self, request: RequestId) -> RequestProgress {
        let Some(script) = self.in_flight.get_mut(&request) else {
            return RequestProgress::Failed(PortalError::UnknownRequest(request));
        };

        // The last entry repeats and is never consumed, so a script says
        // "and then it stays like that" without counting how many times.
        let progress = if script.len() > 1 {
            script.pop_front()
        } else {
            script.front().cloned()
        };
        let Some(progress) = progress else {
            return RequestProgress::Failed(PortalError::UnknownRequest(request));
        };

        if matches!(
            progress,
            RequestProgress::Ready(_) | RequestProgress::Failed(_)
        ) {
            self.in_flight.remove(&request);
        }

        progress
    }
}
