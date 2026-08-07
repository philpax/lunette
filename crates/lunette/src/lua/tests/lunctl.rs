//! What `lunctl` gets back when a chunk returns the session's own handles.
//!
//! The serialiser's own tests use a fake handle, because what they are about is
//! the tagging convention. These use the real ones, against a real snapshot, so
//! that a handle type registered without its tag — or with the wrong one — fails
//! here rather than at a shell prompt.

use lunette_compositor::protocol::PixelSize;
use pretty_assertions::assert_eq;

use super::{lua, session, window};
use crate::control::{
    Budget, answer,
    wire::{Handle, HandleId, HandleKind, Key, Reply, TableValue, Value, read_reply, write_reply},
};

fn size() -> PixelSize {
    PixelSize::new(1920, 1080)
}

fn returned(chunk: &str, windows: usize) -> Vec<Value> {
    let snapshots = (1..=windows as u64)
        .map(|id| window(id, "a terminal", "org.example.Term", size()))
        .collect();
    let session = session(snapshots);
    let lua = lua(&session);

    match answer(&lua, chunk, Budget::DEFAULT) {
        Reply::Returned(values) => values,
        other => panic!("expected a return, and lunctl answered {other:?}"),
    }
}

fn table_of(value: &Value) -> &TableValue {
    match value {
        Value::Table(table) => table,
        other => panic!("{other:?} is not a table"),
    }
}

#[test]
fn a_window_handle_serialises_as_its_kind_and_id() {
    let values = returned("return lunette.windows()", 2);

    assert_eq!(
        table_of(&values[0]).array,
        vec![
            Value::Handle(Handle {
                kind: HandleKind::Window,
                id: Some(HandleId::Number(1)),
            }),
            Value::Handle(Handle {
                kind: HandleKind::Window,
                id: Some(HandleId::Number(2)),
            }),
        ],
    );
}

/// The userdata is minted fresh on every read, so two reads of one window are
/// two objects. The id is what makes them the same window on the wire.
#[test]
fn two_reads_of_one_window_agree_on_the_wire() {
    let values = returned("return lunette.windows()[1], lunette.windows()[1]", 1);

    assert_eq!(values[0], values[1]);
}

#[test]
fn a_sink_handle_reached_through_a_window_serialises_too() {
    let values = returned("return lunette.windows()[1].sink", 1);

    let Value::Handle(handle) = &values[0] else {
        panic!("{:?} is not a handle", values[0]);
    };
    assert_eq!(handle.kind, HandleKind::Sink);
    assert!(
        handle.id.is_some(),
        "a sink onto a window is named by the surface it reaches"
    );
}

#[test]
fn a_process_handle_serialises_as_its_kind_and_id() {
    let values = returned("return lunette.spawn{ argv = { 'true' } }", 0);

    assert_eq!(
        values,
        vec![Value::Handle(Handle {
            kind: HandleKind::Process,
            id: Some(HandleId::Number(1)),
        })],
    );
}

#[test]
fn a_seat_handle_serialises_as_its_kind_and_id() {
    let values = returned("return lunette.newSeat('second')", 0);

    let Value::Handle(handle) = &values[0] else {
        panic!("{:?} is not a handle", values[0]);
    };
    assert_eq!(handle.kind, HandleKind::Seat);
    assert!(handle.id.is_some());
}

#[test]
fn a_claim_handle_serialises_as_its_kind_and_id() {
    let values = returned(
        "return lunette.claimLayer{ window = lunette.windows()[1], width = 1024, height = 1024, \
          priority = 1 }",
        1,
    );

    let Value::Handle(handle) = &values[0] else {
        panic!("{:?} is not a handle", values[0]);
    };
    assert_eq!(handle.kind, HandleKind::Claim);
    assert!(handle.id.is_some());
}

/// What `lunctl 'for _, w in ipairs(lunette.windows()) do ... end'` is for: a
/// nested table of scalars and handles, arriving intact at the other end.
#[test]
fn a_nested_table_of_windows_survives_the_wire() {
    let values = returned(
        "local out = {} \
         for index, win in ipairs(lunette.windows()) do \
           out[index] = { handle = win, id = win.id, title = win.title, size = { win.width, win.height } } \
         end \
         return out",
        2,
    );

    let table = table_of(&values[0]);
    assert_eq!(table.array.len(), 2);
    let first = table_of(&table.array[0]);
    assert!(first.entries.contains(&(
        Key::String(b"title".to_vec()),
        Value::String(b"a terminal".to_vec())
    )));
    assert!(first.entries.contains(&(
        Key::String(b"handle".to_vec()),
        Value::Handle(Handle {
            kind: HandleKind::Window,
            id: Some(HandleId::Number(1)),
        })
    )));

    let sent = Reply::Returned(values);
    let mut buffer = Vec::new();
    write_reply(&mut buffer, &sent).expect("it fits a frame");
    assert_eq!(
        read_reply(&mut buffer.as_slice()).expect("it decodes"),
        sent
    );
}

/// A texture is a LÖVR object with no wire form. Refusing it is what keeps the
/// protocol from the `tostring` fallback the design rejects.
#[test]
fn a_chunk_returning_something_unrepresentable_is_told_so() {
    let session = session(vec![window(1, "a terminal", "org.example.Term", size())]);
    let lua = lua(&session);

    let reply = answer(&lua, "return function() end", Budget::DEFAULT);

    let Reply::Unrepresentable(message) = reply else {
        panic!("a function has no wire form, and lunctl answered {reply:?}");
    };
    assert!(message.contains("result 1"), "{message}");
}

#[test]
fn a_load_error_and_a_runtime_error_reach_the_client_apart() {
    let session = session(Vec::new());
    let lua = lua(&session);

    assert!(matches!(
        answer(&lua, "this is not lua {{{", Budget::DEFAULT),
        Reply::LoadError(_)
    ));
    assert!(matches!(
        answer(&lua, "error('deliberate')", Budget::DEFAULT),
        Reply::RuntimeError(_)
    ));
}
