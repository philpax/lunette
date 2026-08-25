//! Linux-only: `wlx-capture`'s D-Bus ScreenCast client behind lunette's seam.
//!
//! The only place in this crate that names a `wlx-capture` portal type.
//! Everything above it is written in [`crate::portal`]'s own vocabulary, so the
//! logic that decides anything is testable without a session bus.
//!
//! # Not `Send`, deliberately
//!
//! `ScreenCastManager` polls D-Bus futures with a no-op waker on the calling
//! thread (`pipewire/mod.rs:840`), `DbusFuture` is not `Send` (`mod.rs:632`),
//! and `ScreenCastParams.token` is an `Rc<str>` (`mod.rs:46`). This type is
//! constructed on the thread that will drive it and never leaves it.
//!
//! # What this adapter cannot observe
//!
//! Two fields the portal sends are discarded before they reach here.
//! `parse_start_response` (`pipewire/mod.rs:686-691`) reads `streams` and
//! `restore_token` and drops the response's `persist_mode`, so
//! [`GrantedPersistMode::Unstated`] is what every grant reports. `parse_streams`
//! (`mod.rs:693-733`) reads `node_id`, `position`, and `size` and drops
//! `mapping_id`, so [`PortalStream::connector`] is always `None`. Both are
//! upstream changes, and neither is load-bearing: geometry is the mechanism.

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
    /// When the session bus cannot be reached, which is what a process with no
    /// session — a system service, a container without the bus socket bound —
    /// sees.
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

/// Translates a request into the parameters `wlx-capture` takes.
///
/// `screens_only` and `allow_multiple` are constants rather than fields: a
/// window belongs to lunette's own compositor, and one dialog listing every
/// screen is what removes the prescribed selection order.
fn params_for(request: &SessionRequest) -> Result<ScreenCastParams, PortalError> {
    // `persist` is a bool mapping to 0 or 2, so the middle mode has no
    // representation. Sending 2 for it would ask for a longer-lived grant than
    // the caller wanted.
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
        // Only reachable by polling an identifier `wlx-capture` has already
        // retired, which this adapter's own bookkeeping prevents.
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
        // `allow_multiple` is what removes the prescribed selection order, and
        // `screens_only` keeps lunette's own windows out of the list.
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
        // Stated rather than assumed: the day `parse_start_response` reads
        // `persist_mode`, this test is what says the adapter has to change too.
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
