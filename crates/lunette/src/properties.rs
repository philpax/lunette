//! Per-window state that outlives the Lua state.
//!
//! A soft reload discards the Lua state and re-runs `main.luau`
//! (`docs/dev/architecture.md`); anything the standard library must remember
//! across a reload cannot be kept in Lua. State a rule can derive comes back
//! when the rules re-run; a pose the user placed by hand, a size they
//! dragged, a tag they assigned by hand do not. This store holds those.
//!
//! # `win.userdata`
//!
//! `docs/dev/architecture.md` gives windows a `userdata` field, the obvious place
//! for per-window state. It holds a Lua value, and a Lua value does not
//! survive its state being discarded. `userdata` is for state that is worth
//! keeping for the rest of the session and worth losing on a reload; this
//! store is for the rest. The two have different lifetimes, and both are
//! needed; neither replaces the other.
//!
//! # Plain values only
//!
//! [`PropertyValue`] is a boolean, a finite number, or a string, and a table
//! is refused by name. A table would hold Lua values, the same problem one
//! level down: the entries would be dangling references the moment the state
//! is discarded. A caller that requires structure encodes it into a string
//! itself and keeps the meaning of that encoding.
//!
//! # Lineage
//!
//! awesome keeps per-client state in X properties on the window, because
//! those outlive the window manager's own process, and skips or alters rule
//! application at startup when any are present. lunette has no X server, and
//! this is the adaptation: a native store that outlives the Lua state for the
//! same reason. `docs/dev/lua-api.md` records the choice.
//!
//! Writing any of this to disk, to survive a full restart, belongs to the
//! standard library, not to this module. This store is live state, keyed by
//! an identifier that a restart does not preserve.

use std::{
    borrow::Borrow,
    collections::{BTreeMap, HashMap},
    error::Error,
    fmt,
};

use lunette_compositor::protocol::WindowId;
use lunette_luau::Type;

/// The properties every window is carrying, keyed by window.
///
/// Empty until something is stored. A window with no properties occupies
/// nothing; most windows never acquire one.
#[derive(Debug, Default)]
pub struct WindowProperties {
    windows: HashMap<WindowId, BTreeMap<PropertyKey, PropertyValue>>,
}

impl WindowProperties {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Stores `value` under `key` for `window`, replacing what was there.
    pub fn set(&mut self, window: WindowId, key: PropertyKey, value: PropertyValue) {
        self.windows.entry(window).or_default().insert(key, value);
    }

    /// Removes `key` from `window`, reporting whether it held anything.
    ///
    /// The window's own entry is removed alongside its last property. A window that
    /// acquires and then loses every property costs the same as one that never
    /// had any.
    pub fn clear(&mut self, window: WindowId, key: &str) -> bool {
        let Some(properties) = self.windows.get_mut(&window) else {
            return false;
        };

        let removed = properties.remove(key).is_some();
        if properties.is_empty() {
            self.windows.remove(&window);
        }
        removed
    }

    /// What `window` holds under `key`, if anything.
    ///
    /// An absent key is `None`, not an error. A configuration asking for a
    /// pose it has not yet placed is the ordinary first case.
    #[must_use]
    pub fn get(&self, window: WindowId, key: &str) -> Option<&PropertyValue> {
        self.windows.get(&window)?.get(key)
    }

    /// Everything `window` holds, in key order.
    ///
    /// The order does not depend on the hash of keys the caller supplied. The
    /// order is not part of the Lua surface, because a Lua table has none; the
    /// fixed order lets a test assert one answer.
    pub fn of(&self, window: WindowId) -> impl Iterator<Item = (&PropertyKey, &PropertyValue)> {
        self.windows.get(&window).into_iter().flatten()
    }

    /// Drops the properties of every window `live` does not name.
    ///
    /// Called once per frame with the windows the frame can still describe.
    /// Entries live as long as the window does, not as long as the Lua state; a
    /// reload leaves them untouched, and a window closing removes its properties.
    pub fn retain(&mut self, live: &[WindowId]) {
        self.windows.retain(|window, _| live.contains(window));
    }

    /// How many windows are carrying properties, for the tests that assert the
    /// store empties.
    #[must_use]
    pub fn len(&self) -> usize {
        self.windows.len()
    }

    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.windows.is_empty()
    }
}

/// The name a property is stored under.
///
/// A newtype over `String`, because the store's whole surface takes a key,
/// and a bare `String` argument could be the value.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct PropertyKey(String);

impl PropertyKey {
    /// Reads a key, refusing one that names nothing.
    ///
    /// # Errors
    ///
    /// If the key is empty.
    pub fn new(key: impl Into<String>) -> Result<Self, PropertyError> {
        let key = key.into();
        if key.is_empty() {
            return Err(PropertyError::EmptyKey);
        }
        Ok(Self(key))
    }

    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

/// A lookup borrows the caller's string without allocating a key to discard
/// afterwards.
impl Borrow<str> for PropertyKey {
    fn borrow(&self) -> &str {
        &self.0
    }
}

impl fmt::Display for PropertyKey {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.0)
    }
}

/// The Luau type of [`PropertyValue`], in the order the union states it.
///
/// Built from structure. What a property is declared to hold carries no
/// punctuation of its own: whether it ends up optional or inside a table
/// is the caller's to decide, and the rendering follows from the structure.
/// `the_declared_union_covers_every_variant` verifies the union against the
/// enum.
#[must_use]
pub fn property_value() -> Type {
    Type::Union(vec![Type::BOOLEAN, Type::NUMBER, Type::STRING])
}

/// What a property may hold.
///
/// Not a Lua value. Tables are refused by name, because a Lua table would
/// dangle once the state it belongs to is discarded. See the module
/// documentation.
#[derive(Clone, Debug, PartialEq)]
pub enum PropertyValue {
    Boolean(bool),
    /// Finite. [`PropertyValue::number`] is the only constructor, so an infinity
    /// or a nan cannot be stored.
    Number(f64),
    Text(String),
}

impl PropertyValue {
    /// Reads a number, refusing one that is not finite.
    ///
    /// A nan or an infinity here is a defect in the caller's maths; the
    /// likeliest source is a pose derived from a zero-length vector. Storing
    /// it returns the same broken value after a reload, where it is harder to
    /// trace. `lunette.claimLayer` refuses a nan priority for the same reason.
    ///
    /// # Errors
    ///
    /// If the number is not finite.
    pub fn number(key: &PropertyKey, value: f64) -> Result<Self, PropertyError> {
        if !value.is_finite() {
            return Err(PropertyError::NotFinite {
                key: key.clone(),
                value,
            });
        }
        Ok(Self::Number(value))
    }
}

/// What a caller supplied that the store cannot hold.
#[derive(Clone, Debug, PartialEq)]
pub enum PropertyError {
    /// The key names nothing.
    EmptyKey,
    /// The value is of a kind the store cannot hold.
    Unsupported {
        key: PropertyKey,
        /// What the value is, for the message. Lua's own type name; message
        /// content, not something anything branches on.
        kind: &'static str,
    },
    /// The number is a nan or an infinity.
    NotFinite { key: PropertyKey, value: f64 },
}

impl fmt::Display for PropertyError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::EmptyKey => formatter.write_str("properties: a property key cannot be empty"),
            Self::Unsupported { key, kind } => write!(
                formatter,
                "properties: '{key}' cannot hold a {kind}; a property is a number, a string, or a \
                 boolean, because the store outlives the Lua state and a {kind} would not"
            ),
            Self::NotFinite { key, value } => write!(
                formatter,
                "properties: '{key}' cannot hold {value}; a property number has to be finite"
            ),
        }
    }
}

impl Error for PropertyError {}

#[cfg(test)]
#[expect(
    clippy::expect_used,
    reason = "a failed expectation is how a test reports a failure; the ban is on production code"
)]
mod tests {
    use pretty_assertions::assert_eq;

    use super::*;

    /// The declared union and the enum are two statements of one set; this test
    /// keeps the two statements equal. The match is exhaustive, so a variant
    /// added to [`PropertyValue`] fails to compile here until the declared
    /// union states it.
    #[test]
    fn the_declared_union_covers_every_variant() {
        let Type::Union(members) = property_value() else {
            panic!("a property value is a union")
        };

        for value in [
            PropertyValue::Boolean(false),
            PropertyValue::Number(0.0),
            PropertyValue::Text(String::new()),
        ] {
            let declared = match value {
                PropertyValue::Boolean(_) => Type::BOOLEAN,
                PropertyValue::Number(_) => Type::NUMBER,
                PropertyValue::Text(_) => Type::STRING,
            };
            assert!(
                members.contains(&declared),
                "{declared} is missing from the declared union"
            );
        }

        assert_eq!(
            members.len(),
            3,
            "the union carries a member with no variant"
        );
    }

    fn window(raw: u64) -> WindowId {
        WindowId::new(raw).expect("non-zero")
    }

    fn key(name: &str) -> PropertyKey {
        PropertyKey::new(name).expect("a non-empty key")
    }

    #[test]
    fn a_stored_value_reads_back() {
        let mut properties = WindowProperties::new();
        properties.set(window(1), key("pose"), PropertyValue::Text("0 1 0".into()));

        assert_eq!(
            properties.get(window(1), "pose"),
            Some(&PropertyValue::Text("0 1 0".into()))
        );
    }

    #[test]
    fn an_absent_key_is_nothing_rather_than_an_error() {
        let mut properties = WindowProperties::new();
        properties.set(window(1), key("pose"), PropertyValue::Boolean(true));

        assert_eq!(properties.get(window(1), "tag"), None);
        assert_eq!(properties.get(window(2), "pose"), None);
    }

    #[test]
    fn a_second_write_replaces_the_first() {
        let mut properties = WindowProperties::new();
        properties.set(window(1), key("width"), PropertyValue::Number(1.0));
        properties.set(window(1), key("width"), PropertyValue::Number(2.0));

        assert_eq!(
            properties.get(window(1), "width"),
            Some(&PropertyValue::Number(2.0))
        );
        assert_eq!(properties.of(window(1)).count(), 1);
    }

    #[test]
    fn two_windows_do_not_share_a_key() {
        let mut properties = WindowProperties::new();
        properties.set(window(1), key("tag"), PropertyValue::Text("left".into()));
        properties.set(window(2), key("tag"), PropertyValue::Text("right".into()));

        assert_eq!(
            properties.get(window(1), "tag"),
            Some(&PropertyValue::Text("left".into()))
        );
        assert_eq!(
            properties.get(window(2), "tag"),
            Some(&PropertyValue::Text("right".into()))
        );
    }

    #[test]
    fn clearing_removes_the_key_and_the_window_with_its_last_one() {
        let mut properties = WindowProperties::new();
        properties.set(window(1), key("tag"), PropertyValue::Boolean(true));

        assert!(properties.clear(window(1), "tag"));
        assert_eq!(properties.get(window(1), "tag"), None);
        assert!(
            properties.is_empty(),
            "a window that lost its last property costs nothing"
        );
    }

    #[test]
    fn clearing_what_was_never_set_reports_that_and_raises_nothing() {
        let mut properties = WindowProperties::new();

        assert!(!properties.clear(window(1), "tag"));
        properties.set(window(1), key("tag"), PropertyValue::Boolean(true));
        assert!(!properties.clear(window(1), "pose"));
    }

    #[test]
    fn everything_a_window_holds_comes_back_in_key_order() {
        let mut properties = WindowProperties::new();
        properties.set(window(1), key("pose"), PropertyValue::Number(1.0));
        properties.set(window(1), key("actual"), PropertyValue::Number(2.0));
        properties.set(window(1), key("tag"), PropertyValue::Number(3.0));

        let names: Vec<&str> = properties
            .of(window(1))
            .map(|(key, _)| key.as_str())
            .collect();
        assert_eq!(names, vec!["actual", "pose", "tag"]);
        assert_eq!(properties.of(window(2)).count(), 0);
    }

    #[test]
    fn a_window_the_frame_no_longer_names_loses_its_properties() {
        let mut properties = WindowProperties::new();
        properties.set(window(1), key("tag"), PropertyValue::Boolean(true));
        properties.set(window(2), key("tag"), PropertyValue::Boolean(true));

        properties.retain(&[window(2)]);

        assert_eq!(properties.get(window(1), "tag"), None);
        assert_eq!(
            properties.get(window(2), "tag"),
            Some(&PropertyValue::Boolean(true))
        );
        assert_eq!(properties.len(), 1);
    }

    #[test]
    fn retaining_nothing_empties_the_store() {
        let mut properties = WindowProperties::new();
        properties.set(window(1), key("tag"), PropertyValue::Boolean(true));

        properties.retain(&[]);

        assert!(properties.is_empty());
    }

    #[test]
    fn an_empty_key_names_nothing_and_is_refused() {
        assert_eq!(PropertyKey::new(""), Err(PropertyError::EmptyKey));
        assert_eq!(
            PropertyError::EmptyKey.to_string(),
            "properties: a property key cannot be empty"
        );
    }

    #[test]
    fn a_number_that_is_not_finite_is_refused_and_the_message_names_the_key() {
        for value in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY] {
            let error = PropertyValue::number(&key("pose"), value)
                .expect_err("a value that is not finite is refused");
            assert!(
                error.to_string().contains("'pose'"),
                "unhelpful message: {error}"
            );
        }

        assert_eq!(
            PropertyValue::number(&key("pose"), 1.5),
            Ok(PropertyValue::Number(1.5))
        );
    }

    #[test]
    fn the_message_for_an_unsupported_value_names_the_key_and_what_it_was() {
        let error = PropertyError::Unsupported {
            key: key("layout"),
            kind: "table",
        };

        let message = error.to_string();
        assert!(message.contains("'layout'"), "unhelpful message: {message}");
        assert!(message.contains("table"), "unhelpful message: {message}");
    }
}
