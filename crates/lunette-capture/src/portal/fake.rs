//! A scripted [`ScreenCastPortal`] for tests.
//!
//! Tests use this implementation of lunette's seam instead of mocking the
//! unmanaged D-Bus service. It opens no bus, spawns no thread, and waits for no
//! external event. A test supplies the portal responses and polls them directly.
//!
//! [`ScreenCastPortal`]: crate::portal::ScreenCastPortal

use std::collections::{HashMap, VecDeque};

use crate::portal::{
    PortalError, RequestId, RequestProgress, ScreenCastPortal, SessionRequest, SessionResponse,
};

/// A portal whose responses come from a queue of scripts.
///
/// Each call to [`ScreenCastPortal::begin`] consumes one script. Each script
/// supplies one response per [`ScreenCastPortal::poll`]. Its last response
/// repeats until it is terminal, and a terminal response is delivered once.
/// An unscripted request remains in [`RequestProgress::AwaitingUser`].
#[derive(Debug, Default)]
pub struct FakePortal {
    scripts: VecDeque<Vec<RequestProgress>>,
    in_flight: HashMap<RequestId, VecDeque<RequestProgress>>,
    /// Requests in the order in which the portal received them.
    pub requests: Vec<SessionRequest>,
    begin_failure: Option<PortalError>,
    next: u64,
}

impl FakePortal {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Queues a session that becomes ready after one user-waiting response.
    pub fn will_grant(&mut self, response: SessionResponse) -> &mut Self {
        self.scripts.push_back(vec![
            RequestProgress::AwaitingUser,
            RequestProgress::Ready(response),
        ]);
        self
    }

    /// Queues a session that returns the supplied failure.
    pub fn will_fail(&mut self, error: PortalError) -> &mut Self {
        self.scripts.push_back(vec![RequestProgress::Failed(error)]);
        self
    }

    /// Makes subsequent [`ScreenCastPortal::begin`] calls return the supplied
    /// error, as they would when the session bus is unreachable.
    pub fn will_refuse_to_begin(&mut self, error: PortalError) -> &mut Self {
        self.begin_failure = Some(error);
        self
    }

    /// Polls until the request reports a terminal state.
    ///
    /// The limit turns a non-terminating test script into a test failure instead
    /// of hanging the test suite.
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

    /// Polls until the request is granted and returns the response.
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

        // Repeating the last response lets a script represent a persistent
        // non-terminal state without choosing an arbitrary number of polls.
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
