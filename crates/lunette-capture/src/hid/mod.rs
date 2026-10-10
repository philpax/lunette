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
#[cfg(test)]
pub mod recording;
pub mod selection;
pub mod uinput;
pub mod wl_virtual;

use std::path::PathBuf;

use tracing::{info, warn};

pub use crate::hid::{
    dummy::DummyProvider,
    key::{KeyModifiers, PointerButton, VirtualKey, XkbKeymap},
    mapping::{DesktopLayout, MappingError, MonitorMapping, PanelPoint},
    pointer::{DesktopExtent, DesktopPoint, PendingPointer, PointerBatch, WheelDelta},
    selection::{
        NoHostInput, PROVIDER_ORDER, ProviderError, ProviderFailure, ProviderKind, Selected, select,
    },
    uinput::UinputProvider,
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
    /// The host compositor's Wayland socket, or `None` when there is no host
    /// Wayland session.
    pub host_socket: Option<PathBuf>,
    /// The layout `wl_virtual` uploads when it opens, or `None` when the entry
    /// point could not compile one.
    ///
    /// `zwp_virtual_keyboard_v1` disconnects a client that sends a key before a
    /// keymap, so `wl_virtual` does not open without one.
    pub keymap: Option<XkbKeymap>,
}

impl HidConfig {
    /// The configuration `wl_virtual` opens with.
    ///
    /// # Errors
    ///
    /// [`ProviderError::NotConfigured`] naming the first value the entry point
    /// did not supply.
    fn wl_virtual(&self) -> Result<WlVirtualConfig, ProviderError> {
        let socket = self
            .host_socket
            .clone()
            .ok_or(ProviderError::NotConfigured {
                what: "host Wayland socket",
            })?;
        let keymap = self.keymap.clone().ok_or(ProviderError::NotConfigured {
            what: "keyboard layout for the virtual keyboard",
        })?;
        Ok(WlVirtualConfig { socket, keymap })
    }
}

/// The provider in use and the failures recorded while selecting it.
///
/// Owns the provider so a fatal error has one place to be handled.
pub struct HostInput {
    provider: Box<dyn HidProvider>,
    kind: ProviderKind,
    failures: Vec<ProviderFailure>,
    /// The layout the provider was last given.
    ///
    /// Kept because each upload makes the host compositor recompile. `wl_virtual`
    /// starts with the layout it uploaded when it opened.
    keymap: Option<XkbKeymap>,
}

impl HostInput {
    /// Which mechanism is in use.
    #[must_use]
    pub const fn kind(&self) -> ProviderKind {
        self.kind
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

    /// Sends a key press or release, degrading if the provider is gone.
    ///
    /// # Errors
    ///
    /// [`ProviderError`] when the key could not be sent. After a fatal error
    /// the provider is already the dummy.
    pub fn send_key(&mut self, key: VirtualKey, down: bool) -> Result<(), ProviderError> {
        let result = self.provider.send_key(key, down);
        self.degrade_on(result)
    }

    /// Brings the host's held modifiers to `modifiers`, degrading if the
    /// provider is gone.
    ///
    /// # Errors
    ///
    /// [`ProviderError`] when the modifiers could not be set. After a fatal
    /// error the provider is already the dummy.
    pub fn set_modifiers(&mut self, modifiers: KeyModifiers) -> Result<(), ProviderError> {
        let result = self.provider.set_modifiers(modifiers);
        self.degrade_on(result)
    }

    /// Gives the provider a layout, unless it already has that one.
    ///
    /// A failed upload is not remembered, so the next call tries again.
    ///
    /// # Errors
    ///
    /// [`ProviderError`] when the layout could not be uploaded. After a fatal
    /// error the provider is already the dummy.
    pub fn set_keymap(&mut self, keymap: &XkbKeymap) -> Result<(), ProviderError> {
        if self.keymap.as_ref() == Some(keymap) {
            return Ok(());
        }

        let result = self.provider.set_keymap(keymap);
        self.degrade_on(result)?;
        self.keymap = Some(keymap.clone());
        Ok(())
    }

    /// Sends the frame's accumulated input, degrading if the provider is gone.
    ///
    /// A fatal failure replaces the provider with the dummy, so the session
    /// does not report the same disconnection every frame.
    pub fn commit(&mut self) {
        let result = self.provider.commit();
        if let Err(error) = self.degrade_on(result)
            && !error.is_fatal()
        {
            warn!(provider = %self.kind, %error, "host input could not be sent this frame");
        }
    }

    /// Replaces the provider with the dummy when `result` is a fatal failure,
    /// and passes `result` on.
    ///
    /// Degrading on the first fatal failure, not at the next commit, stops
    /// further requests from being written to a connection that has ended.
    fn degrade_on(&mut self, result: Result<(), ProviderError>) -> Result<(), ProviderError> {
        let Err(error) = result else {
            return Ok(());
        };
        if error.is_fatal() {
            warn!(
                provider = %self.kind,
                %error,
                "host input is no longer reachable, so lunette will stop driving the host desktop",
            );
            self.provider = Box::new(DummyProvider);
            self.kind = ProviderKind::Dummy;
            self.keymap = None;
        }
        Err(error)
    }
}

/// Opens the first provider in [`PROVIDER_ORDER`] that works.
///
/// When nothing opens, the dummy does, and [`HostInput::unreachable`] reports
/// that.
#[must_use]
pub fn open(config: &HidConfig) -> HostInput {
    open_with(config, open_one)
}

/// Opens the chain through `opener`, the device and compositor boundary.
fn open_with(
    config: &HidConfig,
    mut opener: impl FnMut(ProviderKind, &HidConfig) -> Result<Box<dyn HidProvider>, ProviderError>,
) -> HostInput {
    let selected = select(
        &PROVIDER_ORDER,
        |kind| opener(kind, config),
        || Box::new(DummyProvider) as Box<dyn HidProvider>,
    );

    for failure in &selected.failures {
        warn!(%failure, "an input provider could not be opened");
        if failure.kind() == ProviderKind::Uinput {
            warn!(
                advice = uinput::ACCESS_ADVICE,
                "uinput is usually a permission"
            );
        }
    }
    info!(provider = %selected.kind, "host input");

    // `wl_virtual` opens only after uploading the configured layout.
    let keymap = match selected.kind {
        ProviderKind::WlVirtual => config.keymap.clone(),
        ProviderKind::Uinput | ProviderKind::Dummy => None,
    };

    HostInput {
        provider: selected.provider,
        kind: selected.kind,
        failures: selected.failures,
        keymap,
    }
}

/// Opens one mechanism, for [`select`].
fn open_one(kind: ProviderKind, config: &HidConfig) -> Result<Box<dyn HidProvider>, ProviderError> {
    match kind {
        ProviderKind::Uinput => {
            UinputProvider::open().map(|provider| Box::new(provider) as Box<dyn HidProvider>)
        }
        ProviderKind::WlVirtual => WlVirtualProvider::open(&config.wl_virtual()?)
            .map(|provider| Box::new(provider) as Box<dyn HidProvider>),
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
        hid::recording::{FailingCall, Failure, HidEvent, Recording},
        monitor::{LogicalGeometry, LogicalPosition, LogicalSize},
    };

    fn layout(name: &str) -> XkbKeymap {
        XkbKeymap::new(format!("xkb_keymap {{ /* {name} */ }};")).expect("a non-empty keymap")
    }

    fn configured(keymap: Option<XkbKeymap>) -> HidConfig {
        HidConfig {
            host_socket: Some(PathBuf::from("/run/user/1000/wayland-1")),
            keymap,
        }
    }

    /// Opens the chain with uinput denied and `wl_virtual` standing in for
    /// the real one: it requires a full configuration and uploads its layout
    /// before reporting itself open, as `WlVirtualProvider::open` does.
    fn open_without_uinput(config: &HidConfig, recording: &Recording) -> HostInput {
        open_with(config, |kind, config| match kind {
            ProviderKind::Uinput => Err(ProviderError::Io {
                operation: "open",
                path: Some(PathBuf::from("/dev/uinput")),
                source: std::io::Error::from_raw_os_error(13),
            }),
            ProviderKind::WlVirtual => {
                let wl_virtual = config.wl_virtual()?;
                let mut provider = recording.provider();
                provider.set_keymap(&wl_virtual.keymap)?;
                Ok(Box::new(provider))
            }
            ProviderKind::Dummy => Ok(Box::new(DummyProvider)),
        })
    }

    fn failing(recording: &Recording, call: FailingCall, fatal: bool) -> HostInput {
        host(
            Box::new(recording.failing_provider(Failure {
                call,
                fatal,
                detail: "broken pipe".to_owned(),
            })),
            ProviderKind::WlVirtual,
        )
    }

    fn host(provider: Box<dyn HidProvider>, kind: ProviderKind) -> HostInput {
        HostInput {
            provider,
            kind,
            failures: Vec::new(),
            keymap: None,
        }
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

        input.provider().mouse_move(DesktopPoint::new(1.0, 1.0));
        input.commit();
        assert_eq!(
            recording.events(),
            vec![HidEvent::Commit],
            "the provider that went away is not called again",
        );
    }

    #[test]
    fn uinput_unavailable_falls_back_to_wl_virtual_with_the_configured_layout() {
        let recording = Recording::new();
        let mut input = open_without_uinput(&configured(Some(layout("us"))), &recording);

        assert_eq!(input.kind(), ProviderKind::WlVirtual);
        assert!(input.unreachable().is_none());

        input.set_keymap(&layout("us")).expect("the layout is set");
        input
            .send_key(VirtualKey::A, true)
            .expect("the key is sent");

        assert_eq!(
            recording.events(),
            vec![
                HidEvent::Keymap(layout("us")),
                HidEvent::Key {
                    key: VirtualKey::A,
                    down: true,
                },
            ],
            "the layout uploaded on open precedes the key, and is not uploaded again",
        );
    }

    #[test]
    fn a_seat_with_another_layout_replaces_the_one_uploaded_on_open() {
        let recording = Recording::new();
        let mut input = open_without_uinput(&configured(Some(layout("us"))), &recording);

        input.set_keymap(&layout("de")).expect("the layout is set");
        input.set_keymap(&layout("de")).expect("the layout is kept");

        assert_eq!(
            recording.events(),
            vec![
                HidEvent::Keymap(layout("us")),
                HidEvent::Keymap(layout("de")),
            ],
        );
    }

    #[test]
    fn wl_virtual_without_a_layout_is_unconfigured_and_both_failures_are_reported() {
        let recording = Recording::new();
        let input = open_without_uinput(&configured(None), &recording);

        assert_eq!(input.kind(), ProviderKind::Dummy);
        assert_eq!(recording.events(), Vec::new());

        let rendered = input
            .unreachable()
            .expect("nothing reached the host")
            .to_string();
        assert!(
            rendered.contains("uinput: could not open /dev/uinput"),
            "{rendered}"
        );
        assert!(
            rendered
                .contains("wl_virtual: no keyboard layout for the virtual keyboard was supplied"),
            "{rendered}",
        );
    }

    #[test]
    fn wl_virtual_without_a_host_socket_names_the_socket() {
        let recording = Recording::new();
        let input = open_without_uinput(
            &HidConfig {
                host_socket: None,
                keymap: Some(layout("us")),
            },
            &recording,
        );

        let rendered = input
            .unreachable()
            .expect("nothing reached the host")
            .to_string();
        assert!(
            rendered.contains("wl_virtual: no host Wayland socket was supplied"),
            "{rendered}",
        );
    }

    #[test]
    fn a_disconnection_while_sending_a_key_degrades_at_once() {
        let recording = Recording::new();
        let mut input = failing(&recording, FailingCall::Key, true);

        let error = input
            .send_key(VirtualKey::A, true)
            .expect_err("the key reports the disconnection");
        assert!(error.is_fatal());
        assert_eq!(input.kind(), ProviderKind::Dummy);

        input
            .send_key(VirtualKey::A, false)
            .expect("the dummy accepts the release");
        input.commit();
        assert_eq!(
            recording.events(),
            vec![HidEvent::Key {
                key: VirtualKey::A,
                down: true,
            }],
            "nothing more is written to the connection that ended",
        );
    }

    #[test]
    fn a_failed_upload_is_not_remembered_and_is_tried_again() {
        let recording = Recording::new();
        let mut input = failing(&recording, FailingCall::Keymap, false);

        input
            .set_keymap(&layout("us"))
            .expect_err("the upload fails");
        assert_eq!(
            input.kind(),
            ProviderKind::WlVirtual,
            "a failed write is not fatal"
        );
        let _ = input.set_keymap(&layout("us"));

        assert_eq!(
            recording.events(),
            vec![
                HidEvent::Keymap(layout("us")),
                HidEvent::Keymap(layout("us")),
            ],
        );
    }

    #[test]
    fn a_disconnection_while_uploading_a_layout_degrades_at_once() {
        let recording = Recording::new();
        let mut input = failing(&recording, FailingCall::Keymap, true);

        input
            .set_keymap(&layout("us"))
            .expect_err("the upload reports the disconnection");

        assert_eq!(input.kind(), ProviderKind::Dummy);
        assert!(
            input.unreachable().is_none(),
            "a provider lost mid-session is logged, not reported as never reached",
        );
    }

    #[test]
    fn a_failed_commit_that_is_not_fatal_keeps_the_provider() {
        let recording = Recording::new();
        let mut input = failing(&recording, FailingCall::Commit, false);

        input.commit();
        input.commit();

        assert_eq!(input.kind(), ProviderKind::WlVirtual);
        assert_eq!(recording.events(), vec![HidEvent::Commit, HidEvent::Commit]);
    }
}
