//! Records Wayland events from the test client for assertions.
//!
//! Dispatch handlers preserve event arrival order and key records by the object
//! that received each event. This keeps routing across multiple seats, outputs,
//! and surfaces observable to tests.

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
    xdg::{
        decoration::zv1::client::{
            zxdg_decoration_manager_v1::ZxdgDecorationManagerV1,
            zxdg_toplevel_decoration_v1::{self, ZxdgToplevelDecorationV1},
        },
        shell::client::{
            xdg_popup::XdgPopup,
            xdg_positioner::XdgPositioner,
            xdg_surface::{self, XdgSurface},
            xdg_toplevel::{self, XdgToplevel},
            xdg_wm_base::{self, XdgWmBase},
        },
    },
};

use crate::protocol::ScrollAxis;

#[derive(Debug, Default)]
pub struct Driver {
    pub globals: Vec<Global>,
    pub(super) registry: Option<WlRegistry>,
    /// Stores the latest serial for each `xdg_surface`; clients must acknowledge
    /// the serial for the same surface before attaching a buffer.
    configures: Vec<(ObjectId, u32)>,
    /// Stores every configure serial in arrival order so tests can check global
    /// serial uniqueness across surfaces.
    configure_serials: Vec<u32>,
    pub toplevel_size: Option<(i32, i32)>,
    /// The decoration mode of the latest `zxdg_toplevel_decoration_v1.configure`.
    pub decoration_mode: Option<zxdg_toplevel_decoration_v1::Mode>,
    pub closed: bool,
    seats: Vec<SeatRecord>,
    /// Stores each pointer event with the object that received it, in arrival
    /// order, so tests can verify routing between seats.
    pointer: Vec<(ObjectId, PointerEvent)>,
    /// Stores each keyboard event with the object that received it, in arrival
    /// order, so tests can verify routing between seats.
    keyboard: Vec<(ObjectId, KeyboardEvent)>,
    /// A client may reuse a buffer after the compositor sends `wl_buffer.release`.
    pub released: Vec<ObjectId>,
    /// Publishes each output's pending properties only when `wl_output.done`
    /// arrives, so a read never observes a partial configuration.
    outputs: Vec<(ObjectId, OutputRecord)>,
    /// Stores output identifiers for each surface in event order. Duplicate
    /// `wl_surface.enter` events remain observable.
    surface_outputs: Vec<(ObjectId, Vec<ObjectId>)>,
    surface_buffer_scales: Vec<(ObjectId, Vec<i32>)>,
    /// Stores `preferred_scale` values in protocol units: 120ths.
    fractional_scales: Vec<(ObjectId, Vec<u32>)>,
    /// Stores each frame callback timestamp by surface and in arrival order;
    /// withheld callbacks remain distinguishable from delivered callbacks.
    frames: Vec<(ObjectId, Vec<u32>)>,

    pub(super) offers: Vec<(ObjectId, Vec<String>)>,
    pub(super) clipboard: Vec<(ObjectId, Option<WlDataOffer>)>,
    pub(super) primary: Vec<(ObjectId, Option<ZwpPrimarySelectionOfferV1>)>,
    /// Keeps the compositor-provided descriptor alive until the test writes and
    /// closes it.
    pub(super) sends: Vec<(String, OwnedFd)>,
    pub(super) cancelled: bool,
}

impl Driver {
    /// Returns callback timestamps in arrival order. An empty slice means that
    /// no callback has arrived, including when the compositor withholds them.
    #[must_use]
    pub fn frames(&self, surface: &ObjectId) -> &[u32] {
        self.frames
            .iter()
            .find(|(held, _)| held == surface)
            .map_or(&[], |(_, stamps)| stamps.as_slice())
    }

    /// Returns the latest serial for an `xdg_surface`; the caller acknowledges it
    /// before attaching a buffer.
    #[must_use]
    pub fn configure_serial(&self, xdg_surface: &XdgSurface) -> Option<u32> {
        let id = xdg_surface.id();
        self.configures
            .iter()
            .find(|(target, _)| *target == id)
            .map(|(_, serial)| *serial)
    }

    /// Returns configure serials in arrival order, including serials for different
    /// surfaces.
    #[must_use]
    pub fn configure_serials(&self) -> Vec<u32> {
        self.configure_serials.clone()
    }

    /// Returns the latest state published by `wl_output.done`, or `None` before
    /// the first `done`.
    #[must_use]
    pub fn output(&self, output: &WlOutput) -> Option<OutputState> {
        let id = output.id();
        self.outputs
            .iter()
            .find(|(target, _)| *target == id)
            .and_then(|(_, record)| record.current.clone())
    }

    /// Returns `wl_output.name` events in arrival order. A name is sent once per
    /// output object, so repeated entries expose a protocol violation.
    #[must_use]
    pub fn output_names(&self, output: &WlOutput) -> Vec<String> {
        let id = output.id();
        self.outputs
            .iter()
            .find(|(target, _)| *target == id)
            .map_or_else(Vec::new, |(_, record)| record.names.clone())
    }

    /// Returns output identifiers from `wl_surface.enter` in arrival order; the
    /// list reflects the surface's current output membership after leaves.
    #[must_use]
    pub fn surface_outputs(&self, surface: &ObjectId) -> Vec<ObjectId> {
        self.surface_outputs
            .iter()
            .find(|(target, _)| target == surface)
            .map_or_else(Vec::new, |(_, outputs)| outputs.clone())
    }

    /// Returns `preferred_buffer_scale` factors in arrival order.
    #[must_use]
    pub fn buffer_scales(&self, surface: &ObjectId) -> Vec<i32> {
        self.surface_buffer_scales
            .iter()
            .find(|(target, _)| target == surface)
            .map_or_else(Vec::new, |(_, scales)| scales.clone())
    }

    /// Returns `preferred_scale` values in arrival order and protocol units of
    /// 120ths.
    #[must_use]
    pub fn preferred_scales(&self, scale: &WpFractionalScaleV1) -> Vec<u32> {
        let id = scale.id();
        self.fractional_scales
            .iter()
            .find(|(target, _)| *target == id)
            .map_or_else(Vec::new, |(_, scales)| scales.clone())
    }

    #[must_use]
    pub fn seat_name(&self, seat: &WlSeat) -> Option<String> {
        self.seat(seat).and_then(|record| record.name.clone())
    }

    #[must_use]
    pub fn seat_names(&self) -> Vec<String> {
        self.seats
            .iter()
            .filter_map(|record| record.name.clone())
            .collect()
    }

    #[must_use]
    pub fn has_pointer(&self, seat: &WlSeat) -> bool {
        self.seat(seat).is_some_and(|record| record.has_pointer)
    }

    #[must_use]
    pub fn has_keyboard(&self, seat: &WlSeat) -> bool {
        self.seat(seat).is_some_and(|record| record.has_keyboard)
    }

    /// Returns events delivered to this keyboard in arrival order.
    #[must_use]
    pub fn keyboard_events(&self, keyboard: &WlKeyboard) -> Vec<KeyboardEvent> {
        let id = keyboard.id();
        self.keyboard
            .iter()
            .filter(|(target, _)| *target == id)
            .map(|(_, event)| event.clone())
            .collect()
    }

    /// Returns key presses and releases in arrival order; key codes use evdev
    /// numbering.
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

    /// Returns the latest depressed and locked modifier masks, if any.
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

    /// Returns keymap text delivered to this keyboard in arrival order. Each
    /// value excludes the protocol's terminating NUL.
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

    /// Returns the surface named by the latest keyboard enter, or `None` after a
    /// leave or before any enter.
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

    /// Returns events delivered to this pointer in arrival order.
    #[must_use]
    pub fn events(&self, pointer: &WlPointer) -> Vec<PointerEvent> {
        let id = pointer.id();
        self.pointer
            .iter()
            .filter(|(target, _)| *target == id)
            .map(|(_, event)| event.clone())
            .collect()
    }

    /// Returns the first entered surface and its surface-local coordinates, if
    /// any.
    #[must_use]
    pub fn first_enter(&self, pointer: &WlPointer) -> Option<(ObjectId, f64, f64)> {
        self.events(pointer)
            .into_iter()
            .find_map(|event| match event {
                PointerEvent::Enter { surface, x, y, .. } => Some((surface, x, y)),
                _ => None,
            })
    }

    /// Returns the latest enter serial, which `set_cursor` must use for this
    /// pointer.
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

    /// Returns button presses and releases in arrival order; button codes use the
    /// values carried by `wl_pointer.button`.
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

#[derive(Debug, Default)]
struct OutputRecord {
    pending: OutputState,
    current: Option<OutputState>,
    names: Vec<String>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct OutputState {
    /// The current mode's resolution, in pixels.
    pub size: (i32, i32),
    /// The `wl_output.mode` refresh rate, in millihertz.
    pub refresh: i32,
    /// The physical output dimensions, in millimetres.
    pub physical: (i32, i32),
    /// The integer output scale factor.
    pub scale: i32,
    /// The output name, sent by `wl_output` version 4 and later.
    pub name: Option<String>,
    /// The output description, sent by `wl_output` version 4 and later.
    pub description: Option<String>,
}

#[derive(Debug)]
struct SeatRecord {
    seat: ObjectId,
    name: Option<String>,
    has_pointer: bool,
    has_keyboard: bool,
}

#[derive(Clone, Debug)]
pub struct Global {
    pub name: u32,
    pub interface: String,
    pub version: u32,
}

/// Pointer events retain surface-local coordinates and protocol serials so tests
/// can verify routing and cursor requests.
#[derive(Clone, Debug, PartialEq)]
pub enum PointerEvent {
    Enter {
        surface: ObjectId,
        x: f64,
        y: f64,
        /// The serial that a subsequent `set_cursor` request must repeat.
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
    /// The `wl_pointer.axis_source` value that describes the input device.
    AxisSource {
        source: wl_pointer::AxisSource,
    },
    Axis {
        axis: ScrollAxis,
        value: f64,
    },
    /// Discrete steps carried by the compatibility `axis_discrete` event for
    /// clients below `wl_pointer` version 8.
    AxisDiscrete {
        axis: ScrollAxis,
        steps: i32,
    },
}

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
            wl_output::Event::Name { name } => {
                pending.names.push(name.clone());
                pending.pending.name = Some(name);
            }
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
        // The compositor disconnects a client that does not answer a ping.
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

impl Dispatch<ZxdgToplevelDecorationV1, ()> for Driver {
    fn event(
        state: &mut Self,
        _decoration: &ZxdgToplevelDecorationV1,
        event: zxdg_toplevel_decoration_v1::Event,
        (): &(),
        _connection: &Connection,
        _handle: &QueueHandle<Self>,
    ) {
        if let zxdg_toplevel_decoration_v1::Event::Configure {
            mode: wayland_client::WEnum::Value(mode),
        } = event
        {
            state.decoration_mode = Some(mode);
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
            _ => return,
        };
        state.pointer.push((pointer.id(), recorded));
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum KeyboardEvent {
    /// Keymap text read from the descriptor supplied with `wl_keyboard.keymap`.
    Keymap {
        text: String,
    },
    Enter {
        surface: ObjectId,
    },
    Leave {
        surface: ObjectId,
    },
    /// A key code in the numbering carried by `wl_keyboard.key`.
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
            _ => return,
        };
        state.keyboard.push((keyboard.id(), recorded));
    }
}

/// Reads the keymap text from a clone of the descriptor owned by the keymap
/// event. The protocol size includes the terminating NUL, which is omitted from
/// the returned text.
fn read_keymap(fd: &OwnedFd, size: u32) -> String {
    let length = usize::try_from(size).expect("a keymap size that fits in memory");
    let mut file = std::fs::File::from(
        fd.try_clone()
            .expect("the keymap descriptor can be duplicated"),
    );
    // Reset the shared file offset so each keymap event reads from the beginning.
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
delegate_noop!(Driver: ignore XdgPopup);
delegate_noop!(Driver: ignore ZxdgDecorationManagerV1);
