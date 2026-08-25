//! Linux-only: `wlx-capture`'s D-Bus ScreenCast client behind lunette's seam.
//!
//! This is the only module in the crate that names a `wlx-capture` portal type.
//! The rest of the crate uses [`crate::portal`] data, so its decision logic is
//! testable without a session bus.
//!
//! # Thread affinity
//!
//! `ScreenCastManager` polls D-Bus futures with a no-op waker on the calling
//! thread, and its futures are not `Send`. `ScreenCastParams.token` is an
//! `Rc<str>`, so this adapter must remain on the thread that drives it.
//!
//! # Unobserved response fields
//!
//! The underlying adapter drops `persist_mode` and `mapping_id`. Grants therefore
//! report [`GrantedPersistMode::Unstated`], and streams have no connector name.
//! Geometry remains sufficient to correlate streams with monitors.

use std::{collections::HashMap, rc::Rc};

use tracing::debug;
use wlx_capture::pipewire::{
    PipewireStream, ScreenCastError, ScreenCastManager, ScreenCastParams, ScreenCastRequestId,
    ScreenCastResponse, ScreenCastResult,
};

use crate::{
    monitor::geometry::{LogicalPosition, LogicalSize},
    portal::{
        CursorPolicy, GrantedPersistMode, NodeId, PersistMode, PortalError, PortalStream,
        RequestId, RequestProgress, RestoreToken, ScreenCastPortal, SessionRequest,
        SessionResponse,
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
    /// Returns an error when the session bus is unavailable, including for a
    /// service or container without a session bus socket.
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
        let params = params_for(&request)?;
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

/// Translates a request into `wlx-capture` parameters.
///
/// The adapter requests monitor sources only and allows multiple streams, so one
/// dialog can list every screen.
fn params_for(request: &SessionRequest) -> Result<ScreenCastParams, PortalError> {
    // The client represents only the shortest and longest persistence modes.
    // Mapping the middle mode to the longest one would overstate the request.
    let persist = match request.persist_mode {
        PersistMode::DoNot => false,
        PersistMode::UntilRevoked => true,
        mode @ PersistMode::WhileRunning => {
            return Err(PortalError::UnsupportedPersistMode(mode));
        }
    };

    Ok(ScreenCastParams {
        token: request
            .restore_token
            .as_ref()
            .map(|token| Rc::from(token.as_str())),
        embed_mouse: matches!(request.cursor, CursorPolicy::Visible),
        screens_only: true,
        persist,
        allow_multiple: true,
    })
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
        size: stream.size.and_then(logical_size),
        connector: None,
    })
}

/// Widens a stream's reported extent, discarding a negative one.
///
/// The portal's `size` is a pair of signed integers and a negative extent
/// describes no rectangle, so it is dropped rather than wrapped into an
/// enormous unsigned one. A stream with no usable size still correlates on its
/// position.
fn logical_size((width, height): (i32, i32)) -> Option<LogicalSize> {
    Some(LogicalSize::new(
        u32::try_from(width).ok()?,
        u32::try_from(height).ok()?,
    ))
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
        // The adapter normally removes a request before this response occurs.
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
        // These options request one dialog for all monitors and exclude lunette's
        // own windows from the selection.
        let params = params_for(&SessionRequest::new(None, CursorPolicy::Hidden))
            .expect("the default request is expressible");

        assert!(params.allow_multiple);
        assert!(params.screens_only);
        assert!(params.persist);
        assert!(!params.embed_mouse);
    }

    #[test]
    fn a_visible_cursor_asks_the_backend_to_supply_one() {
        let params = params_for(&SessionRequest::new(None, CursorPolicy::Visible))
            .expect("the default request is expressible");

        assert!(params.embed_mouse);
    }

    #[test]
    fn a_restore_token_is_carried_into_the_request() {
        let token = RestoreToken::new("stored").expect("a non-empty token");
        let params = params_for(&SessionRequest::new(Some(token), CursorPolicy::Hidden))
            .expect("the default request is expressible");

        assert_eq!(params.token.as_deref(), Some("stored"));
    }

    #[test]
    fn a_persistence_mode_the_client_cannot_express_is_refused_rather_than_rounded_up() {
        let mut request = SessionRequest::new(None, CursorPolicy::Hidden);
        request.persist_mode = PersistMode::WhileRunning;

        assert_eq!(
            params_for(&request).err(),
            Some(PortalError::UnsupportedPersistMode(
                PersistMode::WhileRunning
            )),
        );
    }

    #[test]
    fn a_stream_naming_the_pipewire_core_is_refused_rather_than_connected_to() {
        assert_eq!(
            translate_stream(&stream(0, Some((1920, 1080)))),
            Err(PortalError::UnusableNode { raw: 0 }),
        );
    }

    #[test]
    fn a_negative_extent_leaves_the_stream_matching_on_its_position_alone() {
        let translated = translate_stream(&stream(7, Some((-1, 1080))))
            .expect("a stream with a usable node identifier");

        assert_eq!(translated.size, None);
        assert_eq!(translated.position, Some(LogicalPosition::new(1920, 0)));
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
        // This assertion must change if the client starts exposing `persist_mode`.
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
