//! Linux-only: `wlx-capture`'s D-Bus ScreenCast client behind lunette's seam.
//!
//! The only place in this crate that names a `wlx-capture` portal type.
//! Everything above it is written in [`crate::portal`]'s own vocabulary, so
//! the decision logic is testable without a session bus.
//!
//! # Thread affinity
//!
//! `ScreenCastManager` polls D-Bus futures with a no-op waker on the calling
//! thread (`pipewire/mod.rs:840`). `DbusFuture` is not `Send` (`mod.rs:632`).
//! `ScreenCastParams.token` is an `Rc<str>` (`mod.rs:46`). `WlxPortal` is
//! constructed on the thread that drives it and never leaves it.
//!
//! # Fields `wlx-capture` discards
//!
//! Two fields the portal sends are discarded before they reach this adapter.
//! `parse_start_response` reads `streams` and `restore_token` and drops the
//! response's `persist_mode` (`pipewire/mod.rs:686-691`), so every grant
//! reports [`GrantedPersistMode::Unstated`]. `parse_streams` reads `node_id`,
//! `position`, and `size` and drops `mapping_id` (`mod.rs:693-733`). Both
//! drops happen in upstream `wlx-capture`. Neither is load-bearing: the
//! stream's position is the mechanism, and lunette reads neither.

use std::{collections::HashMap, rc::Rc};

use tracing::debug;
use wlx_capture::pipewire::{
    PipewireStream, ScreenCastError, ScreenCastManager, ScreenCastParams, ScreenCastRequestId,
    ScreenCastResponse, ScreenCastResult,
};

use crate::{
    monitor::geometry::LogicalPosition,
    portal::{
        CursorPolicy, GrantedPersistMode, NodeId, PortalError, PortalStream, RequestId,
        RequestProgress, RestoreToken, ScreenCastPortal, SessionRequest, SessionResponse,
    },
};

/// The production portal: `wlx-capture`'s ScreenCast client.
pub struct WlxPortal {
    manager: ScreenCastManager,
    in_flight: HashMap<RequestId, ScreenCastRequestId>,
    next: u64,
}

impl WlxPortal {
    /// Connects to the session bus.
    ///
    /// # Errors
    ///
    /// Connecting fails when the session bus cannot be reached. A process with
    /// no session sees this error: a system service, or a container without
    /// the bus socket bound.
    pub fn connect() -> Result<Self, PortalError> {
        Ok(Self {
            manager: ScreenCastManager::new().map_err(translate_error)?,
            in_flight: HashMap::new(),
            next: 0,
        })
    }
}

impl ScreenCastPortal for WlxPortal {
    fn begin(&mut self, request: SessionRequest) -> Result<RequestId, PortalError> {
        let params = params_for(&request);
        let inner = self.manager.request(params).map_err(translate_error)?;

        self.next += 1;
        let id = RequestId::from_raw(self.next);
        self.in_flight.insert(id, inner);

        debug!(%id, restoring = request.restore_token.is_some(), "asked the portal for a session");
        Ok(id)
    }

    fn poll(&mut self, request: RequestId) -> RequestProgress {
        let Some(inner) = self.in_flight.get(&request).copied() else {
            return RequestProgress::Failed(PortalError::UnknownRequest(request));
        };

        let progress = match self.manager.check(&inner) {
            ScreenCastResult::Queued => RequestProgress::Queued,
            ScreenCastResult::Pending => RequestProgress::Negotiating,
            ScreenCastResult::WaitingForUser => RequestProgress::AwaitingUser,
            ScreenCastResult::Ok(response) => match translate_response(response) {
                Ok(response) => RequestProgress::Ready(response),
                Err(error) => RequestProgress::Failed(error),
            },
            ScreenCastResult::Failed(error) => RequestProgress::Failed(translate_error(error)),
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

/// Translates a request into the parameters `wlx-capture` takes.
///
/// `screens_only` and `allow_multiple` are constants. A window belongs to
/// lunette's own compositor. One dialog listing every screen removes the
/// prescribed selection order. `persist` is true because every request asks
/// for a session that lasts until revoked; `wlx-capture` encodes it as
/// `persist_mode` 2.
fn params_for(request: &SessionRequest) -> ScreenCastParams {
    ScreenCastParams {
        token: request
            .restore_token
            .as_ref()
            .map(|token| Rc::from(token.as_str())),
        embed_mouse: matches!(request.cursor, CursorPolicy::Visible),
        screens_only: true,
        persist: true,
        allow_multiple: true,
    }
}

fn translate_response(response: ScreenCastResponse) -> Result<SessionResponse, PortalError> {
    Ok(SessionResponse {
        streams: response
            .streams
            .iter()
            .map(translate_stream)
            .collect::<Result<Vec<_>, _>>()?,
        restore_token: response.restore_token.and_then(RestoreToken::new),
        granted_persist_mode: GrantedPersistMode::Unstated,
    })
}

fn translate_stream(stream: &PipewireStream) -> Result<PortalStream, PortalError> {
    Ok(PortalStream {
        node: NodeId::new(stream.node_id).ok_or(PortalError::UnusableNode {
            raw: stream.node_id,
        })?,
        position: stream.position.map(|(x, y)| LogicalPosition::new(x, y)),
    })
}

fn translate_error(error: ScreenCastError) -> PortalError {
    match error {
        ScreenCastError::PortalResponse(code) => PortalError::Refused { code },
        ScreenCastError::UnsupportedSourceTypes { available, .. } => {
            PortalError::NoMonitorSources { available }
        }
        ScreenCastError::UnsupportedCursorMode { available } => {
            PortalError::NoCursorMode { available }
        }
        ScreenCastError::MissingField(field) => PortalError::Malformed(field),
        ScreenCastError::InvalidResponse(what) => PortalError::Malformed(what),
        error @ (ScreenCastError::Dbus(_)
        | ScreenCastError::DbusDisconnected
        | ScreenCastError::InvalidObjectPath(_)) => PortalError::Dbus(error.to_string()),
        // Only reachable by polling an identifier `wlx-capture` has already
        // retired. This adapter's own bookkeeping prevents that.
        ScreenCastError::UnknownRequest => {
            PortalError::Dbus("the portal client lost track of the request".to_owned())
        }
    }
}

#[cfg(test)]
#[expect(
    clippy::expect_used,
    reason = "a failed expectation is how a test reports a failure; the ban is on production code"
)]
mod tests {
    use pretty_assertions::assert_eq;

    use super::*;

    fn stream(node_id: u32, size: Option<(i32, i32)>) -> PipewireStream {
        PipewireStream {
            node_id,
            position: Some((1920, 0)),
            size,
        }
    }

    #[test]
    fn a_session_is_always_asked_for_every_screen_in_one_dialog() {
        // `allow_multiple` removes the prescribed selection order. `screens_only`
        // keeps lunette's own windows out of the list.
        let params = params_for(&SessionRequest::new(None, CursorPolicy::Hidden));

        assert!(params.allow_multiple);
        assert!(params.screens_only);
        assert!(params.persist);
        assert!(!params.embed_mouse);
    }

    #[test]
    fn a_visible_cursor_asks_the_backend_to_supply_one() {
        let params = params_for(&SessionRequest::new(None, CursorPolicy::Visible));

        assert!(params.embed_mouse);
    }

    #[test]
    fn a_restore_token_is_carried_into_the_request() {
        let token = RestoreToken::new("stored").expect("a non-empty token");
        let params = params_for(&SessionRequest::new(Some(token), CursorPolicy::Hidden));

        assert_eq!(params.token.as_deref(), Some("stored"));
    }

    #[test]
    fn a_stream_naming_the_pipewire_core_is_refused_rather_than_connected_to() {
        assert_eq!(
            translate_stream(&stream(0, Some((1920, 1080)))),
            Err(PortalError::UnusableNode { raw: 0 }),
        );
    }

    #[test]
    fn an_empty_restore_token_is_not_stored_as_though_it_were_one() {
        let translated = translate_response(ScreenCastResponse {
            streams: vec![stream(7, Some((1920, 1080)))],
            restore_token: Some(String::new()),
        })
        .expect("a response with a usable stream");

        assert_eq!(translated.restore_token, None);
    }

    #[test]
    fn this_client_never_observes_what_persistence_the_backend_granted() {
        // `parse_start_response` drops `persist_mode`, so the adapter always
        // reports `GrantedPersistMode::Unstated`. When upstream reads
        // `persist_mode`, the assertion fails and the adapter has to change
        // too.
        let translated = translate_response(ScreenCastResponse {
            streams: vec![stream(7, Some((1920, 1080)))],
            restore_token: Some("fresh".to_owned()),
        })
        .expect("a response with a usable stream");

        assert_eq!(
            translated.granted_persist_mode,
            GrantedPersistMode::Unstated
        );
    }
}
