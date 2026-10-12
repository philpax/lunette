//! The wire format's cases: what round-trips, and what a decoder answers
//! a malformed or mismatched frame with.

use std::collections::HashSet;

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
        Handle {
            kind: HandleKind::AudioCapture,
            id: Some(HandleId::Number(11)),
        },
    ] {
        let reply = Reply::Returned(vec![Value::Handle(handle.clone())]);
        assert_eq!(round_trip(&reply), reply, "{handle:?}");
    }
}

#[test]
fn every_handle_kind_has_a_distinct_tag_and_name() {
    assert_eq!(PROTOCOL_VERSION, 4);
    assert_eq!(HandleKind::AudioCapture.tag(), 8);
    assert_eq!(HandleKind::AudioCapture.as_str(), "audio-capture");

    for &kind in HandleKind::ALL {
        assert_eq!(HandleKind::from_tag(kind.tag()), Some(kind));
        assert_eq!(HandleKind::from_name(kind.as_str()), Some(kind));
    }

    let tags: HashSet<u8> = HandleKind::ALL.iter().map(|kind| kind.tag()).collect();
    assert_eq!(tags.len(), HandleKind::ALL.len(), "two kinds share a tag");
    let names: HashSet<&str> = HandleKind::NAMES.iter().copied().collect();
    assert_eq!(names.len(), HandleKind::ALL.len(), "two kinds share a name");
    assert_eq!(HandleKind::from_name("texture"), None);
}

#[test]
fn a_nan_and_the_infinities_arrive_as_themselves() {
    // A float travels as its IEEE 754 bits. A value with no faithful text
    // form keeps its exact bits.
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
fn audio_handle_protocol_version_matrix_rejects_v3_and_v4_in_both_directions() {
    const OLD_VERSION: u8 = 3;

    let mut old_request_frame = Vec::new();
    write_request(&mut old_request_frame, "return 1").expect("the request fits a frame");
    old_request_frame[4] = OLD_VERSION;
    let old_request =
        read_request(&mut old_request_frame.as_slice()).expect("the old request frame decodes");
    assert_eq!(
        old_request.version_mismatch(PROTOCOL_VERSION),
        Some(Reply::Incompatible {
            session: PROTOCOL_VERSION,
            client: OLD_VERSION,
        }),
        "a v4 session rejects a real v3 request frame",
    );

    let mut new_request_frame = Vec::new();
    write_request(&mut new_request_frame, "return 1").expect("the request fits a frame");
    let new_request =
        read_request(&mut new_request_frame.as_slice()).expect("the v4 request frame decodes");
    assert_eq!(
        new_request.version_mismatch(OLD_VERSION),
        Some(Reply::Incompatible {
            session: OLD_VERSION,
            client: PROTOCOL_VERSION,
        }),
        "a v3 session rejects a real v4 request frame",
    );

    let mut new_reply = Vec::new();
    write_reply(
        &mut new_reply,
        &Reply::Returned(vec![Value::Handle(Handle {
            kind: HandleKind::AudioCapture,
            id: Some(HandleId::Number(11)),
        })]),
    )
    .expect("the v4 reply fits a frame");
    assert_eq!(
        read_reply_for_version(&mut new_reply.as_slice(), OLD_VERSION)
            .expect("the old reader reports its mismatch before parsing new tags"),
        Reply::Incompatible {
            session: PROTOCOL_VERSION,
            client: OLD_VERSION,
        },
    );

    let mut old_reply = Vec::new();
    write_reply(&mut old_reply, &Reply::Busy).expect("the reply fits a frame");
    old_reply[4] = OLD_VERSION;
    assert_eq!(
        read_reply(&mut old_reply.as_slice()).expect("the v4 reader reports the old version"),
        Reply::Incompatible {
            session: OLD_VERSION,
            client: PROTOCOL_VERSION,
        },
        "a v4 reader rejects a v3 reply",
    );
}

/// The frame is refused at the start of writing. Nothing reaches the
/// peer, and the caller receives an error it can report.
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

/// A count prefix comes from the peer. Reserving its full value would
/// allocate four billion slots for an eight-byte frame.
#[test]
fn a_count_past_what_the_frame_holds_reserves_only_what_could_follow() {
    let mut body = vec![PROTOCOL_VERSION, REPLY_RETURNED];
    encode_count(&mut body, usize::try_from(u32::MAX).expect("it fits"));
    let mut buffer = (body.len() as u32).to_le_bytes().to_vec();
    buffer.extend_from_slice(&body);

    let error = read_reply(&mut buffer.as_slice()).expect_err("nothing follows the count");
    assert!(matches!(error, WireError::Truncated), "{error}");

    // The clamp the frame above would otherwise defeat. No value is
    // shorter than a byte, so a count past the bytes left cannot describe
    // what follows.
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

/// The decoder stops recursion at the depth cap, so a malformed frame
/// cannot exhaust the stack. The producer enforces the same cap.
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
