//! These tests verify drag-and-drop between two clients' windows.
//!
//! The commands follow what Lua sends while a laser drags: the press goes to
//! the window the drag starts from, the pointer leaves that window's sink and
//! moves onto the other's, and the release is addressed to the window that was
//! pressed. One client starts the drag with a data source and an optional icon;
//! the other is entered, accepts, receives the drop, and reads the bytes from
//! the first. Both clients use the in-process socket-pair harness, so the tests
//! need no GPU.

#![expect(
    clippy::expect_used,
    reason = "a failed expectation is how a test reports a failure; the ban is on production code"
)]

#[allow(
    dead_code,
    reason = "each integration test binary is its own crate and uses a subset of the harness"
)]
mod harness;

use std::{io::Write, time::Instant};

use harness::WINDOW_SIZE;
use lunette_compositor::{
    config::DEFAULT_SEAT,
    protocol::{
        Command, DragIcon, DragSnapshot, KeyboardConfig, PixelPoint, PixelSize, PointerButton,
        SeatId, SeatSnapshot, SinkId, SourceCrop, SurfaceOffset,
    },
    test_client::{DragEvent, DragSource, SelectionDevices, SourceEvent, TestClient, read_to_end},
    testing::{DEADLINE, TestCompositor},
};
use pretty_assertions::assert_eq;
use wayland_client::protocol::wl_pointer::WlPointer;

const MIME: &str = "text/plain;charset=utf-8";
const DEFAULT_SEAT_NAME: &str = "lunette";
const ICON: PixelSize = PixelSize::new(32, 24);
/// Where the drag starts on the source window.
const GRAB: (f64, f64) = (10.0, 10.0);
/// Where the pointer crosses into the target window.
const AIM: (f64, f64) = (30.0, 40.0);

/// Two clients, each with a mapped window and the data device of one seat,
/// and the source client's pointer on that seat.
struct Fixture {
    compositor: TestCompositor,
    seat: SeatId,
    source: TestClient,
    source_devices: SelectionDevices,
    source_pointer: WlPointer,
    source_sink: SinkId,
    target: TestClient,
    target_devices: SelectionDevices,
    target_sink: SinkId,
}

impl Fixture {
    fn new() -> Self {
        Self::on_seat(TestCompositor::new(), DEFAULT_SEAT, DEFAULT_SEAT_NAME)
    }

    fn on_seat(mut compositor: TestCompositor, seat: SeatId, name: &str) -> Self {
        let mut source = open_window(&mut compositor);
        let source_sink = newest_sink(&compositor);
        let source_pointer = source.open_pointer_for(&mut compositor, name);
        let source_devices = source.open_selection(&mut compositor, name);

        let mut target = open_window(&mut compositor);
        let target_sink = newest_sink(&compositor);
        let target_devices = target.open_selection(&mut compositor, name);

        Self {
            compositor,
            seat,
            source,
            source_devices,
            source_pointer,
            source_sink,
            target,
            target_devices,
            target_sink,
        }
    }

    /// Presses on the source window and starts a drag from that press.
    fn start(&mut self, icon: Option<PixelSize>) -> DragSource {
        self.point(self.source_sink, GRAB);
        self.button(self.source_sink, true);
        let pointer = self.source_pointer.clone();
        self.source.settle(&mut self.compositor, |driver| {
            driver.buttons(&pointer).contains(&(BTN_LEFT, true))
        });
        let devices = self.source_devices.clone();
        let drag = self
            .source
            .start_drag(&mut self.compositor, &devices, &pointer, &[MIME], icon);
        let seat = self.seat;
        self.await_snapshot(|seats| seat_of(seats, seat).drag.is_some());
        drag
    }

    /// Leaves the source window and enters the target, as a laser crossing
    /// from one panel to the other does, and waits for the target's enter.
    fn cross_to_target(&mut self) {
        self.leave();
        self.point(self.target_sink, AIM);
        let devices = self.target_devices.clone();
        self.target.settle(&mut self.compositor, |driver| {
            driver
                .drag_events(&devices)
                .iter()
                .any(|event| matches!(event, DragEvent::Enter { .. }))
        });
    }

    fn point(&self, sink: SinkId, (x, y): (f64, f64)) {
        self.compositor.send(Command::Pointer {
            seat: self.seat,
            sink,
            position: PixelPoint::new(x, y),
        });
    }

    fn leave(&self) {
        self.compositor
            .send(Command::PointerLeave { seat: self.seat });
    }

    fn button(&self, sink: SinkId, pressed: bool) {
        self.compositor.send(Command::Button {
            seat: self.seat,
            sink,
            button: PointerButton::Left,
            pressed,
        });
    }

    fn target_events(&self) -> Vec<DragEvent> {
        self.target.driver().drag_events(&self.target_devices)
    }

    fn await_source_event(&mut self, drag: &DragSource, wanted: SourceEvent) {
        let source = drag.source.clone();
        self.source.settle(&mut self.compositor, |driver| {
            driver.source_events(&source).contains(&wanted)
        });
    }

    fn await_target_event(&mut self, wanted: impl Fn(&DragEvent) -> bool) {
        let devices = self.target_devices.clone();
        self.target.settle(&mut self.compositor, |driver| {
            driver.drag_events(&devices).iter().any(&wanted)
        });
    }

    fn await_snapshot(&mut self, ready: impl Fn(&[SeatSnapshot]) -> bool) {
        let deadline = Instant::now() + DEADLINE;
        loop {
            self.source.settle_quiet(&mut self.compositor);
            if ready(&self.compositor.snapshot().seats) {
                return;
            }
            assert!(
                Instant::now() < deadline,
                "the snapshot did not reach the expected state; it has {:?}",
                self.compositor.snapshot().seats
            );
        }
    }

    fn drag_on(&self, seat: SeatId) -> Option<DragSnapshot> {
        seat_of(&self.compositor.snapshot().seats, seat)
            .drag
            .clone()
    }
}

/// `BTN_LEFT`, the evdev code a left click carries on the wire.
const BTN_LEFT: u32 = 0x110;

#[test]
fn a_drag_carries_its_data_from_one_client_s_window_to_another_s() {
    let mut fixture = Fixture::new();
    let drag = fixture.start(Some(ICON));

    fixture.cross_to_target();
    let devices = fixture.target_devices.clone();
    assert_eq!(fixture.target.driver().drag_mimes(&devices), [MIME]);
    match fixture.target_events().as_slice() {
        [DragEvent::Enter { x, y, offer, .. }] => {
            assert_eq!(
                (*x, *y),
                AIM,
                "the drag enters at the target's own coordinates"
            );
            assert!(offer.is_some(), "a drag with a source carries an offer");
        }
        other => panic!("the target saw {other:?} rather than one enter"),
    }

    fixture
        .target
        .accept_drag(&mut fixture.compositor, &devices, MIME);
    // Lua releases on the sink it pressed, wherever the pointer now is.
    fixture.button(fixture.source_sink, false);
    fixture.await_target_event(|event| *event == DragEvent::Drop);
    fixture.await_source_event(&drag, SourceEvent::DropPerformed);

    let pipe = fixture
        .target
        .receive_drop(&mut fixture.compositor, &devices, MIME);
    fixture
        .source
        .settle(&mut fixture.compositor, |driver| !driver.sends_are_empty());
    let (mime, fd) = fixture
        .source
        .take_sends()
        .pop()
        .expect("the receive reached the dragging client");
    assert_eq!(mime, MIME);
    std::fs::File::from(fd)
        .write_all(b"dragged")
        .expect("the pipe accepts the bytes");
    assert_eq!(read_to_end(pipe), b"dragged");

    fixture
        .target
        .finish_drop(&mut fixture.compositor, &devices);
    fixture.await_source_event(&drag, SourceEvent::Finished);
    let seat = fixture.seat;
    fixture.await_snapshot(|seats| seat_of(seats, seat).drag.is_none());
    assert_eq!(
        fixture.target.driver().drag_events(&devices).last(),
        Some(&DragEvent::Leave),
        "the target is left once the drop completes"
    );
}

#[test]
fn a_drag_released_over_nothing_is_cancelled_and_drops_nowhere() {
    let mut fixture = Fixture::new();
    let drag = fixture.start(None);
    fixture.cross_to_target();
    let devices = fixture.target_devices.clone();
    fixture
        .target
        .accept_drag(&mut fixture.compositor, &devices, MIME);

    fixture.leave();
    fixture.await_target_event(|event| *event == DragEvent::Leave);
    fixture.button(fixture.source_sink, false);
    fixture.await_source_event(&drag, SourceEvent::Cancelled);

    let seat = fixture.seat;
    fixture.await_snapshot(|seats| seat_of(seats, seat).drag.is_none());
    assert!(
        !fixture.target_events().contains(&DragEvent::Drop),
        "nothing was under the pointer to drop on"
    );
}

#[test]
fn closing_the_window_a_drag_started_from_cancels_the_drag() {
    let mut fixture = Fixture::new();
    let drag = fixture.start(Some(ICON));
    fixture.cross_to_target();

    // Lua never releases on a sink whose window is gone, so the compositor
    // ends the drag itself.
    fixture.source.close_toplevel(&mut fixture.compositor);
    fixture.await_target_event(|event| *event == DragEvent::Leave);
    fixture.await_source_event(&drag, SourceEvent::Cancelled);
    let seat = fixture.seat;
    fixture.await_snapshot(|seats| seat_of(seats, seat).drag.is_none());
    assert!(!fixture.target_events().contains(&DragEvent::Drop));
}

#[test]
fn a_drag_whose_client_disconnects_ends_and_leaves_the_target() {
    let mut fixture = Fixture::new();
    fixture.start(Some(ICON));
    fixture.cross_to_target();

    let Fixture {
        mut compositor,
        source,
        mut target,
        target_devices,
        seat,
        ..
    } = fixture;
    source.disconnect(&mut compositor);
    target.settle(&mut compositor, |driver| {
        driver
            .drag_events(&target_devices)
            .contains(&DragEvent::Leave)
    });
    target.settle_quiet(&mut compositor);
    assert_eq!(
        seat_of(&compositor.snapshot().seats, seat).drag,
        None,
        "the drag ended with its client"
    );
}

#[test]
fn the_snapshot_reports_a_drag_and_its_icon_on_the_seat_that_carries_it() {
    let mut fixture = Fixture::new();
    let drag = fixture.start(Some(ICON));
    let icon = fixture
        .drag_on(DEFAULT_SEAT)
        .expect("the seat carries the drag")
        .icon
        .expect("the icon has content");
    assert_eq!(
        (icon.size, icon.source_crop, icon.offset),
        (ICON, SourceCrop::FULL, SurfaceOffset { x: 0, y: 0 }),
        "the icon's corner starts at the pointer"
    );

    let surface = drag.icon.clone().expect("the drag has an icon");
    fixture
        .source
        .offset_icon(&mut fixture.compositor, &surface, -4, -6);
    fixture
        .source
        .offset_icon(&mut fixture.compositor, &surface, 1, 1);
    let offset = |seats: &[SeatSnapshot]| {
        seat_of(seats, DEFAULT_SEAT)
            .drag
            .as_ref()
            .and_then(|drag| drag.icon.as_ref())
            .map(|icon: &DragIcon| icon.offset)
    };
    fixture.await_snapshot(|seats| offset(seats) == Some(SurfaceOffset { x: -3, y: -5 }));
}

#[test]
fn a_drag_without_an_icon_is_reported_without_one() {
    let mut fixture = Fixture::new();
    fixture.start(None);
    let drag = fixture
        .drag_on(DEFAULT_SEAT)
        .expect("the seat carries the drag");
    assert_eq!(drag.icon, None);
}

#[test]
fn two_drags_are_told_apart() {
    let mut fixture = Fixture::new();
    fixture.start(None);
    let first = fixture.drag_on(DEFAULT_SEAT).expect("a drag").drag;
    fixture.leave();
    fixture.button(fixture.source_sink, false);
    fixture.await_snapshot(|seats| seat_of(seats, DEFAULT_SEAT).drag.is_none());

    fixture.start(None);
    let second = fixture.drag_on(DEFAULT_SEAT).expect("a drag").drag;
    assert_ne!(first, second);
}

#[test]
fn a_drag_belongs_to_the_seat_whose_press_it_started_from() {
    let mut compositor = TestCompositor::new();
    compositor.send(Command::CreateSeat {
        seat: LEFT.0,
        name: LEFT.1.to_owned(),
        keyboard: Box::new(KeyboardConfig::default()),
    });
    compositor.send(Command::CreateSeat {
        seat: RIGHT.0,
        name: RIGHT.1.to_owned(),
        keyboard: Box::new(KeyboardConfig::default()),
    });
    compositor.step();
    let mut fixture = Fixture::on_seat(compositor, LEFT.0, LEFT.1);

    fixture.point(fixture.source_sink, GRAB);
    fixture.button(fixture.source_sink, true);
    let pointer = fixture.source_pointer.clone();
    fixture.source.settle(&mut fixture.compositor, |driver| {
        driver.buttons(&pointer).contains(&(BTN_LEFT, true))
    });
    // Another seat presses after the left one, and before the drag starts.
    fixture.compositor.send(Command::Pointer {
        seat: RIGHT.0,
        sink: fixture.target_sink,
        position: PixelPoint::new(AIM.0, AIM.1),
    });
    fixture.compositor.send(Command::Button {
        seat: RIGHT.0,
        sink: fixture.target_sink,
        button: PointerButton::Left,
        pressed: true,
    });
    fixture.target.settle_quiet(&mut fixture.compositor);

    let devices = fixture.source_devices.clone();
    fixture
        .source
        .start_drag(&mut fixture.compositor, &devices, &pointer, &[MIME], None);
    fixture.await_snapshot(|seats| seat_of(seats, LEFT.0).drag.is_some());
    assert_eq!(fixture.drag_on(RIGHT.0), None);
}

#[test]
fn destroying_the_seat_that_carries_a_drag_cancels_it() {
    let mut compositor = TestCompositor::new();
    compositor.send(Command::CreateSeat {
        seat: LEFT.0,
        name: LEFT.1.to_owned(),
        keyboard: Box::new(KeyboardConfig::default()),
    });
    compositor.step();
    let mut fixture = Fixture::on_seat(compositor, LEFT.0, LEFT.1);
    let drag = fixture.start(None);
    fixture.cross_to_target();

    fixture
        .compositor
        .send(Command::DestroySeat { seat: LEFT.0 });
    fixture.await_target_event(|event| *event == DragEvent::Leave);
    fixture.await_source_event(&drag, SourceEvent::Cancelled);
}

const LEFT: (SeatId, &str) = (seat_id(2), "left");
const RIGHT: (SeatId, &str) = (seat_id(3), "right");

const fn seat_id(raw: u64) -> SeatId {
    match SeatId::new(raw) {
        Some(seat) => seat,
        None => unreachable!(),
    }
}

fn open_window(compositor: &mut TestCompositor) -> TestClient {
    let mut client = TestClient::connect(compositor);
    client.open_toplevel(compositor);
    client.attach_buffer(compositor, WINDOW_SIZE);
    client
}

/// The sink of the most recently opened window. Snapshots keep creation order.
fn newest_sink(compositor: &TestCompositor) -> SinkId {
    compositor
        .snapshot()
        .windows
        .last()
        .expect("a window is mapped")
        .sink
}

fn seat_of(seats: &[SeatSnapshot], seat: SeatId) -> &SeatSnapshot {
    seats
        .iter()
        .find(|entry| entry.seat == seat)
        .unwrap_or_else(|| panic!("{seat} is not in the snapshot"))
}
