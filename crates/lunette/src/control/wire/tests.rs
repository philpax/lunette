//! The wire format's own cases: what round-trips, and what a hostile or
//! mismatched frame is answered with.

use pretty_assertions::assert_eq;

use super::*;

fn round_trip(reply: &Reply) -> Reply {
    let mut buffer = Vec::new();
    write_reply(&mut buffer, reply).expect("the reply fits a frame");
    read_reply(&mut buffer.as_slice()).expect("the reply decodes")
}

#[test]
fn a_nested_table_round_trips() {
    let reply = Reply::Returned(vec![Value::Table(TableValue {
        array: vec![
            Value::Integer(1),
            Value::Table(TableValue {
                array: vec![Value::String(b"deep".to_vec())],
                entries: Vec::new(),
            }),
        ],
        entries: vec![(
            Key::String(b"title".to_vec()),
            Value::String(b"a window".to_vec()),
        )],
    })]);

    assert_eq!(round_trip(&reply), reply);
}

#[test]
fn a_mixed_array_and_hash_table_keeps_both_parts() {
    // `{1, 2, x = 3}`, which has no equivalent in a format with only lists
    // or only objects.
    let reply = Reply::Returned(vec![Value::Table(TableValue {
        array: vec![Value::Integer(1), Value::Integer(2)],
        entries: vec![(Key::String(b"x".to_vec()), Value::Integer(3))],
    })]);

    assert_eq!(round_trip(&reply), reply);
}

#[test]
fn every_key_shape_round_trips() {
    let reply = Reply::Returned(vec![Value::Table(TableValue {
        array: Vec::new(),
        entries: vec![
            (Key::Boolean(true), Value::Nil),
            (Key::Boolean(false), Value::Nil),
            (Key::Integer(-7), Value::Nil),
            (Key::Float(0.5), Value::Nil),
            (Key::String(vec![0xff, 0x00]), Value::Nil),
        ],
    })]);

    assert_eq!(round_trip(&reply), reply);
}

#[test]
fn a_handle_round_trips_by_kind_and_id() {
    for handle in [
        Handle {
            kind: HandleKind::Window,
            id: Some(HandleId::Number(3)),
        },
        Handle {
            kind: HandleKind::Monitor,
            id: Some(HandleId::Text(b"Acme X24".to_vec())),
        },
        Handle {
            kind: HandleKind::Sink,
            id: None,
        },
    ] {
        let reply = Reply::Returned(vec![Value::Handle(handle.clone())]);
        assert_eq!(round_trip(&reply), reply, "{handle:?}");
    }
}

#[test]
fn every_handle_kind_has_a_distinct_tag_and_name() {
    let kinds = [
        HandleKind::Window,
        HandleKind::Monitor,
        HandleKind::Process,
        HandleKind::Seat,
        HandleKind::Sink,
        HandleKind::Claim,
    ];
    for kind in kinds {
        assert_eq!(HandleKind::from_tag(kind.tag()), Some(kind));
        assert_eq!(HandleKind::named(kind.as_str()), Some(kind));
    }
    assert_eq!(HandleKind::named("texture"), None);
}

#[test]
fn a_nan_and_the_infinities_arrive_as_themselves() {
    // The bits are what is written, so a value with no faithful text form
    // is not silently rounded into one.
    let mut buffer = Vec::new();
    let reply = Reply::Returned(vec![
        Value::Float(f64::NAN),
        Value::Float(f64::INFINITY),
        Value::Float(f64::NEG_INFINITY),
        Value::Float(-0.0),
    ]);
    write_reply(&mut buffer, &reply).expect("the reply fits a frame");

    let Reply::Returned(values) = read_reply(&mut buffer.as_slice()).expect("it decodes") else {
        panic!("a returned reply decodes as one");
    };
    let bits: Vec<u64> = values
        .iter()
        .map(|value| match value {
            Value::Float(number) => number.to_bits(),
            other => panic!("{other:?} is not a float"),
        })
        .collect();
    assert_eq!(
        bits,
        vec![
            f64::NAN.to_bits(),
            f64::INFINITY.to_bits(),
            f64::NEG_INFINITY.to_bits(),
            (-0.0f64).to_bits(),
        ]
    );
}

#[test]
fn every_reply_shape_round_trips() {
    for reply in [
        Reply::Returned(Vec::new()),
        Reply::Returned(vec![Value::Nil, Value::Boolean(true), Value::Integer(-1)]),
        Reply::LoadError("a syntax error".to_owned()),
        Reply::RuntimeError("it raised".to_owned()),
        Reply::Abandoned {
            after: Duration::from_millis(250),
        },
        Reply::Unrepresentable("result 1 is a function".to_owned()),
        Reply::Busy,
        Reply::Unanswered,
        Reply::Oversized { length: 9_000_000 },
        Reply::Malformed("the chunk is not valid utf-8".to_owned()),
        Reply::Incompatible {
            session: 1,
            client: 9,
        },
    ] {
        assert_eq!(round_trip(&reply), reply, "{reply:?}");
    }
}

#[test]
fn a_request_round_trips() {
    let mut buffer = Vec::new();
    write_request(&mut buffer, "return 1 + 1").expect("the chunk fits a frame");

    assert_eq!(
        read_request(&mut buffer.as_slice()).expect("it decodes"),
        Request {
            version: PROTOCOL_VERSION,
            chunk: "return 1 + 1".to_owned(),
        }
    );
}

#[test]
fn a_frame_from_another_protocol_version_is_named_rather_than_parsed() {
    // The version byte is at a fixed offset that will not move, so a peer
    // from either side of a change can always read it.
    let mut buffer = Vec::new();
    write_reply(&mut buffer, &Reply::Busy).expect("the reply fits a frame");
    buffer[4] = PROTOCOL_VERSION.wrapping_add(1);

    assert_eq!(
        read_reply(&mut buffer.as_slice()).expect("the version is still readable"),
        Reply::Incompatible {
            // The reader of a reply is the client, so the version in the
            // frame is the session's whichever side wrote it.
            session: PROTOCOL_VERSION.wrapping_add(1),
            client: PROTOCOL_VERSION,
        }
    );
}

/// The frame is refused before it is written, so nothing reaches the peer
/// and the caller has something to say instead of a closed connection.
#[test]
fn a_reply_larger_than_a_frame_is_refused_before_any_of_it_is_written() {
    let mut buffer = Vec::new();
    let reply = Reply::Returned(vec![Value::String(vec![b'x'; MAX_FRAME + 1])]);

    let error = write_reply(&mut buffer, &reply).expect_err("it does not fit");

    assert!(matches!(error, WireError::TooLarge { .. }), "{error}");
    assert!(
        buffer.is_empty(),
        "a partial frame would leave the stream unusable for the substitute"
    );
}

/// A count is a peer's claim about what follows, and reserving against it
/// would let eight bytes ask for four billion slots.
#[test]
fn a_count_past_what_the_frame_holds_reserves_only_what_could_follow() {
    let mut body = vec![PROTOCOL_VERSION, REPLY_RETURNED];
    encode_count(&mut body, usize::try_from(u32::MAX).expect("it fits"));
    let mut buffer = (body.len() as u32).to_le_bytes().to_vec();
    buffer.extend_from_slice(&body);

    let error = read_reply(&mut buffer.as_slice()).expect_err("nothing follows the count");
    assert!(matches!(error, WireError::Truncated), "{error}");

    // The clamp itself, which is what the frame above would otherwise
    // defeat: no value is shorter than a byte, so a count larger than the
    // bytes left cannot describe what follows.
    let cursor = Cursor::new(&[0u8; 4]);
    assert_eq!(cursor.at_most(usize::MAX, 1), 4);
    assert_eq!(cursor.at_most(usize::MAX, 2), 2);
    assert_eq!(cursor.at_most(1, 1), 1);
}

#[test]
fn a_truncated_frame_is_reported_rather_than_guessed_at() {
    let mut buffer = Vec::new();
    write_reply(&mut buffer, &Reply::RuntimeError("it raised".to_owned()))
        .expect("the reply fits a frame");
    buffer.truncate(buffer.len() - 3);

    let error = read_reply(&mut buffer.as_slice()).expect_err("the frame is short");
    assert!(matches!(error, WireError::Truncated), "{error}");
}

#[test]
fn a_length_prefix_past_the_cap_is_refused_before_anything_is_allocated() {
    let mut buffer = u32::MAX.to_le_bytes().to_vec();
    buffer.push(PROTOCOL_VERSION);

    let error = read_reply(&mut buffer.as_slice()).expect_err("the frame is oversized");
    assert!(matches!(error, WireError::TooLarge { .. }), "{error}");
}

#[test]
fn a_tag_this_build_does_not_know_is_refused() {
    let mut body = vec![PROTOCOL_VERSION, REPLY_RETURNED];
    encode_count(&mut body, 1);
    body.push(200);
    let mut buffer = (body.len() as u32).to_le_bytes().to_vec();
    buffer.extend_from_slice(&body);

    let error = read_reply(&mut buffer.as_slice()).expect_err("200 is not a value tag");
    assert!(
        matches!(
            error,
            WireError::UnknownTag {
                what: "value",
                tag: 200
            }
        ),
        "{error}"
    );
}

/// A hostile frame must not recurse until the stack runs out, so the cap
/// belongs to the decoder as much as to the producer.
#[test]
fn a_frame_nesting_past_the_cap_is_refused_rather_than_overflowing() {
    let mut body = vec![PROTOCOL_VERSION, REPLY_RETURNED];
    encode_count(&mut body, 1);
    for _ in 0..MAX_DEPTH + 8 {
        body.push(VALUE_TABLE);
        encode_count(&mut body, 1);
    }
    body.push(VALUE_NIL);
    let mut buffer = (body.len() as u32).to_le_bytes().to_vec();
    buffer.extend_from_slice(&body);

    let error = read_reply(&mut buffer.as_slice()).expect_err("it nests too deep");
    assert!(matches!(error, WireError::TooDeep { .. }), "{error}");
}

#[test]
fn a_frame_with_bytes_left_over_is_refused() {
    let mut body = vec![PROTOCOL_VERSION, REPLY_BUSY, 0];
    let mut buffer = (body.len() as u32).to_le_bytes().to_vec();
    buffer.append(&mut body);

    let error = read_reply(&mut buffer.as_slice()).expect_err("there is a trailing byte");
    assert!(matches!(error, WireError::Trailing), "{error}");
}

#[test]
fn a_chunk_that_is_not_utf8_is_reported() {
    let body = vec![PROTOCOL_VERSION, 0xff, 0xfe];
    let mut buffer = (body.len() as u32).to_le_bytes().to_vec();
    buffer.extend_from_slice(&body);

    let error = read_request(&mut buffer.as_slice()).expect_err("the chunk is not utf-8");
    assert!(matches!(error, WireError::NotUtf8), "{error}");
}

#[test]
fn an_error_names_its_subsystem() {
    assert!(WireError::Truncated.to_string().starts_with("lunctl: "));
}
