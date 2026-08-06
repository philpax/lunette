//! A provider that records what it was asked to do.
//!
//! The fake behind the [`crate::hid::HidProvider`] seam. `/dev/uinput` and the
//! host compositor are unmanaged dependencies, so the rule against mocking what
//! one does not own applies: the seam is lunette's own trait, and this is what
//! the tests substitute for it. Nothing here opens a device.
//!
//! Available to the crate's own tests through `cfg(test)`, and to other crates'
//! integration tests through the `test-fakes` feature.

use std::{cell::RefCell, rc::Rc};

use crate::hid::{
    HidProvider,
    key::{KeyModifiers, PointerButton, VirtualKey, XkbKeymap},
    pointer::{DesktopExtent, DesktopPoint, DesktopVector, WheelDelta},
    selection::{ProviderError, ProviderKind},
};

/// One call a provider received.
///
/// Records the calls rather than what a real provider would have written to a
/// device, because the calls are the trait's contract and the bytes are each
/// implementation's business.
#[derive(Clone, Debug, PartialEq)]
pub enum HidEvent {
    MouseMove(DesktopPoint),
    MouseMoveRelative(DesktopVector),
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
    /// One frame boundary. Everything between two of these accumulated together.
    Commit,
}

/// The recorded stream, shared with whoever is inspecting it.
///
/// [`Rc`] rather than [`std::sync::Arc`] because the trait is not `Send`: a
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
            disconnect_on_commit: None,
        }
    }

    /// A provider whose `commit` reports the host compositor gone.
    ///
    /// The one failure worth faking: it is the fatal one, and so the only one
    /// that changes what the owner does next.
    #[must_use]
    pub fn disconnecting_provider(&self, detail: impl Into<String>) -> RecordingProvider {
        RecordingProvider {
            recording: self.clone(),
            disconnect_on_commit: Some(detail.into()),
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

/// A provider that appends every call to a [`Recording`].
pub struct RecordingProvider {
    recording: Recording,
    /// Why `commit` reports the compositor gone, or `None` to succeed.
    ///
    /// Held rather than returned once, because a fatal error is fatal on every
    /// call: a disconnected compositor does not reconnect itself.
    disconnect_on_commit: Option<String>,
}

impl HidProvider for RecordingProvider {
    fn kind(&self) -> ProviderKind {
        // The fake stands in for whichever provider a test is exercising, and
        // reporting the dummy would make a test of the chain's outcome pass for
        // the wrong reason. `WlVirtual` is the one with a fallible `commit`,
        // which is what this fake is mostly used to drive.
        ProviderKind::WlVirtual
    }

    fn mouse_move(&mut self, position: DesktopPoint) {
        self.recording.push(HidEvent::MouseMove(position));
    }

    fn mouse_move_rel(&mut self, delta: DesktopVector) {
        self.recording.push(HidEvent::MouseMoveRelative(delta));
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
        Ok(())
    }

    fn set_keymap(&mut self, keymap: &XkbKeymap) -> Result<(), ProviderError> {
        self.recording.push(HidEvent::Keymap(keymap.clone()));
        Ok(())
    }

    fn commit(&mut self) -> Result<(), ProviderError> {
        self.recording.push(HidEvent::Commit);
        match &self.disconnect_on_commit {
            Some(detail) => Err(ProviderError::Disconnected {
                detail: detail.clone(),
            }),
            None => Ok(()),
        }
    }
}
