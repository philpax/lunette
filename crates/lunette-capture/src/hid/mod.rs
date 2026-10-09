//! Linux-only: reaches the host's keyboard and pointer through `/dev/uinput` or
//! the wlroots virtual-input protocols.
//!
//! Input sent here reaches whatever the host compositor focuses. [`HidProvider`] is not `Send`,
//! because the virtual-input provider keeps its event queue on one thread.

pub mod dummy;
pub mod evdev;
pub mod key;
pub mod mapping;
pub mod pointer;
#[cfg(any(test, feature = "test-fakes"))]
pub mod recording;
pub mod selection;
pub mod uinput;
pub mod wl_virtual;

use tracing::{info, warn};

pub use crate::hid::{
    dummy::DummyProvider,
    key::{KeyModifiers, PointerButton, VirtualKey, XkbKeymap},
    mapping::{DesktopLayout, MappingError, MonitorMapping, PanelPoint},
    pointer::{
        DesktopExtent, DesktopPoint, DesktopVector, PendingPointer, PointerBatch, WheelDelta,
    },
    selection::{
        NoHostInput, ProviderError, ProviderFailure, ProviderKind, ProviderOrder, Selected, select,
    },
    uinput::{UinputConfig, UinputProvider},
    wl_virtual::{WlVirtualConfig, WlVirtualProvider},
};

/// The interface to the host's keyboard and pointer.
///
/// Pointer and button calls accumulate, and [`Self::commit`] flushes once per
/// frame. Implementors accumulate in [`pointer::PendingPointer`] so every
/// provider batches the same way.
pub trait HidProvider {
    /// Which mechanism this is.
    fn kind(&self) -> ProviderKind;

    /// Moves the cursor to a position on the host desktop.
    fn mouse_move(&mut self, position: DesktopPoint);

    /// Moves the cursor by a displacement, clamped to the desktop bounds.
    fn mouse_move_rel(&mut self, delta: DesktopVector);

    fn send_button(&mut self, button: PointerButton, down: bool);

    fn wheel(&mut self, delta: WheelDelta);

    /// Sets the host desktop's bounding box on the provider.
    ///
    /// Nothing is recreated, because uinput spans a fixed normalised range and
    /// `zwlr_virtual_pointer_v1` takes the extent on every call.
    fn set_desktop_extent(&mut self, extent: DesktopExtent);

    /// Sets where the host desktop's bounding box begins.
    ///
    /// A monitor left of the primary one has a negative position, so this is
    /// not always the origin.
    fn set_desktop_origin(&mut self, origin: DesktopPoint);

    /// Brings the host's held modifiers to `modifiers`.
    ///
    /// # Errors
    ///
    /// [`ProviderError`] when the key events this implies could not be sent.
    fn set_modifiers(&mut self, modifiers: KeyModifiers) -> Result<(), ProviderError>;

    /// Sends a key press or release.
    ///
    /// # Errors
    ///
    /// [`ProviderError`] when the event could not be sent.
    fn send_key(&mut self, key: VirtualKey, down: bool) -> Result<(), ProviderError>;

    /// Uploads a keymap to the provider for interpreting keycodes.
    ///
    /// A no-op on uinput, where the display server applies its own layout.
    ///
    /// # Errors
    ///
    /// [`ProviderError`] when the layout could not be uploaded.
    fn set_keymap(&mut self, keymap: &XkbKeymap) -> Result<(), ProviderError>;

    /// Sends what accumulated since the last commit. Called once per frame.
    ///
    /// # Errors
    ///
    /// [`ProviderError`] when the batch could not be sent.
    /// [`ProviderError::is_fatal`] is true for a failure that would repeat
    /// every frame.
    fn commit(&mut self) -> Result<(), ProviderError>;
}

/// Everything the chain needs to try each mechanism.
///
/// The entry point resolves the environment and passes the result here.
#[derive(Clone, Debug, Default)]
pub struct HidConfig {
    pub order: ProviderOrder,
    pub uinput: UinputConfig,
    /// The host compositor and the layout to upload, or `None` when there is no
    /// host Wayland session, which reports [`ProviderError::NotConfigured`].
    pub wl_virtual: Option<WlVirtualConfig>,
}

impl HidConfig {
    /// A configuration that attempts nothing and selects the dummy.
    ///
    /// Distinct from every provider failing, which is reported as a fault.
    #[must_use]
    pub fn disabled() -> Self {
        Self {
            order: ProviderOrder::none(),
            ..Self::default()
        }
    }
}

/// The provider in use and the failures recorded while selecting it.
///
/// Owns the provider so a fatal error has one place to be handled.
pub struct HostInput {
    provider: Box<dyn HidProvider>,
    kind: ProviderKind,
    failures: Vec<ProviderFailure>,
}

impl HostInput {
    /// Which mechanism is in use.
    #[must_use]
    pub const fn kind(&self) -> ProviderKind {
        self.kind
    }

    /// Every mechanism that was tried and failed, in the order they were tried.
    ///
    /// A non-empty list does not imply a fault when a later mechanism worked.
    #[must_use]
    pub fn failures(&self) -> &[ProviderFailure] {
        &self.failures
    }

    /// The error to report when nothing reached the host, or `None`.
    #[must_use]
    pub fn unreachable(&self) -> Option<NoHostInput> {
        (self.kind == ProviderKind::Dummy && !self.failures.is_empty())
            .then(|| NoHostInput::from_failures(self.failures.clone()))
    }

    /// Sets the host desktop's position and size on the provider.
    ///
    /// Called on every output change.
    pub fn set_desktop(&mut self, layout: &DesktopLayout) {
        self.provider.set_desktop_origin(layout.origin());
        self.provider.set_desktop_extent(layout.extent());
    }

    /// The provider, for the calls that only accumulate.
    #[must_use]
    pub fn provider(&mut self) -> &mut dyn HidProvider {
        self.provider.as_mut()
    }

    /// Sends the frame's accumulated input, degrading if the provider is gone.
    ///
    /// A fatal failure replaces the provider with the dummy, so the session
    /// does not report the same disconnection every frame.
    pub fn commit(&mut self) {
        let Err(error) = self.provider.commit() else {
            return;
        };

        if !error.is_fatal() {
            warn!(provider = %self.kind, %error, "host input could not be sent this frame");
            return;
        }

        warn!(
            provider = %self.kind,
            %error,
            "host input is no longer reachable, so lunette will stop driving the host desktop",
        );
        self.provider = Box::new(DummyProvider);
        self.kind = ProviderKind::Dummy;
    }
}

/// Opens the first provider in the configured order that works.
///
/// When nothing opens, the dummy does, and [`HostInput::unreachable`] reports
/// that.
#[must_use]
pub fn open(config: &HidConfig) -> HostInput {
    let selected = select(
        &config.order,
        |kind| open_one(kind, config),
        || Box::new(DummyProvider) as Box<dyn HidProvider>,
    );

    for failure in &selected.failures {
        warn!(%failure, "an input provider could not be opened");
        if failure.kind() == ProviderKind::Uinput {
            warn!(advice = %uinput::Advice { user: None }, "uinput is usually a permission");
        }
    }
    info!(provider = %selected.kind, "host input");

    HostInput {
        provider: selected.provider,
        kind: selected.kind,
        failures: selected.failures,
    }
}

/// Opens one mechanism, for [`select`].
fn open_one(kind: ProviderKind, config: &HidConfig) -> Result<Box<dyn HidProvider>, ProviderError> {
    match kind {
        ProviderKind::Uinput => UinputProvider::open(&config.uinput)
            .map(|provider| Box::new(provider) as Box<dyn HidProvider>),
        ProviderKind::WlVirtual => {
            let wl_virtual = config
                .wl_virtual
                .as_ref()
                .ok_or(ProviderError::NotConfigured {
                    what: "host Wayland socket",
                })?;
            WlVirtualProvider::open(wl_virtual)
                .map(|provider| Box::new(provider) as Box<dyn HidProvider>)
        }
        // Unreachable through `select`, which supplies the dummy itself.
        ProviderKind::Dummy => Ok(Box::new(DummyProvider)),
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
    use crate::{
        hid::recording::{HidEvent, Recording},
        monitor::{LogicalGeometry, LogicalPosition, LogicalSize},
    };

    fn host(provider: Box<dyn HidProvider>, kind: ProviderKind) -> HostInput {
        HostInput {
            provider,
            kind,
            failures: Vec::new(),
        }
    }

    #[test]
    fn a_disabled_configuration_attempts_nothing_and_reports_no_fault() {
        let input = open(&HidConfig::disabled());

        assert_eq!(input.kind(), ProviderKind::Dummy);
        assert!(input.failures().is_empty());
        assert!(input.unreachable().is_none());
    }

    #[test]
    fn a_frames_input_reaches_the_provider() {
        let recording = Recording::new();
        let mut input = host(Box::new(recording.provider()), ProviderKind::WlVirtual);

        input.provider().mouse_move(DesktopPoint::new(4.0, 5.0));
        input.commit();

        assert_eq!(
            recording.events(),
            vec![
                HidEvent::MouseMove(DesktopPoint::new(4.0, 5.0)),
                HidEvent::Commit,
            ],
        );
    }

    #[test]
    fn an_output_change_reaches_the_provider_as_a_new_origin_and_extent() {
        let recording = Recording::new();
        let mut input = host(Box::new(recording.provider()), ProviderKind::WlVirtual);
        let layout = DesktopLayout::new([MonitorMapping::new(LogicalGeometry::new(
            LogicalPosition::new(-1920, 0),
            LogicalSize::new(1920, 1080),
        ))
        .expect("a monitor with an area")])
        .expect("at least one monitor");

        input.set_desktop(&layout);

        assert_eq!(
            recording.events(),
            vec![
                HidEvent::DesktopOrigin(DesktopPoint::new(-1920.0, 0.0)),
                HidEvent::DesktopExtent(
                    DesktopExtent::new(1920.0, 1080.0).expect("a positive extent")
                ),
            ],
        );
    }

    #[test]
    fn a_host_session_ending_degrades_to_the_dummy_rather_than_aborting() {
        let recording = Recording::new();
        let mut input = host(
            Box::new(recording.disconnecting_provider("broken pipe")),
            ProviderKind::WlVirtual,
        );

        input.commit();

        assert_eq!(input.kind(), ProviderKind::Dummy);
    }

    #[test]
    fn a_degraded_session_stops_calling_the_provider_that_went_away() {
        let recording = Recording::new();
        let mut input = host(
            Box::new(recording.disconnecting_provider("broken pipe")),
            ProviderKind::WlVirtual,
        );

        input.commit();
        input.provider().mouse_move(DesktopPoint::new(1.0, 1.0));
        input.commit();

        assert_eq!(recording.events(), vec![HidEvent::Commit]);
    }
}
