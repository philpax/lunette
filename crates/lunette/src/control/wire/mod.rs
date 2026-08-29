//! What travels over the control socket, in both directions.
//!
//! A request carries a Lua chunk. A reply carries either the values the chunk
//! returned or the reason it produced none. Both are length-prefixed frames.
//! The prefix encodes the body length. A partial write leaves a frame shorter
//! than the length in its prefix, and a reader detects that shortfall as a
//! truncated frame.
//!
//! # The value tree
//!
//! [`Value`] is a tagged tree. `lunctl` prints a nested table from the tag;
//! awesome's remote control falls back to `tostring`
//! ([the Lua API](../../../docs/lua-api.md#lunctl)). The tag on each node
//! names what the node is, and nothing is inferred from its shape.
//!
//! A table carries its array part and its other entries separately, because
//! `{1, 2, x = 3}` is one Lua value with no single equivalent in a format that
//! cannot mix lists and objects. Keys are [`Key`] values. The [`Key`] type has
//! no table variant; a table-valued key, which the serialiser refuses, cannot
//! occur in the tree.
//!
//! A handle is a kind and an identifier, never a pointer.
//! `crate::control::serialise` states why an address would be wrong.
//!
//! # Versioning
//!
//! Every frame begins with [`PROTOCOL_VERSION`], at a fixed offset that will not
//! move. `lunctl` and lunette ship together, and a mismatch arises when one end
//! is replaced under a running session. The peer answers [`Reply::Incompatible`]
//! and does not parse a body of unknown shape. Bump the version when a tag's
//! meaning changes or a field is added, not when the first caller depends on
//! it. An old reader that guessed at a new body would report a value nobody
//! sent.

use std::{
    error::Error,
    fmt,
    io::{self, Read, Write},
    time::Duration,
};

use lunette_luau::closed_set;

/// The version every frame in this build carries.
///
/// Version 2 is version 1 plus [`Reply::Oversized`] and [`Reply::Malformed`]. A
/// version 1 reader has no tag for either. Adding a reply requires a bump:
/// without one, a version 1 reader would reach the new tag and report a peer
/// using a later protocol against a matching version prefix.
pub const PROTOCOL_VERSION: u8 = 2;

/// The largest frame either side will write or accept.
///
/// A frame is fully buffered, not streamed. The whole value tree is built in
/// memory, and the write follows. A reader that trusted the length prefix
/// would allocate whatever size the prefix announces. Eight mebibytes exceeds
/// what a session inspection produces, and it bounds the allocation an
/// oversized announcement can force.
pub const MAX_FRAME: usize = 8 * 1024 * 1024;

/// How deep a value tree may nest, on the wire and in the serialiser.
///
/// `luax_checkvariant` in `vendor/lovr/src/api/api.c` uses the same figure for
/// the same reason. The decoder enforces it as well as the encoder's producer,
/// because a decoder that trusted its input would overflow the stack on a
/// hostile frame.
pub const MAX_DEPTH: usize = 128;

/// A Lua value, as one side of the socket describes it to the other.
#[derive(Clone, Debug, PartialEq)]
pub enum Value {
    Nil,
    Boolean(bool),
    /// A number that is whole and fits an `i64`.
    Integer(i64),
    /// Every other number, including infinities and NaN, carried by its bits.
    /// The value arrives unchanged.
    Float(f64),
    /// Lua strings are byte strings; this is not required to be UTF-8.
    String(Vec<u8>),
    Table(TableValue),
    Handle(Handle),
}

/// A table, with its array part kept apart from everything else.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct TableValue {
    /// The contiguous run of integer keys from 1, in order. A `nil` hole ends
    /// it, and the entries past the hole are in [`Self::entries`] under their
    /// integer keys. The length operator is not used; a table with a hole has
    /// no well-defined length.
    pub array: Vec<Value>,
    /// Everything else, in the order `next` produced it. Lua gives a hash part
    /// no order of its own; one traversal reproduces this order, and a later
    /// traversal may differ.
    pub entries: Vec<(Key, Value)>,
}

/// What a table entry may be keyed by.
///
/// Keys form a closed set, separate from [`Value`]. The serialiser refuses a
/// table, a function, or a handle as a key, and the type cannot express one.
#[derive(Clone, Debug, PartialEq)]
pub enum Key {
    Boolean(bool),
    Integer(i64),
    Float(f64),
    String(Vec<u8>),
}

/// A native handle, as an identifier, never as an object.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Handle {
    pub kind: HandleKind,
    /// The identity the session keys this handle on, or `None` for a handle
    /// that has none. A sink onto a mirrored monitor is named by its monitor,
    /// not by an identifier of its own.
    pub id: Option<HandleId>,
}

closed_set! {
    /// Which of the native handle types a [`Handle`] refers to.
    ///
    /// A closed set. A handle type added without a wire tag is a compilation
    /// failure here; a string would arrive unrecognised at the other end.
    #[derive(Clone, Copy, Debug, PartialEq, Eq)]
    pub enum HandleKind {
        Window = "window",
        Monitor = "monitor",
        Process = "process",
        Seat = "seat",
        Sink = "sink",
        Claim = "claim",
        Output = "output",
    }
}

impl HandleKind {
    /// The tag byte for this kind on the wire.
    ///
    /// The tags are written out, not derived from the position in
    /// [`HandleKind::ALL`]. The tag is a wire format, and deriving it from
    /// declaration order would make reordering the variants a silent protocol
    /// break.
    const fn tag(self) -> u8 {
        match self {
            Self::Window => 0,
            Self::Monitor => 1,
            Self::Process => 2,
            Self::Seat => 3,
            Self::Sink => 4,
            Self::Claim => 5,
            Self::Output => 6,
        }
    }

    /// The kind a tag refers to.
    ///
    /// The mapping is searched, not matched, so it is stated once. A second
    /// match here would carry a wildcard; a kind missing from it would arrive
    /// as an unrecognised tag, and the compiler would not catch the omission.
    fn from_tag(tag: u8) -> Option<Self> {
        Self::ALL.iter().copied().find(|kind| kind.tag() == tag)
    }
}

/// How a handle is identified.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum HandleId {
    Number(i64),
    /// A monitor's saved identity, which is a string, not a number.
    Text(Vec<u8>),
}

impl fmt::Display for HandleId {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Number(id) => write!(formatter, "{id}"),
            Self::Text(id) => formatter.write_str(&String::from_utf8_lossy(id)),
        }
    }
}

/// What the session answers a chunk with.
#[derive(Clone, Debug, PartialEq)]
pub enum Reply {
    /// The chunk ran and returned these values, in order. A chunk returning
    /// nothing returns an empty list; an empty list is not the same as
    /// returning `nil`.
    Returned(Vec<Value>),
    /// The chunk did not compile.
    LoadError(String),
    /// The chunk compiled and raised.
    RuntimeError(String),
    /// The chunk ran past the wall-clock budget; the session abandoned it.
    Abandoned { after: Duration },
    /// The chunk returned a value that cannot be put on the wire.
    Unrepresentable(String),
    /// The queue toward the session is full; the chunk did not run.
    Busy,
    /// The session did not answer within the reply bound. Whether the chunk ran
    /// is unknown, and the reply states the uncertainty.
    Unanswered,
    /// The chunk ran, and what it returned is larger than one frame carries.
    ///
    /// Distinct from [`Self::Unrepresentable`], which is about a value with
    /// no wire form. Here the answer has a form, and the amount exceeds one
    /// frame. Closing the connection would reach the client as an end-of-file;
    /// the client can report that as an unreachable session, misstating a
    /// running session and a successful chunk.
    Oversized {
        /// The size of the answer, in bytes.
        length: u64,
    },
    /// The request could not be read: not valid UTF-8, or larger than one frame
    /// carries. The chunk did not run.
    Malformed(String),
    /// The two ends use different protocol versions.
    ///
    /// The fields are named by role, not by runtime position. A reader that
    /// finds a version it has no tag for builds one of these replies too. The
    /// found version is the session's, and the local version is the client's.
    /// Field names fixed to one point of view would print the message
    /// backwards for the other side.
    Incompatible {
        /// The version the session carries.
        session: u8,
        /// The version the client carries.
        client: u8,
    },
}

/// Writes one request frame.
///
/// # Errors
///
/// If the chunk exceeds [`MAX_FRAME`], or the write fails.
pub fn write_request(writer: &mut impl Write, chunk: &str) -> Result<(), WireError> {
    let mut body = vec![PROTOCOL_VERSION];
    body.extend_from_slice(chunk.as_bytes());
    write_frame(writer, &body)
}

/// Reads one request frame, returning the chunk it carries.
///
/// The version is returned with the chunk, not checked here. A caller that
/// finds a mismatch answers [`Reply::Incompatible`]; a caller that cannot read
/// the frame has nothing to answer.
///
/// # Errors
///
/// If the frame is truncated, oversized, or the chunk is not valid UTF-8. Lua
/// source is bytes as far as the interpreter is concerned, but a chunk arriving
/// over a socket in some other encoding is a mistake worth reporting, not
/// compiling.
pub fn read_request(reader: &mut impl Read) -> Result<Request, WireError> {
    let body = read_frame(reader)?;
    let (&version, chunk) = body.split_first().ok_or(WireError::Truncated)?;
    let chunk = String::from_utf8(chunk.to_vec()).map_err(|_| WireError::NotUtf8)?;
    Ok(Request { version, chunk })
}

/// The chunk as it arrived, with the version the sender wrote.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Request {
    pub version: u8,
    pub chunk: String,
}

/// Writes one reply frame.
///
/// # Errors
///
/// If the encoded reply exceeds [`MAX_FRAME`], or the write fails.
pub fn write_reply(writer: &mut impl Write, reply: &Reply) -> Result<(), WireError> {
    let mut body = vec![PROTOCOL_VERSION];
    encode_reply(&mut body, reply);
    write_frame(writer, &body)
}

/// Reads one reply frame.
///
/// # Errors
///
/// If the frame is truncated or oversized, if it carries a tag this build does
/// not know, or if it nests deeper than [`MAX_DEPTH`].
pub fn read_reply(reader: &mut impl Read) -> Result<Reply, WireError> {
    let body = read_frame(reader)?;
    let (&version, rest) = body.split_first().ok_or(WireError::Truncated)?;
    if version != PROTOCOL_VERSION {
        // The client reads a reply, so the version found in it is the
        // session's, and the client's own is the local one.
        return Ok(Reply::Incompatible {
            session: version,
            client: PROTOCOL_VERSION,
        });
    }

    let mut cursor = Cursor::new(rest);
    let reply = decode_reply(&mut cursor)?;
    if !cursor.finished() {
        return Err(WireError::Trailing);
    }
    Ok(reply)
}

/// Why a frame could not be written or understood.
#[derive(Debug)]
pub enum WireError {
    /// The peer closed the connection, or the frame ended mid-value.
    Truncated,
    /// The frame declared a length that exceeds [`MAX_FRAME`].
    TooLarge {
        length: usize,
    },
    /// A tag this build does not define.
    UnknownTag {
        what: &'static str,
        tag: u8,
    },
    /// A value tree deeper than [`MAX_DEPTH`].
    TooDeep {
        limit: usize,
    },
    /// The frame decoded, and bytes remained after the value.
    Trailing,
    /// A chunk that is not valid UTF-8.
    NotUtf8,
    Io(io::Error),
}

impl fmt::Display for WireError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("lunctl: ")?;
        match self {
            Self::Truncated => formatter.write_str("the message ended before it was complete"),
            Self::TooLarge { length } => write!(
                formatter,
                "a message of {length} bytes was announced, and the limit is {MAX_FRAME}"
            ),
            Self::UnknownTag { what, tag } => write!(
                formatter,
                "{tag} is not a {what} this build knows; the peer is speaking a later protocol"
            ),
            Self::TooDeep { limit } => write!(
                formatter,
                "the value nests deeper than {limit}, which is as deep as this protocol goes"
            ),
            Self::Trailing => {
                formatter.write_str("the message decoded and had bytes left over after it")
            }
            Self::NotUtf8 => formatter.write_str("the chunk is not valid utf-8"),
            Self::Io(error) => write!(formatter, "the message could not be transferred: {error}"),
        }
    }
}

impl Error for WireError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        match self {
            Self::Io(error) => Some(error),
            _ => None,
        }
    }
}

impl From<io::Error> for WireError {
    fn from(error: io::Error) -> Self {
        Self::Io(error)
    }
}

/// Writes one body behind a length prefix.
fn write_frame(writer: &mut impl Write, body: &[u8]) -> Result<(), WireError> {
    if body.len() > MAX_FRAME {
        return Err(WireError::TooLarge { length: body.len() });
    }
    // The cast is exact; the cap keeps `MAX_FRAME` below `u32`'s range.
    let length = body.len() as u32;
    writer.write_all(&length.to_le_bytes())?;
    writer.write_all(body)?;
    writer.flush()?;
    Ok(())
}

/// Reads one length-prefixed body.
fn read_frame(reader: &mut impl Read) -> Result<Vec<u8>, WireError> {
    let mut length = [0u8; 4];
    match reader.read_exact(&mut length) {
        Ok(()) => {}
        Err(error) if error.kind() == io::ErrorKind::UnexpectedEof => {
            return Err(WireError::Truncated);
        }
        Err(error) => return Err(WireError::Io(error)),
    }

    let length = u32::from_le_bytes(length) as usize;
    if length > MAX_FRAME {
        return Err(WireError::TooLarge { length });
    }

    // The allocation is bounded by the cap above, which checked the announced
    // length; trusting the prefix outright would allocate whatever a peer
    // claimed.
    let mut body = vec![0u8; length];
    match reader.read_exact(&mut body) {
        Ok(()) => Ok(body),
        Err(error) if error.kind() == io::ErrorKind::UnexpectedEof => Err(WireError::Truncated),
        Err(error) => Err(WireError::Io(error)),
    }
}

const REPLY_RETURNED: u8 = 0;
const REPLY_LOAD_ERROR: u8 = 1;
const REPLY_RUNTIME_ERROR: u8 = 2;
const REPLY_ABANDONED: u8 = 3;
const REPLY_UNREPRESENTABLE: u8 = 4;
const REPLY_BUSY: u8 = 5;
const REPLY_UNANSWERED: u8 = 6;
const REPLY_INCOMPATIBLE: u8 = 7;
const REPLY_OVERSIZED: u8 = 8;
const REPLY_MALFORMED: u8 = 9;

fn encode_reply(out: &mut Vec<u8>, reply: &Reply) {
    match reply {
        Reply::Returned(values) => {
            out.push(REPLY_RETURNED);
            encode_count(out, values.len());
            for value in values {
                encode_value(out, value);
            }
        }
        Reply::LoadError(message) => {
            out.push(REPLY_LOAD_ERROR);
            encode_bytes(out, message.as_bytes());
        }
        Reply::RuntimeError(message) => {
            out.push(REPLY_RUNTIME_ERROR);
            encode_bytes(out, message.as_bytes());
        }
        Reply::Abandoned { after } => {
            out.push(REPLY_ABANDONED);
            out.extend_from_slice(&after.as_millis().min(u128::from(u64::MAX)).to_le_bytes()[..8]);
        }
        Reply::Unrepresentable(message) => {
            out.push(REPLY_UNREPRESENTABLE);
            encode_bytes(out, message.as_bytes());
        }
        Reply::Busy => out.push(REPLY_BUSY),
        Reply::Unanswered => out.push(REPLY_UNANSWERED),
        Reply::Oversized { length } => {
            out.push(REPLY_OVERSIZED);
            out.extend_from_slice(&length.to_le_bytes());
        }
        Reply::Malformed(message) => {
            out.push(REPLY_MALFORMED);
            encode_bytes(out, message.as_bytes());
        }
        Reply::Incompatible { session, client } => {
            out.push(REPLY_INCOMPATIBLE);
            out.push(*session);
            out.push(*client);
        }
    }
}

fn decode_reply(cursor: &mut Cursor<'_>) -> Result<Reply, WireError> {
    match cursor.byte()? {
        REPLY_RETURNED => {
            let count = cursor.count()?;
            let mut values = Vec::with_capacity(cursor.at_most(count, 1));
            for _ in 0..count {
                values.push(decode_value(cursor, 0)?);
            }
            Ok(Reply::Returned(values))
        }
        REPLY_LOAD_ERROR => Ok(Reply::LoadError(cursor.string()?)),
        REPLY_RUNTIME_ERROR => Ok(Reply::RuntimeError(cursor.string()?)),
        REPLY_ABANDONED => Ok(Reply::Abandoned {
            after: Duration::from_millis(cursor.u64()?),
        }),
        REPLY_UNREPRESENTABLE => Ok(Reply::Unrepresentable(cursor.string()?)),
        REPLY_BUSY => Ok(Reply::Busy),
        REPLY_UNANSWERED => Ok(Reply::Unanswered),
        REPLY_OVERSIZED => Ok(Reply::Oversized {
            length: cursor.u64()?,
        }),
        REPLY_MALFORMED => Ok(Reply::Malformed(cursor.string()?)),
        REPLY_INCOMPATIBLE => Ok(Reply::Incompatible {
            session: cursor.byte()?,
            client: cursor.byte()?,
        }),
        tag => Err(WireError::UnknownTag { what: "reply", tag }),
    }
}

const VALUE_NIL: u8 = 0;
const VALUE_FALSE: u8 = 1;
const VALUE_TRUE: u8 = 2;
const VALUE_INTEGER: u8 = 3;
const VALUE_FLOAT: u8 = 4;
const VALUE_STRING: u8 = 5;
const VALUE_TABLE: u8 = 6;
const VALUE_HANDLE: u8 = 7;

fn encode_value(out: &mut Vec<u8>, value: &Value) {
    match value {
        Value::Nil => out.push(VALUE_NIL),
        Value::Boolean(false) => out.push(VALUE_FALSE),
        Value::Boolean(true) => out.push(VALUE_TRUE),
        Value::Integer(number) => {
            out.push(VALUE_INTEGER);
            out.extend_from_slice(&number.to_le_bytes());
        }
        Value::Float(number) => {
            out.push(VALUE_FLOAT);
            // The bits, not a rendering. An infinity and a NaN arrive
            // unchanged; a text form would round them to something else.
            out.extend_from_slice(&number.to_bits().to_le_bytes());
        }
        Value::String(bytes) => {
            out.push(VALUE_STRING);
            encode_bytes(out, bytes);
        }
        Value::Table(table) => {
            out.push(VALUE_TABLE);
            encode_count(out, table.array.len());
            for value in &table.array {
                encode_value(out, value);
            }
            encode_count(out, table.entries.len());
            for (key, value) in &table.entries {
                encode_key(out, key);
                encode_value(out, value);
            }
        }
        Value::Handle(handle) => {
            out.push(VALUE_HANDLE);
            out.push(handle.kind.tag());
            match &handle.id {
                None => out.push(0),
                Some(HandleId::Number(id)) => {
                    out.push(1);
                    out.extend_from_slice(&id.to_le_bytes());
                }
                Some(HandleId::Text(id)) => {
                    out.push(2);
                    encode_bytes(out, id);
                }
            }
        }
    }
}

fn decode_value(cursor: &mut Cursor<'_>, depth: usize) -> Result<Value, WireError> {
    if depth > MAX_DEPTH {
        return Err(WireError::TooDeep { limit: MAX_DEPTH });
    }

    match cursor.byte()? {
        VALUE_NIL => Ok(Value::Nil),
        VALUE_FALSE => Ok(Value::Boolean(false)),
        VALUE_TRUE => Ok(Value::Boolean(true)),
        VALUE_INTEGER => Ok(Value::Integer(cursor.i64()?)),
        VALUE_FLOAT => Ok(Value::Float(f64::from_bits(cursor.u64()?))),
        VALUE_STRING => Ok(Value::String(cursor.bytes()?)),
        VALUE_TABLE => {
            let count = cursor.count()?;
            let mut array = Vec::with_capacity(cursor.at_most(count, 1));
            for _ in 0..count {
                array.push(decode_value(cursor, depth + 1)?);
            }
            let count = cursor.count()?;
            // A key and a value follow, so an entry is at least two bytes.
            let mut entries = Vec::with_capacity(cursor.at_most(count, 2));
            for _ in 0..count {
                let key = decode_key(cursor)?;
                entries.push((key, decode_value(cursor, depth + 1)?));
            }
            Ok(Value::Table(TableValue { array, entries }))
        }
        VALUE_HANDLE => {
            let tag = cursor.byte()?;
            let kind = HandleKind::from_tag(tag).ok_or(WireError::UnknownTag {
                what: "handle kind",
                tag,
            })?;
            let id = match cursor.byte()? {
                0 => None,
                1 => Some(HandleId::Number(cursor.i64()?)),
                2 => Some(HandleId::Text(cursor.bytes()?)),
                tag => {
                    return Err(WireError::UnknownTag {
                        what: "handle id",
                        tag,
                    });
                }
            };
            Ok(Value::Handle(Handle { kind, id }))
        }
        tag => Err(WireError::UnknownTag { what: "value", tag }),
    }
}

fn encode_key(out: &mut Vec<u8>, key: &Key) {
    match key {
        Key::Boolean(false) => out.push(VALUE_FALSE),
        Key::Boolean(true) => out.push(VALUE_TRUE),
        Key::Integer(number) => {
            out.push(VALUE_INTEGER);
            out.extend_from_slice(&number.to_le_bytes());
        }
        Key::Float(number) => {
            out.push(VALUE_FLOAT);
            out.extend_from_slice(&number.to_bits().to_le_bytes());
        }
        Key::String(bytes) => {
            out.push(VALUE_STRING);
            encode_bytes(out, bytes);
        }
    }
}

fn decode_key(cursor: &mut Cursor<'_>) -> Result<Key, WireError> {
    match cursor.byte()? {
        VALUE_FALSE => Ok(Key::Boolean(false)),
        VALUE_TRUE => Ok(Key::Boolean(true)),
        VALUE_INTEGER => Ok(Key::Integer(cursor.i64()?)),
        VALUE_FLOAT => Ok(Key::Float(f64::from_bits(cursor.u64()?))),
        VALUE_STRING => Ok(Key::String(cursor.bytes()?)),
        tag => Err(WireError::UnknownTag { what: "key", tag }),
    }
}

fn encode_count(out: &mut Vec<u8>, count: usize) {
    // Saturating, not wrapping. A count past `u32` cannot arise from a tree
    // that fits `MAX_FRAME`; truncation would describe a shorter sequence
    // than the body contains.
    let count = u32::try_from(count).unwrap_or(u32::MAX);
    out.extend_from_slice(&count.to_le_bytes());
}

fn encode_bytes(out: &mut Vec<u8>, bytes: &[u8]) {
    encode_count(out, bytes.len());
    out.extend_from_slice(bytes);
}

/// A bounds-checked reader over a decoded frame.
struct Cursor<'a> {
    bytes: &'a [u8],
    at: usize,
}

impl<'a> Cursor<'a> {
    fn new(bytes: &'a [u8]) -> Self {
        Self { bytes, at: 0 }
    }

    fn finished(&self) -> bool {
        self.at == self.bytes.len()
    }

    /// How many items the remaining bytes can hold.
    ///
    /// The count comes from a length prefix a peer wrote, so the capacity is
    /// clamped against the bytes left in the frame, not against
    /// [`MAX_FRAME`]. An eight-byte frame announcing `u32::MAX` values would
    /// otherwise reserve four billion slots and fail on the truncated read.
    /// The bound is exact, because no encoded item is shorter than `each`.
    fn at_most(&self, count: usize, each: usize) -> usize {
        count.min((self.bytes.len() - self.at) / each)
    }

    fn take(&mut self, count: usize) -> Result<&'a [u8], WireError> {
        let end = self.at.checked_add(count).ok_or(WireError::Truncated)?;
        let slice = self.bytes.get(self.at..end).ok_or(WireError::Truncated)?;
        self.at = end;
        Ok(slice)
    }

    fn byte(&mut self) -> Result<u8, WireError> {
        Ok(self.take(1)?[0])
    }

    fn u64(&mut self) -> Result<u64, WireError> {
        let bytes: [u8; 8] = self.take(8)?.try_into().map_err(|_| WireError::Truncated)?;
        Ok(u64::from_le_bytes(bytes))
    }

    fn i64(&mut self) -> Result<i64, WireError> {
        let bytes: [u8; 8] = self.take(8)?.try_into().map_err(|_| WireError::Truncated)?;
        Ok(i64::from_le_bytes(bytes))
    }

    fn count(&mut self) -> Result<usize, WireError> {
        let bytes: [u8; 4] = self.take(4)?.try_into().map_err(|_| WireError::Truncated)?;
        Ok(u32::from_le_bytes(bytes) as usize)
    }

    fn bytes(&mut self) -> Result<Vec<u8>, WireError> {
        let count = self.count()?;
        Ok(self.take(count)?.to_vec())
    }

    fn string(&mut self) -> Result<String, WireError> {
        String::from_utf8(self.bytes()?).map_err(|_| WireError::NotUtf8)
    }
}

#[cfg(test)]
#[expect(
    clippy::expect_used,
    reason = "a failed expectation is how a test reports a failure; the ban is on production code"
)]
mod tests;
