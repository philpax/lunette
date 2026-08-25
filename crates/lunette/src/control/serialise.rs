//! Turning what a chunk returned into something that fits down the socket.
//!
//! [`crate::control::wire::Value`] is the shape; this is the conversion into it,
//! and the refusals that keep the conversion honest.
//!
//! # Nothing is dropped silently
//!
//! Functions, coroutines, and userdata that is not a lunette handle have no wire
//! form, and neither does a table used as a key. Each is an error naming the
//! path to the offending value, not a `tostring` fallback — dropping content that
//! cannot be represented is a correctness bug per `CONTRIBUTING.md`, and the
//! `tostring` fallback is exactly what
//! [the Lua API](../../../docs/lua-api.md#lunctl) criticises awesome's remote
//! control for. A caller that wants to ignore an unrepresentable value can strip
//! it in the chunk, where it knows what it is looking at.
//!
//! # The awkward cases, each with an answer
//!
//! - **Cycles are an error**, not a back-reference. A back-reference would be
//!   more faithful, and it would make the value tree a graph that every consumer
//!   — including `lunctl`'s own renderer — has to be total over. A chunk that
//!   wants to inspect a cyclic structure can break the cycle itself.
//! - **Shared subtables are duplicated**, and identity is not preserved. That
//!   follows from the line above: with no back-references there is nothing to
//!   share with. [`MAX_NODES`] is what keeps a wide directed acyclic graph from
//!   expanding without bound, and it produces a clean error rather than an
//!   allocation failure. It is consulted as each key is read as well as as each
//!   value is converted, so a single table too wide to carry is refused while it
//!   is being collected rather than after it has been.
//! - **Mixed array and hash parts both survive.** `{1, 2, x = 3}` is one Lua
//!   value, and `TableValue` carries both halves.
//! - **`nil` holes end the array part** and everything past one is carried under
//!   its integer key. The length operator is never consulted, because a table
//!   with a hole gives it no single answer.
//! - **NaN, the infinities, and negative zero travel as their bits.** A number
//!   that is whole and fits an `i64` becomes an integer; everything else becomes
//!   a float, so nothing is rounded into a form it did not have.
//! - **Metamethods are not honoured.** Traversal is raw, so what is serialised is
//!   what the table actually holds. `__index` can fabricate fields that do not
//!   exist and `__pairs` can hide ones that do, and a wire format whose contents
//!   depend on which of those a caller installed is not an inspection tool.
//!
//! `docs/lua-api.md` records all of this as a decision rather than as an
//! implementation detail.
//!
//! # Handles are identifiers, never addresses
//!
//! A handle serialises as its kind and the identity the session keys it on
//! (`docs/architecture.md`). Not `tostring(handle)`: addresses are reused after
//! collection, so an id derived from one could come to refer to a different
//! object — a defect that appears only under memory pressure. It is not the
//! userdata's identity in any case, since a fresh one is minted on every read;
//! `win.id` and its siblings are the stable thing, which is what this reads.
//!
//! A handle is recognised by [`HANDLE_METAFIELD`] on its metatable, which is
//! invisible to ordinary Lua indexing and is declared by each handle type
//! alongside its fields. A userdata without it — a LÖVR `Texture`, say — is
//! unrepresentable and says so.

use std::{collections::HashSet, error::Error, ffi::c_void, fmt};

use mlua::{AnyUserData, MultiValue, ObjectLike, Table, Value as LuaValue};

use crate::control::{
    identifier::is_identifier,
    wire::{Handle, HandleId, HandleKind, Key, MAX_DEPTH, TableValue, Value},
};

/// The metatable field each native handle is tagged with.
///
/// A metafield rather than a field, so it does not appear in `pairs` and is not
/// reachable through ordinary indexing: mlua routes a userdata's `__index` to
/// the fields it was registered with, and this is not one of them.
pub const HANDLE_METAFIELD: &str = "__lunettehandle";

/// How many values one reply may carry, counting every key and every value of
/// every table.
///
/// A cap turns a pathological structure — a wide directed acyclic graph, a table
/// of every window's every property — into a clean error rather than into an
/// allocation that fails somewhere unrelated.
///
/// A key counts because a key is materialised: the traversal copies every key it
/// reads before it converts any of the values, so counting only values would let
/// one very wide table allocate without bound before the cap was consulted. The
/// consequence is that a table of scalars is bounded at half this many entries,
/// which is the honest reading of "how much one reply carries".
pub const MAX_NODES: usize = 200_000;

/// Converts a chunk's return values.
///
/// # Errors
///
/// If any value, at any depth, has no wire form; if a table is cyclic; or if the
/// tree is deeper than [`MAX_DEPTH`] or larger than [`MAX_NODES`].
pub fn results(values: MultiValue) -> Result<Vec<Value>, SerialiseError> {
    let mut walk = Walk::default();
    let mut converted = Vec::with_capacity(values.len());

    for (position, value) in (1..).zip(values) {
        walk.path.push(Step::Result(position));
        converted.push(convert(&mut walk, &value)?);
        walk.path.pop();
    }

    Ok(converted)
}

/// [`results`], boxed for `crate::control::eval::evaluate`.
///
/// The seam takes a boxed error so that the evaluation does not have to know
/// what a serialiser is; this is the adaptor rather than a second conversion.
///
/// # Errors
///
/// As [`results`].
pub fn render(values: MultiValue) -> Result<Vec<Value>, Box<dyn Error + Send + Sync>> {
    results(values).map_err(|error| Box::new(error) as Box<dyn Error + Send + Sync>)
}

/// Why a value could not be put on the wire.
#[derive(Debug)]
pub enum SerialiseError {
    /// A value with no wire form at all.
    Unrepresentable { path: ValuePath, kind: String },
    /// Userdata carrying a handle tag this build does not know.
    UnknownHandle { path: ValuePath, name: String },
    /// A table that reaches itself.
    Cycle { path: ValuePath },
    /// A tree deeper than the protocol carries.
    TooDeep { path: ValuePath, limit: usize },
    /// A tree with more nodes than the protocol carries.
    TooManyNodes { limit: usize },
    /// Reading the value raised.
    ///
    /// The cause is rendered rather than kept: the answer this becomes crosses
    /// a thread to reach the client, and `mlua::Error` is neither `Send` nor
    /// `Sync` because it can hold a Lua value. Keeping it would make the whole
    /// error unable to leave the Lua thread, which is where it has to go.
    Lua { path: ValuePath, cause: String },
}

impl fmt::Display for SerialiseError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("lunctl: ")?;
        match self {
            Self::Unrepresentable { path, kind } => write!(
                formatter,
                "{path} is a {kind}, which has no form this protocol can carry; strip it in the \
                 chunk if it is not what you wanted back"
            ),
            Self::UnknownHandle { path, name } => write!(
                formatter,
                "{path} is a '{name}' handle, which this build has no wire tag for"
            ),
            Self::Cycle { path } => write!(
                formatter,
                "{path} reaches a table that already contains it, and this protocol has no \
                 back-reference to say so with"
            ),
            Self::TooDeep { path, limit } => write!(
                formatter,
                "{path} nests deeper than {limit}, which is as deep as this protocol goes"
            ),
            Self::TooManyNodes { limit } => write!(
                formatter,
                "the result holds more than {limit} values, which is more than one reply carries"
            ),
            Self::Lua { path, cause } => {
                write!(formatter, "{path} could not be read: {cause}")
            }
        }
    }
}

impl Error for SerialiseError {}

/// Where in the returned values something sits.
///
/// Rendered when the error is built rather than carried as a live borrow, so an
/// error outlives the traversal that produced it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ValuePath(String);

impl fmt::Display for ValuePath {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.0)
    }
}

/// What one traversal is carrying: where it is, what it is inside, and how much
/// it has produced.
#[derive(Default)]
struct Walk {
    path: Vec<Step>,
    /// The tables on the path from the root to here, by address. A cycle is a
    /// table that is already on it; a table that merely appears twice in
    /// different branches is not one, and is duplicated.
    open: Vec<*const c_void>,
    nodes: usize,
}

impl Walk {
    fn here(&self) -> ValuePath {
        let mut rendered = String::new();
        for step in &self.path {
            match step {
                Step::Result(position) => rendered.push_str(&format!("result {position}")),
                Step::Index(index) => rendered.push_str(&format!("[{index}]")),
                Step::Field(name) => rendered.push_str(&format!(".{name}")),
                Step::Key(key) => rendered.push_str(&format!("[{key}]")),
            }
        }
        ValuePath(rendered)
    }

    fn count(&mut self) -> Result<(), SerialiseError> {
        self.nodes += 1;
        if self.nodes > MAX_NODES {
            return Err(SerialiseError::TooManyNodes { limit: MAX_NODES });
        }
        Ok(())
    }
}

/// One segment of a path, in the form it is rendered as.
enum Step {
    Result(usize),
    Index(i64),
    /// A string key that reads as an identifier.
    Field(String),
    /// Every other key, rendered as a subscript.
    Key(String),
}

/// The step a key leads through, so an error names the way a reader would.
fn step_for(key: &Key) -> Step {
    match key {
        Key::Integer(index) => Step::Index(*index),
        Key::String(bytes) => match str::from_utf8(bytes) {
            Ok(name) if is_identifier(name) => Step::Field(name.to_owned()),
            Ok(name) => Step::Key(format!("'{name}'")),
            Err(_) => Step::Key(format!("{bytes:?}")),
        },
        Key::Boolean(answer) => Step::Key(answer.to_string()),
        Key::Float(number) => Step::Key(number.to_string()),
    }
}

fn convert(walk: &mut Walk, value: &LuaValue) -> Result<Value, SerialiseError> {
    walk.count()?;

    match value {
        LuaValue::Nil => Ok(Value::Nil),
        LuaValue::Boolean(answer) => Ok(Value::Boolean(*answer)),
        LuaValue::Integer(number) => Ok(Value::Integer(*number)),
        LuaValue::Number(number) => Ok(number_value(*number)),
        LuaValue::String(text) => Ok(Value::String(text.as_bytes().to_vec())),
        LuaValue::Table(table) => convert_table(walk, table),
        LuaValue::UserData(userdata) => convert_handle(walk, userdata),
        other => Err(SerialiseError::Unrepresentable {
            path: walk.here(),
            kind: other.type_name().to_owned(),
        }),
    }
}

/// A Lua number, as an integer where that is exact and as a float otherwise.
///
/// LuaJIT holds every number as a double, so the distinction is made here rather
/// than read off the value: a whole number inside `i64` is carried as one, and
/// everything else — a fraction, a magnitude past `i64`, an infinity, a NaN — is
/// carried by its bits.
fn number_value(number: f64) -> Value {
    // The bounds are what make the cast exact. `i64::MAX` is not representable
    // as a double, so the comparison is against the next double below it.
    const UPPER: f64 = 9_223_372_036_854_775_295.0;
    const LOWER: f64 = -9_223_372_036_854_775_808.0;

    if number.fract() == 0.0 && (LOWER..=UPPER).contains(&number) {
        // Negative zero is a whole number, and it is not the integer zero: the
        // sign is information a caller can see, so it stays a float.
        if number != 0.0 || number.is_sign_positive() {
            return Value::Integer(number as i64);
        }
    }
    Value::Float(number)
}

fn convert_table(walk: &mut Walk, table: &Table) -> Result<Value, SerialiseError> {
    let pointer = table.to_pointer();
    if walk.open.contains(&pointer) {
        return Err(SerialiseError::Cycle { path: walk.here() });
    }
    if walk.open.len() >= MAX_DEPTH {
        return Err(SerialiseError::TooDeep {
            path: walk.here(),
            limit: MAX_DEPTH,
        });
    }

    walk.open.push(pointer);
    let converted = table_body(walk, table);
    walk.open.pop();
    converted
}

fn table_body(walk: &mut Walk, table: &Table) -> Result<Value, SerialiseError> {
    // `Table::pairs` traverses with `lua_next`, which is raw: `__pairs` is not
    // consulted and `__index` cannot fabricate an entry. That is the decision
    // recorded in `docs/lua-api.md`, not an accident of the API.
    let mut pairs = Vec::new();
    for pair in table.pairs::<LuaValue, LuaValue>() {
        // Counted here rather than once the traversal reaches the values: every
        // key is copied into `pairs` as it is read, so a table wide enough to
        // exhaust the cap would otherwise be fully materialised before anything
        // noticed. A key is a node, which is what makes the cap a bound on this
        // loop as well as on the tree below it.
        walk.count()?;
        let (key, value) = pair.map_err(|cause| SerialiseError::Lua {
            path: walk.here(),
            cause: cause.to_string(),
        })?;
        pairs.push((convert_key(walk, &key)?, value));
    }

    // The contiguous run from 1, found by looking rather than by asking: a table
    // with a `nil` hole gives the length operator no single answer, and the
    // entries past the hole belong under their integer keys.
    let indices: HashSet<i64> = pairs
        .iter()
        .filter_map(|(key, _)| match key {
            Key::Integer(index) => Some(*index),
            _ => None,
        })
        .collect();
    let mut length = 0i64;
    while indices.contains(&(length + 1)) {
        length += 1;
    }

    let mut array = vec![Value::Nil; usize::try_from(length).unwrap_or(0)];
    let mut entries = Vec::new();
    for (key, value) in pairs {
        match key {
            Key::Integer(index) if index >= 1 && index <= length => {
                walk.path.push(Step::Index(index));
                // The index is in `1 ..= length` and `length` came from a
                // `usize`, so both conversions are exact.
                let slot = usize::try_from(index - 1).unwrap_or(0);
                array[slot] = convert(walk, &value)?;
                walk.path.pop();
            }
            key => {
                walk.path.push(step_for(&key));
                let value = convert(walk, &value)?;
                walk.path.pop();
                entries.push((key, value));
            }
        }
    }

    Ok(Value::Table(TableValue { array, entries }))
}

fn convert_key(walk: &mut Walk, key: &LuaValue) -> Result<Key, SerialiseError> {
    match key {
        LuaValue::Boolean(answer) => Ok(Key::Boolean(*answer)),
        LuaValue::Integer(number) => Ok(Key::Integer(*number)),
        LuaValue::Number(number) => Ok(match number_value(*number) {
            Value::Integer(number) => Key::Integer(number),
            _ => Key::Float(*number),
        }),
        LuaValue::String(text) => Ok(Key::String(text.as_bytes().to_vec())),
        other => Err(SerialiseError::Unrepresentable {
            path: walk.here(),
            kind: format!("table keyed by a {}", other.type_name()),
        }),
    }
}

fn convert_handle(walk: &mut Walk, userdata: &AnyUserData) -> Result<Value, SerialiseError> {
    // A userdata mlua did not register — a LÖVR `Texture`, for instance — has no
    // metatable this can read, and the failure is the right answer rather than
    // something to report as a fault.
    let tagged = userdata
        .metatable()
        .and_then(|metatable| metatable.get::<Option<String>>(HANDLE_METAFIELD))
        .ok()
        .flatten();

    let Some(name) = tagged else {
        return Err(SerialiseError::Unrepresentable {
            path: walk.here(),
            kind: "userdata that is not a lunette handle".to_owned(),
        });
    };

    let Some(kind) = HandleKind::from_name(&name) else {
        return Err(SerialiseError::UnknownHandle {
            path: walk.here(),
            name,
        });
    };

    let id = userdata
        .get::<LuaValue>("id")
        .map_err(|cause| SerialiseError::Lua {
            path: walk.here(),
            cause: cause.to_string(),
        })?;

    let id = match id {
        LuaValue::Nil => None,
        LuaValue::Integer(number) => Some(HandleId::Number(number)),
        LuaValue::Number(number) => Some(match number_value(number) {
            Value::Integer(number) => HandleId::Number(number),
            // A handle identifier that is not whole is a defect in whatever
            // minted it, and rounding one here would produce an id naming a
            // different object.
            _ => {
                return Err(SerialiseError::Unrepresentable {
                    path: walk.here(),
                    kind: format!("{kind} handle whose id is the fractional number {number}"),
                });
            }
        }),
        LuaValue::String(text) => Some(HandleId::Text(text.as_bytes().to_vec())),
        other => {
            return Err(SerialiseError::Unrepresentable {
                path: walk.here(),
                kind: format!("{kind} handle whose id is a {}", other.type_name()),
            });
        }
    };

    Ok(Value::Handle(Handle { kind, id }))
}

#[cfg(test)]
#[expect(
    clippy::expect_used,
    reason = "a failed expectation is how a test reports a failure; the ban is on production code"
)]
mod tests {
    use mlua::{Lua, UserData, UserDataFields};
    use pretty_assertions::assert_eq;

    use super::*;
    use crate::control::wire::{Reply, read_reply, write_reply};

    /// A handle of each shape, standing in for the session's own.
    ///
    /// A fake rather than a `Window`: what is under test is the tagging
    /// convention, and building a real handle needs a session, a snapshot, and a
    /// texture that none of this reads.
    struct FakeHandle {
        id: Option<i64>,
        text: Option<String>,
    }

    impl UserData for FakeHandle {
        fn add_fields<F: UserDataFields<Self>>(fields: &mut F) {
            fields.add_meta_field(HANDLE_METAFIELD, "window");
            fields.add_field_method_get("id", |lua, handle| {
                match (handle.id, handle.text.as_deref()) {
                    (Some(id), _) => Ok(LuaValue::Integer(id)),
                    (None, Some(text)) => Ok(LuaValue::String(lua.create_string(text)?)),
                    (None, None) => Ok(LuaValue::Nil),
                }
            });
        }
    }

    /// A userdata with no handle tag, as a LÖVR `Texture` is.
    struct Untagged;

    impl UserData for Untagged {}

    /// Runs `chunk` and serialises whatever it returned.
    fn returned(chunk: &str) -> Result<Vec<Value>, SerialiseError> {
        let lua = crate::test_lua::session_lua();
        install_handles(&lua);
        let values: MultiValue = lua
            .load(chunk)
            .eval()
            .expect("the chunk runs; only the serialisation is under test");
        results(values)
    }

    fn install_handles(lua: &Lua) {
        let globals = lua.globals();
        globals
            .set(
                "window",
                lua.create_function(|_, id: i64| {
                    Ok(FakeHandle {
                        id: Some(id),
                        text: None,
                    })
                })
                .expect("the function is created"),
            )
            .expect("it can be set");
        globals
            .set(
                "namedHandle",
                lua.create_function(|_, name: String| {
                    Ok(FakeHandle {
                        id: None,
                        text: Some(name),
                    })
                })
                .expect("the function is created"),
            )
            .expect("it can be set");
        globals
            .set(
                "idlessHandle",
                lua.create_function(|_, ()| {
                    Ok(FakeHandle {
                        id: None,
                        text: None,
                    })
                })
                .expect("the function is created"),
            )
            .expect("it can be set");
        globals
            .set(
                "untagged",
                lua.create_function(|_, ()| Ok(Untagged))
                    .expect("the function is created"),
            )
            .expect("it can be set");
    }

    fn table_of(value: &Value) -> &TableValue {
        match value {
            Value::Table(table) => table,
            other => panic!("{other:?} is not a table"),
        }
    }

    #[test]
    fn a_nested_table_survives_the_wire() {
        // The property that earns its place: this is a public wire protocol, so
        // what came out of Lua has to be what arrives at `lunctl`.
        let values = returned("return { title = 'a window', size = { 1920, 1080 } }")
            .expect("it serialises");

        let sent = Reply::Returned(values);
        let mut buffer = Vec::new();
        write_reply(&mut buffer, &sent).expect("it fits a frame");

        assert_eq!(
            read_reply(&mut buffer.as_slice()).expect("it decodes"),
            sent
        );
    }

    #[test]
    fn a_mixed_array_and_hash_table_keeps_both_parts() {
        let values = returned("return {1, 2, x = 3}").expect("it serialises");

        let table = table_of(&values[0]);
        assert_eq!(table.array, vec![Value::Integer(1), Value::Integer(2)]);
        assert_eq!(
            table.entries,
            vec![(Key::String(b"x".to_vec()), Value::Integer(3))]
        );
    }

    #[test]
    fn a_nil_hole_ends_the_array_and_what_follows_keeps_its_integer_key() {
        // `#t` gives a table with a hole no single answer, so it is never asked.
        let values = returned("local t = {1, 2} t[4] = 4 return t").expect("it serialises");

        let table = table_of(&values[0]);
        assert_eq!(table.array, vec![Value::Integer(1), Value::Integer(2)]);
        assert_eq!(
            table.entries,
            vec![(Key::Integer(4), Value::Integer(4))],
            "the entry past the hole keeps its key rather than being renumbered",
        );
    }

    #[test]
    fn an_empty_table_survives() {
        let values = returned("return {}").expect("it serialises");

        assert_eq!(table_of(&values[0]), &TableValue::default());
    }

    #[test]
    fn a_cycle_is_refused_and_names_where_it_closed() {
        let error = returned("local t = { inner = {} } t.inner.back = t return t")
            .expect_err("it reaches itself");

        let SerialiseError::Cycle { path } = &error else {
            panic!("{error} should be a cycle");
        };
        assert_eq!(path.to_string(), "result 1.inner.back");
    }

    /// A table reachable twice by different routes is not a cycle. It is
    /// duplicated, and identity is not preserved — the documented answer.
    #[test]
    fn a_shared_subtable_is_duplicated_rather_than_refused() {
        let values = returned("local shared = { 1 } return { first = shared, second = shared }")
            .expect("it serialises");

        let table = table_of(&values[0]);
        assert_eq!(table.entries.len(), 2);
        for (_, value) in &table.entries {
            assert_eq!(table_of(value).array, vec![Value::Integer(1)]);
        }
    }

    #[test]
    fn a_function_is_refused_and_names_its_path() {
        let error = returned("return { windows = { { onClose = function() end } } }")
            .expect_err("a function has no wire form");

        assert!(
            error.to_string().contains("result 1.windows[1].onClose"),
            "{error}"
        );
        assert!(error.to_string().contains("function"), "{error}");
    }

    #[test]
    fn a_coroutine_is_refused() {
        let error = returned("return coroutine.create(function() end)")
            .expect_err("a coroutine has no wire form");

        assert!(
            matches!(error, SerialiseError::Unrepresentable { .. }),
            "{error}"
        );
    }

    #[test]
    fn a_table_key_is_refused() {
        let error = returned("local t = {} t[{}] = 1 return t").expect_err("a table is not a key");

        assert!(
            error.to_string().contains("table keyed by a table"),
            "{error}"
        );
    }

    #[test]
    fn a_function_key_is_refused() {
        let error =
            returned("local t = {} t[function() end] = 1 return t").expect_err("nor a function");

        assert!(
            error.to_string().contains("table keyed by a function"),
            "{error}"
        );
    }

    #[test]
    fn a_handle_serialises_as_its_kind_and_id() {
        let values = returned("return window(7)").expect("it serialises");

        assert_eq!(
            values,
            vec![Value::Handle(Handle {
                kind: HandleKind::Window,
                id: Some(HandleId::Number(7)),
            })]
        );
    }

    /// The userdata is minted fresh on every read, so the wire form has to agree
    /// across two reads of the same thing. The id is what makes that true.
    #[test]
    fn two_reads_of_the_same_window_serialise_alike() {
        let values = returned("return window(7), window(7)").expect("it serialises");

        assert_eq!(values[0], values[1]);
    }

    #[test]
    fn a_handle_with_a_text_id_serialises_as_text() {
        // A monitor's saved identity, which is a string rather than a number.
        let values = returned("return namedHandle('Acme X24')").expect("it serialises");

        assert_eq!(
            values,
            vec![Value::Handle(Handle {
                kind: HandleKind::Window,
                id: Some(HandleId::Text(b"Acme X24".to_vec())),
            })]
        );
    }

    /// A handle for something that has gone still serialises. Its id names an
    /// object nothing will answer for, which is inert rather than misleading.
    #[test]
    fn a_handle_with_no_id_serialises_as_one_without() {
        let values = returned("return idlessHandle()").expect("it serialises");

        assert_eq!(
            values,
            vec![Value::Handle(Handle {
                kind: HandleKind::Window,
                id: None,
            })]
        );
    }

    #[test]
    fn userdata_that_is_not_a_handle_is_refused_rather_than_stringified() {
        // A LÖVR `Texture` is exactly this case, and `tostring` on one is what
        // the design rejects awesome for.
        let error = returned("return untagged()").expect_err("it is not a handle");

        assert!(
            error.to_string().contains("not a lunette handle"),
            "{error}"
        );
    }

    #[test]
    fn a_whole_number_is_an_integer_and_everything_else_is_a_float() {
        let values = returned("return 1, 1.5, -0.0, 1/0, -1/0, 0/0").expect("it serialises");

        assert_eq!(values[0], Value::Integer(1));
        assert_eq!(values[1], Value::Float(1.5));
        assert_eq!(
            values[2],
            Value::Float(-0.0),
            "negative zero keeps its sign rather than becoming the integer zero",
        );
        assert_eq!(values[3], Value::Float(f64::INFINITY));
        assert_eq!(values[4], Value::Float(f64::NEG_INFINITY));
        let Value::Float(nan) = values[5] else {
            panic!("{:?} is not a float", values[5]);
        };
        assert!(nan.is_nan());
    }

    #[test]
    fn a_string_that_is_not_utf8_survives_as_bytes() {
        // Lua strings are byte strings, and a title from a client is not
        // required to be text.
        let values = returned(r"return '\255\254'").expect("it serialises");

        assert_eq!(values, vec![Value::String(vec![0xff, 0xfe])]);
    }

    #[test]
    fn a_tree_deeper_than_the_cap_is_a_clean_error() {
        let values = returned(&format!(
            "local t = {{}} local at = t for _ = 1, {} do at.next = {{}} at = at.next end return t",
            MAX_DEPTH + 8
        ));

        let error = values.expect_err("it nests too deep");
        assert!(matches!(error, SerialiseError::TooDeep { .. }), "{error}");
    }

    #[test]
    fn a_tree_wider_than_the_cap_is_a_clean_error() {
        let values = returned(&format!(
            "local t = {{}} for i = 1, {} do t[i] = i end return t",
            MAX_NODES + 1
        ));

        let error = values.expect_err("it holds too many values");
        assert!(
            matches!(error, SerialiseError::TooManyNodes { .. }),
            "{error}"
        );
    }

    /// The cap has to bound the collecting loop, not only the conversion that
    /// follows it. A table whose entries alone exhaust it is refused while it is
    /// being read, so the keys are never all copied at once.
    #[test]
    fn a_single_table_too_wide_to_carry_is_refused_while_it_is_being_collected() {
        // Under half the cap in entries, so counting only values would let this
        // through and materialise every key first.
        let values = returned(&format!(
            "local t = {{}} for i = 1, {} do t[i] = i end return t",
            MAX_NODES / 2 + 1
        ));

        let error = values.expect_err("its keys and values together pass the cap");
        assert!(
            matches!(error, SerialiseError::TooManyNodes { .. }),
            "{error}"
        );
    }

    #[test]
    fn a_chunk_returning_nothing_serialises_to_an_empty_list() {
        assert_eq!(returned("return").expect("it serialises"), Vec::new());
    }

    #[test]
    fn a_path_reads_the_way_a_caller_wrote_it() {
        for (chunk, expected) in [
            ("return { a = function() end }", "result 1.a"),
            ("return { { function() end } }", "result 1[1][1]"),
            (
                "return { ['with space'] = function() end }",
                "result 1['with space']",
            ),
            ("return { [true] = function() end }", "result 1[true]"),
            ("return { [1.5] = function() end }", "result 1[1.5]"),
            // A reserved word is not a name, so it is written the way a reader
            // would have had to write it.
            (
                "local t = {} t['end'] = function() end return t",
                "result 1['end']",
            ),
        ] {
            let error = returned(chunk).expect_err("a function has no wire form");
            assert!(
                error.to_string().contains(expected),
                "{chunk} should name {expected}: {error}"
            );
        }
    }

    #[test]
    fn the_second_result_is_named_as_the_second() {
        let error = returned("return 1, function() end").expect_err("the second has no wire form");

        assert!(error.to_string().contains("result 2"), "{error}");
    }

    #[test]
    fn an_error_names_its_subsystem() {
        let error = returned("return function() end").expect_err("it has no wire form");
        assert!(error.to_string().starts_with("lunctl: "), "{error}");
    }
}
