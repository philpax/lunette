//! What `lunctl` gets back when a chunk returns the session's own handles.
//!
//! These tests use real handles, so a handle type registered without its tag,
//! or with the wrong one, fails here.

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
fn each_handle_kind_serialises_as_its_kind_and_id() {
    let values = returned(
        "return lunette.windows(), lunette.windows()[1], lunette.windows()[1], \
         lunette.windows()[1].sink, lunette.spawn{ argv = { 'true' } }, lunette.newSeat('second'), \
         lunette.claimLayer{ window = lunette.windows()[1], width = 1024, height = 1024, priority = 1 }",
        2,
    );

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
    // Each read creates fresh userdata, so the id carries a window's identity.
    assert_eq!(
        values[1], values[2],
        "two reads of one window agree on the wire"
    );
    assert_eq!(
        values[4],
        Value::Handle(Handle {
            kind: HandleKind::Process,
            id: Some(HandleId::Number(1)),
        }),
    );
    for (value, kind) in [
        (&values[3], HandleKind::Sink),
        (&values[5], HandleKind::Seat),
        (&values[6], HandleKind::Claim),
    ] {
        let Value::Handle(handle) = value else {
            panic!("{value:?} is not a handle");
        };
        assert_eq!(handle.kind, kind);
        assert!(handle.id.is_some(), "{kind:?} carries an id");
    }
}

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

/// Refusing a value with no wire form keeps the protocol from a `tostring`
/// fallback.
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
