//! Per-window configuration state that survives Lua reloads.
//!
//! Values retain no Lua reference, so they outlive the state that set them. Persistence across
//! process restarts belongs to the standard library.

use std::{
    borrow::Borrow,
    collections::{BTreeMap, HashMap},
    error::Error,
    fmt,
};

use lunette_compositor::protocol::WindowId;
use lunette_luau::Type;

/// Stores properties by window and removes empty window entries.
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
    /// The window's own entry is removed alongside its last property.
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

    /// Returns `None` when the window or key has no stored value.
    #[must_use]
    pub fn get(&self, window: WindowId, key: &str) -> Option<&PropertyValue> {
        self.windows.get(&window)?.get(key)
    }

    /// Removes properties for closed windows. The store survives Lua reloads.
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

/// The non-empty name a property is stored under.
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

/// The Luau union of boolean, number, and string values.
#[must_use]
pub fn property_value() -> Type {
    Type::Union(vec![Type::BOOLEAN, Type::NUMBER, Type::STRING])
}

/// A persistent property value that does not retain Lua state.
#[derive(Clone, Debug, PartialEq)]
pub enum PropertyValue {
    Boolean(bool),
    /// Finite, because [`PropertyValue::number`] is the only constructor.
    Number(f64),
    Text(String),
}

impl PropertyValue {
    /// Creates a number value, refusing a non-finite one because it would persist across reloads
    /// and could propagate invalid poses.
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

/// An invalid property key or value.
#[derive(Clone, Debug, PartialEq)]
pub enum PropertyError {
    /// The key names nothing.
    EmptyKey,
    Unsupported {
        key: PropertyKey,
        /// Lua's own type name, used only in the message.
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

    /// The match is exhaustive, so a variant added to [`PropertyValue`] fails to compile here until
    /// the declared union states it.
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
