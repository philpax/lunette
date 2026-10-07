//! The tests for the event queue and its dispatch.

#![expect(
    clippy::expect_used,
    reason = "a failed expectation is how a test reports a failure; the ban is on production code"
)]

use lunette_compositor::{
    protocol::{ImportedBuffer, PixelSize, SurfaceId},
    surface::{PixelBuffer, ShmFormat},
};
use pretty_assertions::assert_eq;

use super::*;

fn window_id(raw: u64) -> WindowId {
    WindowId::new(raw).expect("non-zero")
}

fn process_id(raw: u64) -> ProcessId {
    ProcessId::new(raw).expect("non-zero")
}

/// The longest name `CustomEvent.name` can carry is 31 bytes and the NUL.
const LONGEST: &str = "lunabcdefghijklmnopqrstuvwxyz01";

/// The test embeds the checked-in module declarations. It needs no filesystem
/// and cannot pass against a stale copy on disk.
const DECLARATIONS: &str = include_str!("../../../../lua/lunette/init.luau");

/// Every event this build delivers can be subscribed to, and the subscription
/// is declared.
///
/// Both come from one declaration, so they cannot diverge. The test catches an
/// event whose declaration exists and whose generated file omits it.
/// `make check-definitions` reports the same gap, and the test reports it
/// where a reader looks at the events.
#[test]
fn every_event_this_build_delivers_can_be_subscribed_to() {
    let functions = subscription_functions::<crate::lua::declarations::NullTexture>();
    assert_eq!(
        functions.len(),
        EVENT_NAMES.len(),
        "an event without a subscription is one nothing can hear"
    );

    let missing: Vec<&str> = functions
        .iter()
        .map(|function| function.spec.name)
        .filter(|name| !DECLARATIONS.contains(&format!("\n  read {name}: ")))
        .collect();

    assert_eq!(
        missing,
        Vec::<&str>::new(),
        "each of these is registered and undeclared; regenerate the declarations"
    );
}

#[test]
fn every_event_this_build_delivers_has_a_distinct_name() {
    let mut names: Vec<&str> = EVENT_NAMES.iter().map(|name| name.as_str()).collect();
    names.sort_unstable();

    assert_eq!(
        names,
        vec![
            "lunlayergranted",
            "lunlayerrevoked",
            "lunmonitoradded",
            "lunprocessexited",
            "lunprocessoutput",
            "luntitlechanged",
            "lunwindowclosed",
            "lunwindowopened",
        ],
        "a name here is what a configuration writes `function lovr.<name>(event)` against"
    );
}

// The cast is needed when `c_char` is signed.
#[allow(clippy::unnecessary_cast)]
#[test]
fn a_name_at_the_limit_survives_the_trip_through_the_c_array() {
    assert_eq!(LONGEST.len(), CUSTOM_EVENT_NAME_CAPACITY - 1);

    let name = EventName::new(LONGEST).expect("31 bytes fit");
    let array = name.to_c_name();

    let bytes: Vec<u8> = array.iter().map(|byte| *byte as u8).collect();
    assert_eq!(&bytes[..LONGEST.len()], LONGEST.as_bytes());
    assert_eq!(
        bytes[LONGEST.len()],
        0,
        "the array is what `lovr.handlers` is indexed by, so it has to terminate"
    );
}

#[test]
fn a_name_too_long_for_the_array_is_refused() {
    let overlong = format!("{LONGEST}x");
    assert_eq!(overlong.len(), CUSTOM_EVENT_NAME_CAPACITY);

    // `EventName::new` takes a `&'static str`, and its check is on the
    // length. Leaking the test string supplies that lifetime; the constructor
    // refuses this length, one byte past the longest accepted name.
    assert_eq!(EventName::new(String::leak(overlong)), None);
}

#[test]
fn a_name_with_an_embedded_nul_is_refused() {
    assert_eq!(
        EventName::new("lunwindow\0opened"),
        None,
        "the C array would carry only the part before the NUL"
    );
}

#[test]
fn an_empty_array_is_all_zero_beyond_the_name() {
    let array = event_name("lun").to_c_name();
    assert!(array[3..].iter().all(|byte| *byte == 0));
}

#[test]
fn the_window_lifecycle_reaches_lua() {
    assert_eq!(
        LuaEvent::from_compositor(&CompositorEvent::WindowOpened {
            window: window_id(1)
        }),
        Some(LuaEvent::WindowOpened {
            window: window_id(1)
        })
    );
    assert_eq!(
        LuaEvent::from_compositor(&CompositorEvent::WindowClosed {
            window: window_id(1)
        }),
        Some(LuaEvent::WindowClosed {
            window: window_id(1)
        })
    );
    assert_eq!(
        LuaEvent::from_compositor(&CompositorEvent::TitleChanged {
            window: window_id(1),
            title: "htop".to_owned(),
        }),
        Some(LuaEvent::TitleChanged {
            window: window_id(1),
            title: "htop".to_owned(),
        })
    );
}

#[test]
fn a_spawn_that_never_started_reaches_lua_as_an_exit() {
    let outcome = ProcessOutcome::SpawnFailed {
        message: "no such file or directory".to_owned(),
    };

    assert_eq!(
        LuaEvent::from_compositor(&CompositorEvent::ProcessExited {
            process: process_id(3),
            outcome: outcome.clone(),
        }),
        Some(LuaEvent::ProcessExited {
            process: process_id(3),
            outcome,
        }),
        "a mistyped program name has no other way of reaching the configuration"
    );
}

#[test]
fn the_frame_loops_own_reports_are_not_callbacks() {
    let surface = SurfaceId::new(1).expect("non-zero");
    let pixels = PixelBuffer::new(
        PixelSize::new(1, 1),
        ShmFormat::Argb8888,
        vec![0, 0, 0, 255],
    )
    .expect("one pixel");

    assert_eq!(
        LuaEvent::from_compositor(&CompositorEvent::SurfaceDamaged { surface }),
        None
    );
    assert_eq!(
        LuaEvent::from_compositor(&CompositorEvent::BufferImported {
            surface,
            buffer: ImportedBuffer::Pixels(pixels),
        }),
        None
    );
    assert_eq!(
        LuaEvent::from_compositor(&CompositorEvent::SurfaceGone { surface }),
        None,
        "a surface is not a window; a window going away is reported on its own"
    );
}

#[test]
fn a_pending_event_is_taken_by_the_name_it_was_pushed_under() {
    let mut queue = EventQueue::default();
    queue.push(LuaEvent::WindowOpened {
        window: window_id(1),
    });

    assert_eq!(queue.take(WINDOW_CLOSED), None);
    assert_eq!(
        queue.take(WINDOW_OPENED),
        Some(LuaEvent::WindowOpened {
            window: window_id(1)
        })
    );
    assert_eq!(
        queue.take(WINDOW_OPENED),
        None,
        "an event is delivered once, or a handler sees the same window open twice"
    );
}

#[test]
fn events_of_one_name_are_taken_in_the_order_they_were_pushed() {
    let mut queue = EventQueue::default();
    for raw in 1..=3 {
        queue.push(LuaEvent::WindowOpened {
            window: window_id(raw),
        });
    }

    let taken: Vec<u64> = (1..=3)
        .filter_map(|_| match queue.take(WINDOW_OPENED) {
            Some(LuaEvent::WindowOpened { window }) => Some(window.get()),
            _ => None,
        })
        .collect();

    assert_eq!(
        taken,
        vec![1, 2, 3],
        "LÖVR's queue is first-in-first-out and so is this one; that is what pairs them"
    );
}

#[test]
fn an_event_of_another_name_does_not_disturb_the_order() {
    let mut queue = EventQueue::default();
    queue.push(LuaEvent::WindowOpened {
        window: window_id(1),
    });
    queue.push(LuaEvent::TitleChanged {
        window: window_id(1),
        title: "htop".to_owned(),
    });
    queue.push(LuaEvent::WindowOpened {
        window: window_id(2),
    });

    assert_eq!(
        queue.take(TITLE_CHANGED),
        Some(LuaEvent::TitleChanged {
            window: window_id(1),
            title: "htop".to_owned(),
        })
    );
    assert_eq!(
        queue.take(WINDOW_OPENED),
        Some(LuaEvent::WindowOpened {
            window: window_id(1)
        })
    );
}

#[test]
fn clearing_drops_what_was_never_dispatched() {
    let mut queue = EventQueue::default();
    queue.push(LuaEvent::WindowOpened {
        window: window_id(1),
    });
    queue.clear();

    assert_eq!(
        queue.take(WINDOW_OPENED),
        None,
        "an event discarded by lovr.event.clear must not be delivered against a later frame's \
         snapshot"
    );
}

#[test]
fn a_recording_sink_reports_each_push_once() {
    let sink = RecordingEventSink::default();
    sink.push(WINDOW_OPENED);
    sink.push(TITLE_CHANGED);

    assert_eq!(sink.take(), vec![WINDOW_OPENED, TITLE_CHANGED]);
    assert_eq!(sink.take(), Vec::new());
}
