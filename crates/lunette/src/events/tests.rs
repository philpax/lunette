//! The tests for the event queue and its dispatch.

#![expect(
    clippy::expect_used,
    reason = "a failed expectation is how a test reports a failure; the ban is on production code"
)]

use pretty_assertions::assert_eq;

use super::*;
use crate::log_capture::Logs;

fn window_id(raw: u64) -> WindowId {
    WindowId::new(raw).expect("non-zero")
}

fn process_id(raw: u64) -> ProcessId {
    ProcessId::new(raw).expect("non-zero")
}

/// The longest name `CustomEvent.name` can carry is 31 bytes and the NUL.
const LONGEST: &str = "lunabcdefghijklmnopqrstuvwxyz01";

// The cast is needed when `c_char` is signed.
#[allow(clippy::unnecessary_cast)]
#[test]
fn a_name_at_the_limit_survives_the_trip_through_the_c_array() {
    assert_eq!(LONGEST.len(), CUSTOM_EVENT_NAME_CAPACITY - 1);

    let name = event_name(LONGEST);
    let array = name.to_c_name();

    let bytes: Vec<u8> = array.iter().map(|byte| *byte as u8).collect();
    assert_eq!(&bytes[..LONGEST.len()], LONGEST.as_bytes());
    assert_eq!(
        bytes[LONGEST.len()],
        0,
        "the array is what `lovr.handlers` is indexed by, so it has to terminate"
    );
}

/// A client that fails at startup leaves its stderr in the log whether or not
/// a handler listens.
#[test]
fn client_output_is_logged_as_it_is_converted() {
    let logs = Logs::capture(|| {
        let converted = LuaEvent::from_compositor(&CompositorEvent::ProcessOutput {
            process: process_id(5),
            stream: Stream::Stderr,
            bytes: b"cannot open display\n\xff".to_vec(),
        });
        assert!(converted.is_some(), "the output still reaches Lua");
    });

    assert_eq!(logs.mentioning("cannot open display"), 1);
    assert_eq!(logs.mentioning("stderr"), 1, "the log names the stream");
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
    queue.push(LuaEvent::WindowClosed {
        window: window_id(1),
    });
    queue.push(LuaEvent::WindowOpened {
        window: window_id(2),
    });

    assert_eq!(
        queue.take(WINDOW_CLOSED),
        Some(LuaEvent::WindowClosed {
            window: window_id(1),
        })
    );
    assert_eq!(
        queue.take(WINDOW_OPENED),
        Some(LuaEvent::WindowOpened {
            window: window_id(1)
        })
    );
}
