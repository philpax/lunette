//! A provider that accepts every call without reaching the host desktop.
//!
//! The selection logic installs this type when the chain is exhausted. The
//! per-frame commit installs it when a real provider's connection ends
//! mid-session. Doing nothing keeps a session running on a machine where
//! host input is unavailable. Mirrors still render, panels still respond,
//! and the host cursor does not move.
//!
//! The reason nothing reaches the host is reported once, by
//! [`crate::hid::selection::NoHostInput`]. This type does not report the
//! reason on every call.

use crate::hid::{
    HidProvider,
    key::{KeyModifiers, PointerButton, VirtualKey, XkbKeymap},
    pointer::{DesktopExtent, DesktopPoint, DesktopVector, WheelDelta},
    selection::{ProviderError, ProviderKind},
};

#[derive(Clone, Copy, Debug, Default)]
pub struct DummyProvider;

impl HidProvider for DummyProvider {
    fn kind(&self) -> ProviderKind {
        ProviderKind::Dummy
    }

    fn mouse_move(&mut self, _position: DesktopPoint) {}

    fn mouse_move_rel(&mut self, _delta: DesktopVector) {}

    fn send_button(&mut self, _button: PointerButton, _down: bool) {}

    fn wheel(&mut self, _delta: WheelDelta) {}

    fn set_desktop_extent(&mut self, _extent: DesktopExtent) {}

    fn set_desktop_origin(&mut self, _origin: DesktopPoint) {}

    fn set_modifiers(&mut self, _modifiers: KeyModifiers) -> Result<(), ProviderError> {
        Ok(())
    }

    fn send_key(&mut self, _key: VirtualKey, _down: bool) -> Result<(), ProviderError> {
        Ok(())
    }

    fn set_keymap(&mut self, _keymap: &XkbKeymap) -> Result<(), ProviderError> {
        Ok(())
    }

    fn commit(&mut self) -> Result<(), ProviderError> {
        Ok(())
    }
}
