//! What the client learned from the compositor, and the handlers that learn it.
//!
//! [`TestClient`](crate::test_client::TestClient) sends; this receives. Every
//! `Dispatch` implementation lands here, each one recording what arrived rather
//! than reacting to it, so a test asserts over the record afterwards instead of
//! racing the event that produced it.
//!
//! Events are kept in the order they arrived and against the object they
//! reached, not collapsed to a latest value. Two seats mean two pointers, and
//! an event that does not say which pointer it reached says nothing about
//! routing; the same goes for two outputs and two surfaces.

use std::{
    io::{Read, Seek, SeekFrom},
    os::fd::OwnedFd,
};

use wayland_client::{
    Connection, Dispatch, Proxy, QueueHandle,
    backend::ObjectId,
    delegate_noop,
    protocol::{
        wl_buffer::{self, WlBuffer},
        wl_callback::{self, WlCallback},
        wl_compositor::WlCompositor,
        wl_data_offer::WlDataOffer,
        wl_keyboard::{self, KeyState, WlKeyboard},
        wl_output::{self, WlOutput},
        wl_pointer::{self, ButtonState, WlPointer},
        wl_region::WlRegion,
        wl_registry::{self, WlRegistry},
        wl_seat::{self, Capability, WlSeat},
        wl_shm::WlShm,
        wl_shm_pool::WlShmPool,
        wl_subcompositor::WlSubcompositor,
        wl_subsurface::WlSubsurface,
        wl_surface::{self, WlSurface},
    },
};
use wayland_protocols::{
    wp::{
        content_type::v1::client::{
            wp_content_type_manager_v1::WpContentTypeManagerV1, wp_content_type_v1::WpContentTypeV1,
        },
        fractional_scale::v1::client::{
            wp_fractional_scale_manager_v1::WpFractionalScaleManagerV1,
            wp_fractional_scale_v1::{self, WpFractionalScaleV1},
        },
        linux_dmabuf::zv1::client::{
            zwp_linux_buffer_params_v1::ZwpLinuxBufferParamsV1,
            zwp_linux_dmabuf_v1::ZwpLinuxDmabufV1,
        },
        primary_selection::zv1::client::zwp_primary_selection_offer_v1::ZwpPrimarySelectionOfferV1,
    },
    xdg::shell::client::{
        xdg_popup::XdgPopup,
        xdg_positioner::XdgPositioner,
        xdg_surface::{self, XdgSurface},
        xdg_toplevel::{self, XdgToplevel},
        xdg_wm_base::{self, XdgWmBase},
    },
};

use crate::protocol::ScrollAxis;

/// What the client learned from the compositor.
#[derive(Debug, Default)]
pub struct Driver {
    pub globals: Vec<Global>,
    pub(super) registry: Option<WlRegistry>,
    /// The serial each `xdg_surface` was last configured with. Keyed, because a
    /// popup has its own `xdg_surface` and acknowledging the wrong one is a
    /// protocol error.
    configures: Vec<(ObjectId, u32)>,
    /// Every configure serial the compositor ever sent, in order. Kept apart
    /// from `configures` because that one keeps only the latest per surface,
    /// and the property worth asserting — that no two events anywhere share a
    /// serial — needs all of them.
    configure_serials: Vec<u32>,
    pub toplevel_size: Option<(i32, i32)>,
    pub closed: bool,
    /// Every seat the client has bound, in the order it bound them.
    seats: Vec<SeatRecord>,
    /// Every pointer event delivered, in order, against the pointer it was
    /// delivered to. Two seats mean two pointers, and an event that does not
    /// say which one it reached says nothing about routing.
    pointer: Vec<(ObjectId, PointerEvent)>,
    /// Every keyboard event delivered, in order, against the keyboard it was
    /// delivered to. Two seats mean two keyboards, for the reason they mean two
    /// pointers.
    keyboard: Vec<(ObjectId, KeyboardEvent)>,
    /// Every buffer the compositor released, in order. A client may reuse a
    /// buffer only once it appears here.
    pub released: Vec<ObjectId>,
    /// What each bound `wl_output` reported, by output object. Applied at
    /// `done`, because the properties arrive as separate events and a test
    /// reading between two of them would see half a configuration.
    outputs: Vec<(ObjectId, OutputRecord)>,
    /// Which outputs each surface was told it is on, by surface. Kept as a list
    /// rather than a set so that a duplicate enter is visible rather than
    /// absorbed.
    surface_outputs: Vec<(ObjectId, Vec<ObjectId>)>,
    /// Every `wl_surface.preferred_buffer_scale` a surface was sent, in order.
    /// In order rather than latest-only, because the protocol sends one only
    /// when the value changes and a test asserting that needs to count them.
    surface_buffer_scales: Vec<(ObjectId, Vec<i32>)>,
    /// Every `wp_fractional_scale_v1.preferred_scale` an object was sent, in
    /// 120ths, in order. Kept whole for the reason the buffer scales are.
    fractional_scales: Vec<(ObjectId, Vec<u32>)>,
    /// The timestamp of every `wl_callback.done` answering a frame request, by
    /// the surface it was asked for. A count rather than a flag, because
    /// withholding is about how many arrive and when, not whether any did.
    frames: Vec<(ObjectId, Vec<u32>)>,

    // The selection half, in `selection.rs`. The fields live here because that
    // is where the struct is, and everything that reads them is in the submodule.
    /// The MIME types each selection offer advertised, by offer object.
    pub(super) offers: Vec<(ObjectId, Vec<String>)>,
    /// The clipboard offer each data device was last given, by device. Keyed
    /// because two seats mean two devices, and a selection that does not say
    /// which one it reached says nothing about the bridge.
    pub(super) clipboard: Vec<(ObjectId, Option<WlDataOffer>)>,
    /// The primary-selection offer each device was last given, keyed for the
    /// reason the clipboard is.
    pub(super) primary: Vec<(ObjectId, Option<ZwpPrimarySelectionOfferV1>)>,
    /// Requests the compositor made of this client's own sources, each with the
    /// descriptor to write into.
    pub(super) sends: Vec<(String, OwnedFd)>,
    /// Whether one of this client's sources was cancelled.
    pub(super) cancelled: bool,
}

impl Driver {
    /// The timestamp of every frame callback a surface has been answered, in
    /// order.
    ///
    /// Empty for a surface that asked for none, and for one whose requests are
    /// being withheld — which is the case a pacing test is about, so it is an
    /// answer rather than an absence.
    #[must_use]
    pub fn frames(&self, surface: &ObjectId) -> &[u32] {
        self.frames
            .iter()
            .find(|(held, _)| held == surface)
            .map_or(&[], |(_, stamps)| stamps.as_slice())
    }

    /// The serial an `xdg_surface` was last configured with.
    #[must_use]
    pub fn configure_serial(&self, xdg_surface: &XdgSurface) -> Option<u32> {
        let id = xdg_surface.id();
        self.configures
            .iter()
            .find(|(target, _)| *target == id)
            .map(|(_, serial)| *serial)
    }

    /// Every configure serial the compositor has sent, in order.
    #[must_use]
    pub fn configure_serials(&self) -> Vec<u32> {
        self.configure_serials.clone()
    }

    /// What an output reported, as of its latest `done`.
    ///
    /// Absent until the first `done`, so a caller never reads a configuration
    /// the compositor is half-way through sending.
    #[must_use]
    pub fn output(&self, output: &WlOutput) -> Option<OutputState> {
        let id = output.id();
        self.outputs
            .iter()
            .find(|(target, _)| *target == id)
            .and_then(|(_, record)| record.current.clone())
    }

    /// Which outputs a surface has been told it is on, in the order it was told.
    ///
    /// Keyed by object identifier rather than by the proxy, because a test that
    /// opened a toplevel through [`TestClient::open_toplevel`] holds the
    /// identifier and not the surface.
    #[must_use]
    pub fn surface_outputs(&self, surface: &ObjectId) -> Vec<ObjectId> {
        self.surface_outputs
            .iter()
            .find(|(target, _)| target == surface)
            .map_or_else(Vec::new, |(_, outputs)| outputs.clone())
    }

    /// Every `preferred_buffer_scale` a surface has been sent, in order.
    #[must_use]
    pub fn buffer_scales(&self, surface: &ObjectId) -> Vec<i32> {
        self.surface_buffer_scales
            .iter()
            .find(|(target, _)| target == surface)
            .map_or_else(Vec::new, |(_, scales)| scales.clone())
    }

    /// Every `preferred_scale` a `wp_fractional_scale_v1` has been sent, in
    /// 120ths, in order.
    #[must_use]
    pub fn preferred_scales(&self, scale: &WpFractionalScaleV1) -> Vec<u32> {
        let id = scale.id();
        self.fractional_scales
            .iter()
            .find(|(target, _)| *target == id)
            .map_or_else(Vec::new, |(_, scales)| scales.clone())
    }

    /// The name a seat advertised on `wl_seat.name`, once it has.
    #[must_use]
    pub fn seat_name(&self, seat: &WlSeat) -> Option<String> {
        self.seat(seat).and_then(|record| record.name.clone())
    }

    /// Every seat name the client has seen, for a failure message.
    #[must_use]
    pub fn seat_names(&self) -> Vec<String> {
        self.seats
            .iter()
            .filter_map(|record| record.name.clone())
            .collect()
    }

    /// Whether a seat has advertised a pointer capability.
    #[must_use]
    pub fn has_pointer(&self, seat: &WlSeat) -> bool {
        self.seat(seat).is_some_and(|record| record.has_pointer)
    }

    /// Whether a seat has advertised a keyboard capability.
    #[must_use]
    pub fn has_keyboard(&self, seat: &WlSeat) -> bool {
        self.seat(seat).is_some_and(|record| record.has_keyboard)
    }

    /// Every event delivered to one keyboard, in order.
    #[must_use]
    pub fn keyboard_events(&self, keyboard: &WlKeyboard) -> Vec<KeyboardEvent> {
        let id = keyboard.id();
        self.keyboard
            .iter()
            .filter(|(target, _)| *target == id)
            .map(|(_, event)| event.clone())
            .collect()
    }

    /// Every key press and release delivered to one keyboard, in order.
    #[must_use]
    pub fn keys(&self, keyboard: &WlKeyboard) -> Vec<(u32, bool)> {
        self.keyboard_events(keyboard)
            .into_iter()
            .filter_map(|event| match event {
                KeyboardEvent::Key { key, pressed } => Some((key, pressed)),
                _ => None,
            })
            .collect()
    }

    /// The last modifier masks the compositor told one keyboard about.
    #[must_use]
    pub fn modifiers(&self, keyboard: &WlKeyboard) -> Option<(u32, u32)> {
        self.keyboard_events(keyboard)
            .into_iter()
            .rev()
            .find_map(|event| match event {
                KeyboardEvent::Modifiers { depressed, locked } => Some((depressed, locked)),
                _ => None,
            })
    }

    /// Every keymap the compositor uploaded to one keyboard, in order.
    ///
    /// The text as the client would read it, so a test can assert that a
    /// keymap was restored to exactly what it was before.
    #[must_use]
    pub fn keymaps(&self, keyboard: &WlKeyboard) -> Vec<String> {
        self.keyboard_events(keyboard)
            .into_iter()
            .filter_map(|event| match event {
                KeyboardEvent::Keymap { text } => Some(text),
                _ => None,
            })
            .collect()
    }

    /// Whether one keyboard currently holds focus on a surface.
    #[must_use]
    pub fn keyboard_focus(&self, keyboard: &WlKeyboard) -> Option<ObjectId> {
        self.keyboard_events(keyboard)
            .into_iter()
            .rev()
            .find_map(|event| match event {
                KeyboardEvent::Enter { surface } => Some(Some(surface)),
                KeyboardEvent::Leave { .. } => Some(None),
                _ => None,
            })
            .flatten()
    }

    /// Every event delivered to one pointer, in order.
    #[must_use]
    pub fn events(&self, pointer: &WlPointer) -> Vec<PointerEvent> {
        let id = pointer.id();
        self.pointer
            .iter()
            .filter(|(target, _)| *target == id)
            .map(|(_, event)| event.clone())
            .collect()
    }

    /// The first pointer enter delivered to one pointer, if one arrived.
    #[must_use]
    pub fn first_enter(&self, pointer: &WlPointer) -> Option<(ObjectId, f64, f64)> {
        self.events(pointer)
            .into_iter()
            .find_map(|event| match event {
                PointerEvent::Enter { surface, x, y, .. } => Some((surface, x, y)),
                _ => None,
            })
    }

    /// The serial of the last enter delivered to one pointer, which is what a
    /// `set_cursor` request has to carry.
    #[must_use]
    pub fn enter_serial(&self, pointer: &WlPointer) -> Option<u32> {
        self.events(pointer)
            .into_iter()
            .rev()
            .find_map(|event| match event {
                PointerEvent::Enter { serial, .. } => Some(serial),
                _ => None,
            })
    }

    /// Every button press and release delivered to one pointer, in order.
    #[must_use]
    pub fn buttons(&self, pointer: &WlPointer) -> Vec<(u32, bool)> {
        self.events(pointer)
            .into_iter()
            .filter_map(|event| match event {
                PointerEvent::Button { button, pressed } => Some((button, pressed)),
                _ => None,
            })
            .collect()
    }

    fn seat(&self, seat: &WlSeat) -> Option<&SeatRecord> {
        let id = seat.id();
        self.seats.iter().find(|record| record.seat == id)
    }

    fn seat_mut(&mut self, seat: &WlSeat) -> &mut SeatRecord {
        let id = seat.id();
        if let Some(index) = self.seats.iter().position(|record| record.seat == id) {
            return &mut self.seats[index];
        }
        self.seats.push(SeatRecord {
            seat: id,
            name: None,
            has_pointer: false,
            has_keyboard: false,
        });
        self.seats
            .last_mut()
            .unwrap_or_else(|| unreachable!("the record was just pushed"))
    }
}

/// What one bound `wl_output` has told the client about itself.
///
/// Two halves, because the protocol sends the properties as separate events and
/// applies them at `done`. A test reading `current` never sees a configuration
/// the compositor is part-way through sending.
#[derive(Debug, Default)]
struct OutputRecord {
    pending: OutputState,
    current: Option<OutputState>,
}

/// One output's configuration, as the client was told it.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct OutputState {
    /// The current mode's resolution, in pixels.
    pub size: (i32, i32),
    /// The current mode's refresh rate, in millihertz, which is the unit
    /// `wl_output.mode` carries.
    pub refresh: i32,
    /// The physical size in millimetres, from `wl_output.geometry`.
    pub physical: (i32, i32),
    /// The integer scale, which is one until the compositor says otherwise.
    pub scale: i32,
    /// The name, present only from version 4.
    pub name: Option<String>,
    pub description: Option<String>,
}

/// What one bound seat has told the client about itself.
#[derive(Debug)]
struct SeatRecord {
    seat: ObjectId,
    name: Option<String>,
    has_pointer: bool,
    has_keyboard: bool,
}

/// One entry from the registry.
#[derive(Clone, Debug)]
pub struct Global {
    pub name: u32,
    pub interface: String,
    pub version: u32,
}

/// A pointer event as the client received it.
///
/// Coordinates are surface-local, which is the whole point of asserting on
/// them: the compositor is what translates a sink-relative position into the
/// surface's own frame.
#[derive(Clone, Debug, PartialEq)]
pub enum PointerEvent {
    Enter {
        surface: ObjectId,
        x: f64,
        y: f64,
        /// What a `set_cursor` request has to quote back.
        serial: u32,
    },
    Motion {
        x: f64,
        y: f64,
    },
    Button {
        button: u32,
        pressed: bool,
    },
    Leave {
        surface: ObjectId,
    },
    /// `wl_pointer.axis_source`. Recorded as the protocol's own enum, because
    /// what a client does with a scroll turns on whether it came from a notched
    /// wheel or a continuous surface.
    AxisSource {
        source: wl_pointer::AxisSource,
    },
    /// `wl_pointer.axis`, the one axis event every version receives.
    Axis {
        axis: ScrollAxis,
        value: f64,
    },
    /// `wl_pointer.axis_discrete`, which smithay synthesises from the v120
    /// count for a client older than version 8.
    AxisDiscrete {
        axis: ScrollAxis,
        steps: i32,
    },
}

/// The axis a `wl_pointer` axis event named, or nothing for one from a protocol
/// version this client does not know.
fn scroll_axis(axis: wayland_client::WEnum<wl_pointer::Axis>) -> Option<ScrollAxis> {
    match axis {
        wayland_client::WEnum::Value(wl_pointer::Axis::VerticalScroll) => {
            Some(ScrollAxis::Vertical)
        }
        wayland_client::WEnum::Value(wl_pointer::Axis::HorizontalScroll) => {
            Some(ScrollAxis::Horizontal)
        }
        _ => None,
    }
}

impl Dispatch<WlRegistry, ()> for Driver {
    fn event(
        state: &mut Self,
        registry: &WlRegistry,
        event: wl_registry::Event,
        (): &(),
        _connection: &Connection,
        _handle: &QueueHandle<Self>,
    ) {
        state.registry = Some(registry.clone());
        match event {
            wl_registry::Event::Global {
                name,
                interface,
                version,
            } => state.globals.push(Global {
                name,
                interface,
                version,
            }),
            wl_registry::Event::GlobalRemove { name } => {
                state.globals.retain(|global| global.name != name);
            }
            _ => {}
        }
    }
}

/// `wl_surface.enter` and `wl_surface.leave` are what a client learns its
/// output from, and `preferred_buffer_scale` is what it learns the whole-number
/// scale from, so the surface cannot be a no-op the way the rest of its events
/// are.
impl Dispatch<WlSurface, ()> for Driver {
    fn event(
        state: &mut Self,
        surface: &WlSurface,
        event: wl_surface::Event,
        (): &(),
        _connection: &Connection,
        _handle: &QueueHandle<Self>,
    ) {
        let id = surface.id();

        match event {
            wl_surface::Event::Enter { output } => {
                entry_for(&mut state.surface_outputs, id).push(output.id());
            }
            wl_surface::Event::Leave { output } => {
                entry_for(&mut state.surface_outputs, id).retain(|held| held != &output.id());
            }
            wl_surface::Event::PreferredBufferScale { factor } => {
                entry_for(&mut state.surface_buffer_scales, id).push(factor);
            }
            _ => {}
        }
    }
}

/// A frame callback carries the surface it was asked for as its user data, so
/// that a `done` can be counted against the right surface. The object itself
/// says nothing about which surface it belongs to, and the compositor answers
/// one callback per request rather than one per surface.
impl Dispatch<WlCallback, ObjectId> for Driver {
    fn event(
        state: &mut Self,
        _callback: &WlCallback,
        event: wl_callback::Event,
        surface: &ObjectId,
        _connection: &Connection,
        _handle: &QueueHandle<Self>,
    ) {
        if let wl_callback::Event::Done { callback_data } = event {
            entry_for(&mut state.frames, surface.clone()).push(callback_data);
        }
    }
}

impl Dispatch<WpFractionalScaleV1, ()> for Driver {
    fn event(
        state: &mut Self,
        scale: &WpFractionalScaleV1,
        event: wp_fractional_scale_v1::Event,
        (): &(),
        _connection: &Connection,
        _handle: &QueueHandle<Self>,
    ) {
        if let wp_fractional_scale_v1::Event::PreferredScale { scale: preferred } = event {
            entry_for(&mut state.fractional_scales, scale.id()).push(preferred);
        }
    }
}

/// The list an object's events accumulate into, appending an empty one on the
/// first sighting.
///
/// A `Vec` of pairs rather than a map for the reason [`Driver`]'s other keyed
/// records are: the counts are in the single digits, and a test reading one out
/// wants the order it arrived in.
fn entry_for<T>(records: &mut Vec<(ObjectId, Vec<T>)>, id: ObjectId) -> &mut Vec<T> {
    if let Some(index) = records.iter().position(|(target, _)| *target == id) {
        return &mut records[index].1;
    }
    records.push((id, Vec::new()));
    let last = records.len() - 1;
    &mut records[last].1
}

impl Dispatch<WlOutput, ()> for Driver {
    fn event(
        state: &mut Self,
        output: &WlOutput,
        event: wl_output::Event,
        (): &(),
        _connection: &Connection,
        _handle: &QueueHandle<Self>,
    ) {
        let id = output.id();
        let pending = match state.outputs.iter_mut().find(|(target, _)| *target == id) {
            Some((_, pending)) => pending,
            None => {
                state.outputs.push((id, OutputRecord::default()));
                let last = state.outputs.len() - 1;
                &mut state.outputs[last].1
            }
        };

        match event {
            wl_output::Event::Geometry {
                physical_width,
                physical_height,
                ..
            } => {
                pending.pending.physical = (physical_width, physical_height);
            }
            wl_output::Event::Mode {
                flags,
                width,
                height,
                refresh,
            } => {
                if flags
                    .into_result()
                    .is_ok_and(|flags| flags.contains(wl_output::Mode::Current))
                {
                    pending.pending.size = (width, height);
                    pending.pending.refresh = refresh;
                }
            }
            wl_output::Event::Scale { factor } => pending.pending.scale = factor,
            wl_output::Event::Name { name } => pending.pending.name = Some(name),
            wl_output::Event::Description { description } => {
                pending.pending.description = Some(description);
            }
            wl_output::Event::Done => pending.current = Some(pending.pending.clone()),
            _ => {}
        }
    }
}

impl Dispatch<XdgWmBase, ()> for Driver {
    fn event(
        _state: &mut Self,
        wm_base: &XdgWmBase,
        event: xdg_wm_base::Event,
        (): &(),
        _connection: &Connection,
        _handle: &QueueHandle<Self>,
    ) {
        // A client that does not pong is disconnected as unresponsive.
        if let xdg_wm_base::Event::Ping { serial } = event {
            wm_base.pong(serial);
        }
    }
}

impl Dispatch<XdgSurface, ()> for Driver {
    fn event(
        state: &mut Self,
        xdg_surface: &XdgSurface,
        event: xdg_surface::Event,
        (): &(),
        _connection: &Connection,
        _handle: &QueueHandle<Self>,
    ) {
        if let xdg_surface::Event::Configure { serial } = event {
            let id = xdg_surface.id();
            state.configure_serials.push(serial);
            match state
                .configures
                .iter_mut()
                .find(|(target, _)| *target == id)
            {
                Some((_, recorded)) => *recorded = serial,
                None => state.configures.push((id, serial)),
            }
        }
    }
}

impl Dispatch<XdgToplevel, ()> for Driver {
    fn event(
        state: &mut Self,
        _toplevel: &XdgToplevel,
        event: xdg_toplevel::Event,
        (): &(),
        _connection: &Connection,
        _handle: &QueueHandle<Self>,
    ) {
        match event {
            xdg_toplevel::Event::Configure { width, height, .. } => {
                state.toplevel_size = Some((width, height));
            }
            xdg_toplevel::Event::Close => state.closed = true,
            _ => {}
        }
    }
}

impl Dispatch<WlSeat, ()> for Driver {
    fn event(
        state: &mut Self,
        seat: &WlSeat,
        event: wl_seat::Event,
        (): &(),
        _connection: &Connection,
        _handle: &QueueHandle<Self>,
    ) {
        match event {
            wl_seat::Event::Capabilities {
                capabilities: wayland_client::WEnum::Value(capabilities),
            } => {
                let record = state.seat_mut(seat);
                record.has_pointer = capabilities.contains(Capability::Pointer);
                record.has_keyboard = capabilities.contains(Capability::Keyboard);
            }
            wl_seat::Event::Name { name } => state.seat_mut(seat).name = Some(name),
            _ => {}
        }
    }
}

impl Dispatch<WlPointer, ()> for Driver {
    fn event(
        state: &mut Self,
        pointer: &WlPointer,
        event: wl_pointer::Event,
        (): &(),
        _connection: &Connection,
        _handle: &QueueHandle<Self>,
    ) {
        let recorded = match event {
            wl_pointer::Event::Enter {
                surface,
                surface_x,
                surface_y,
                serial,
            } => PointerEvent::Enter {
                surface: surface.id(),
                x: surface_x,
                y: surface_y,
                serial,
            },
            wl_pointer::Event::Motion {
                surface_x,
                surface_y,
                ..
            } => PointerEvent::Motion {
                x: surface_x,
                y: surface_y,
            },
            wl_pointer::Event::Button { button, state, .. } => PointerEvent::Button {
                button,
                pressed: state == wayland_client::WEnum::Value(ButtonState::Pressed),
            },
            wl_pointer::Event::Leave { surface, .. } => PointerEvent::Leave {
                surface: surface.id(),
            },
            wl_pointer::Event::AxisSource { axis_source } => {
                let wayland_client::WEnum::Value(source) = axis_source else {
                    return;
                };
                PointerEvent::AxisSource { source }
            }
            wl_pointer::Event::Axis { axis, value, .. } => {
                let Some(axis) = scroll_axis(axis) else {
                    return;
                };
                PointerEvent::Axis { axis, value }
            }
            wl_pointer::Event::AxisDiscrete { axis, discrete } => {
                let Some(axis) = scroll_axis(axis) else {
                    return;
                };
                PointerEvent::AxisDiscrete {
                    axis,
                    steps: discrete,
                }
            }
            // The frame and stop refinements say nothing these tests assert on.
            _ => return,
        };
        state.pointer.push((pointer.id(), recorded));
    }
}

/// A keyboard event as the client received it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum KeyboardEvent {
    /// The layout the compositor uploaded, read back out of the mapped file.
    Keymap {
        text: String,
    },
    Enter {
        surface: ObjectId,
    },
    Leave {
        surface: ObjectId,
    },
    /// The key in evdev numbering, which is what `wl_keyboard.key` carries.
    Key {
        key: u32,
        pressed: bool,
    },
    Modifiers {
        depressed: u32,
        locked: u32,
    },
}

impl Dispatch<WlKeyboard, ()> for Driver {
    fn event(
        state: &mut Self,
        keyboard: &WlKeyboard,
        event: wl_keyboard::Event,
        (): &(),
        _connection: &Connection,
        _handle: &QueueHandle<Self>,
    ) {
        let recorded = match event {
            wl_keyboard::Event::Keymap { fd, size, .. } => KeyboardEvent::Keymap {
                text: read_keymap(&fd, size),
            },
            wl_keyboard::Event::Enter { surface, .. } => KeyboardEvent::Enter {
                surface: surface.id(),
            },
            wl_keyboard::Event::Leave { surface, .. } => KeyboardEvent::Leave {
                surface: surface.id(),
            },
            wl_keyboard::Event::Key { key, state, .. } => KeyboardEvent::Key {
                key,
                pressed: state == wayland_client::WEnum::Value(KeyState::Pressed),
            },
            wl_keyboard::Event::Modifiers {
                mods_depressed,
                mods_locked,
                ..
            } => KeyboardEvent::Modifiers {
                depressed: mods_depressed,
                locked: mods_locked,
            },
            // `repeat_info` is policy the client applies itself and says
            // nothing about what was delivered.
            _ => return,
        };
        state.keyboard.push((keyboard.id(), recorded));
    }
}

/// The keymap the compositor sent, as the client reads it.
///
/// The size the protocol carries includes the terminating NUL, which is not
/// part of the text; a comparison against the compositor's own string would
/// otherwise never match.
fn read_keymap(fd: &OwnedFd, size: u32) -> String {
    let length = usize::try_from(size).expect("a keymap size that fits in memory");
    let mut file = std::fs::File::from(
        fd.try_clone()
            .expect("the keymap descriptor can be duplicated"),
    );
    // The descriptor is duplicated rather than owned, so it shares its offset
    // with the one the compositor kept: a second keymap event would otherwise
    // read from where the first one stopped.
    file.seek(SeekFrom::Start(0))
        .expect("the keymap file is seekable");
    let mut bytes = vec![0_u8; length];
    file.read_exact(&mut bytes)
        .expect("the keymap file holds the bytes the compositor announced");

    String::from_utf8(
        bytes
            .split(|byte| *byte == 0)
            .next()
            .expect("split always yields at least one piece")
            .to_vec(),
    )
    .expect("a keymap is text")
}

impl Dispatch<WlBuffer, ()> for Driver {
    fn event(
        state: &mut Self,
        buffer: &WlBuffer,
        event: wl_buffer::Event,
        (): &(),
        _connection: &Connection,
        _handle: &QueueHandle<Self>,
    ) {
        if let wl_buffer::Event::Release = event {
            state.released.push(buffer.id());
        }
    }
}

delegate_noop!(Driver: ignore WpContentTypeManagerV1);
delegate_noop!(Driver: ignore WpContentTypeV1);
delegate_noop!(Driver: ignore WlCompositor);
delegate_noop!(Driver: ignore WlShm);
delegate_noop!(Driver: ignore WlShmPool);
delegate_noop!(Driver: ignore ZwpLinuxDmabufV1);
delegate_noop!(Driver: ignore ZwpLinuxBufferParamsV1);
delegate_noop!(Driver: ignore WlRegion);
delegate_noop!(Driver: ignore WlSubcompositor);
delegate_noop!(Driver: ignore WpFractionalScaleManagerV1);
delegate_noop!(Driver: ignore WlSubsurface);
delegate_noop!(Driver: ignore XdgPositioner);
// An `xdg_popup` carries its own configure and a `popup_done`; neither says
// anything about where input lands, which is what these tests are about.
delegate_noop!(Driver: ignore XdgPopup);
