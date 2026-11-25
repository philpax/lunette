//! Host input types and Linux providers. On Linux, reaches the host's keyboard and pointer through `/dev/uinput` or
//! the wlroots virtual-input protocols.
//!
//! Input sent here reaches whatever the host compositor focuses. [`HidProvider`] is not `Send`,
//! because the virtual-input provider keeps its event queue on one thread.

#[cfg(target_os = "linux")]
pub mod dummy;
#[cfg(target_os = "linux")]
pub mod evdev;
pub mod key;
pub mod mapping;
pub mod pointer;
#[cfg(all(test, target_os = "linux"))]
pub mod recording;
#[cfg(target_os = "linux")]
pub mod selection;
#[cfg(target_os = "linux")]
pub mod uinput;
#[cfg(target_os = "linux")]
pub mod wl_virtual;

pub use crate::hid::{
    key::{KeyModifiers, PointerButton, VirtualKey, XkbKeymap},
    mapping::{DesktopLayout, MappingError, MonitorMapping, PanelPoint},
    pointer::{DesktopExtent, DesktopPoint, PendingPointer, PointerBatch, WheelDelta},
};

#[cfg(target_os = "linux")]
mod linux;
#[cfg(target_os = "linux")]
pub use linux::*;

#[cfg(target_os = "linux")]
pub use crate::hid::{
    dummy::DummyProvider,
    selection::{
        NoHostInput, PROVIDER_ORDER, ProviderError, ProviderFailure, ProviderKind, Selected, select,
    },
    uinput::UinputProvider,
    wl_virtual::{WlVirtualConfig, WlVirtualProvider},
};
