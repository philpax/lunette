//! A provider that records what it was asked to do.
//!
//! Tests substitute this fake for the [`crate::hid::HidProvider`] trait. The
//! trait is lunette's own. `/dev/uinput` and the host compositor are
//! unmanaged dependencies, so the tests do not mock what they do not own.
//! Nothing here opens a device.

use std::{cell::RefCell, io, rc::Rc};

use crate::hid::{
    HidProvider,
    key::{KeyModifiers, PointerButton, VirtualKey, XkbKeymap},
    pointer::{DesktopExtent, DesktopPoint, WheelDelta},
    selection::{ProviderError, ProviderKind},
};

/// One call a provider received.
///
/// Records the calls, not the bytes a real provider would have written to a
/// device. The calls are the trait's contract. The bytes are each
/// implementation's concern.
#[derive(Clone, Debug, PartialEq)]
pub enum HidEvent {
    MouseMove(DesktopPoint),
    Button {
        button: PointerButton,
        down: bool,
    },
    Wheel(WheelDelta),
    DesktopExtent(DesktopExtent),
    DesktopOrigin(DesktopPoint),
    Modifiers(KeyModifiers),
    Key {
        key: VirtualKey,
        down: bool,
    },
    Keymap(XkbKeymap),
    /// One frame boundary. Everything between two of these is accumulated together.
    Commit,
}

/// The recorded stream, shared with whoever is inspecting it.
///
/// Uses [`Rc`], not [`std::sync::Arc`], because the trait is not `Send`: a
/// provider lives on one thread, and so does its recording.
#[derive(Clone, Debug, Default)]
pub struct Recording(Rc<RefCell<Vec<HidEvent>>>);

impl Recording {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// A provider that appends to this recording.
    #[must_use]
    pub fn provider(&self) -> RecordingProvider {
        RecordingProvider {
            recording: self.clone(),
            failure: None,
        }
    }

    /// A provider whose `commit` reports the host compositor gone.
    ///
    /// This is the failure worth faking. It is the only fatal
    /// [`ProviderError`], and the only one that changes what the owner does
    /// next.
    #[must_use]
    pub fn disconnecting_provider(&self, detail: impl Into<String>) -> RecordingProvider {
        self.failing_provider(Failure {
            call: FailingCall::Commit,
            fatal: true,
            detail: detail.into(),
        })
    }

    /// A provider whose `call` fails as `failure` describes.
    ///
    /// The call is still recorded, because a real provider has already
    /// written its request when the connection reports the failure.
    #[must_use]
    pub fn failing_provider(&self, failure: Failure) -> RecordingProvider {
        RecordingProvider {
            recording: self.clone(),
            failure: Some(failure),
        }
    }

    /// Everything recorded so far.
    #[must_use]
    pub fn events(&self) -> Vec<HidEvent> {
        self.0.borrow().clone()
    }

    fn push(&self, event: HidEvent) {
        self.0.borrow_mut().push(event);
    }
}

/// A call a [`RecordingProvider`] can be made to fail.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FailingCall {
    Commit,
    Key,
    Keymap,
}

/// How a [`RecordingProvider`] fails.
#[derive(Clone, Debug)]
pub struct Failure {
    pub call: FailingCall,
    /// Whether the failure is a disconnection, the only fatal
    /// [`ProviderError`], or a failed write that a later call may survive.
    pub fatal: bool,
    pub detail: String,
}

impl Failure {
    fn error(&self) -> ProviderError {
        if self.fatal {
            ProviderError::Disconnected {
                detail: self.detail.clone(),
            }
        } else {
            ProviderError::Io {
                operation: "write to the fake provider",
                path: None,
                source: io::Error::other(self.detail.clone()),
            }
        }
    }
}

/// A provider that appends every call to a [`Recording`].
pub struct RecordingProvider {
    recording: Recording,
    /// Which call fails and how, or `None` for every call to succeed.
    ///
    /// Held, not returned once, because a fatal error is fatal on every call:
    /// a disconnected compositor does not reconnect itself.
    failure: Option<Failure>,
}

impl RecordingProvider {
    fn outcome(&self, call: FailingCall) -> Result<(), ProviderError> {
        match &self.failure {
            Some(failure) if failure.call == call => Err(failure.error()),
            _ => Ok(()),
        }
    }
}

impl HidProvider for RecordingProvider {
    fn kind(&self) -> ProviderKind {
        // The fake stands in for whichever provider a test exercises.
        // Reporting the dummy would make a test of the chain's outcome pass
        // without the chain producing that outcome. `WlVirtual` is the
        // provider whose fatal `commit` failure this fake mostly drives.
        ProviderKind::WlVirtual
    }

    fn mouse_move(&mut self, position: DesktopPoint) {
        self.recording.push(HidEvent::MouseMove(position));
    }

    fn send_button(&mut self, button: PointerButton, down: bool) {
        self.recording.push(HidEvent::Button { button, down });
    }

    fn wheel(&mut self, delta: WheelDelta) {
        self.recording.push(HidEvent::Wheel(delta));
    }

    fn set_desktop_extent(&mut self, extent: DesktopExtent) {
        self.recording.push(HidEvent::DesktopExtent(extent));
    }

    fn set_desktop_origin(&mut self, origin: DesktopPoint) {
        self.recording.push(HidEvent::DesktopOrigin(origin));
    }

    fn set_modifiers(&mut self, modifiers: KeyModifiers) -> Result<(), ProviderError> {
        self.recording.push(HidEvent::Modifiers(modifiers));
        Ok(())
    }

    fn send_key(&mut self, key: VirtualKey, down: bool) -> Result<(), ProviderError> {
        self.recording.push(HidEvent::Key { key, down });
        self.outcome(FailingCall::Key)
    }

    fn set_keymap(&mut self, keymap: &XkbKeymap) -> Result<(), ProviderError> {
        self.recording.push(HidEvent::Keymap(keymap.clone()));
        self.outcome(FailingCall::Keymap)
    }

    fn commit(&mut self) -> Result<(), ProviderError> {
        self.recording.push(HidEvent::Commit);
        self.outcome(FailingCall::Commit)
    }
}
