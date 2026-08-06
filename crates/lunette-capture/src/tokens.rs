//! The restore tokens that let a later session skip the portal's dialog.
//!
//! A ScreenCast restore token is single-use. The portal invalidates the one it
//! was given and returns a **new** one in every `Start` response, so a client
//! that stores only the first token has restore on the second run and a prompt
//! on the third. [`TokenStore::record`] is therefore called after every grant,
//! not only when nothing was stored.
//!
//! The store is keyed by [`MonitorKey`], so a token follows the monitor rather
//! than the port it was plugged into.
//!
//! # The file, and the versions of it
//!
//! [`TokenStore::parse`] and [`TokenStore::render`] are the whole of the
//! format, and both are pure. The version matrix is answered by construction:
//!
//! - A new lunette reading an old file gets `#[serde(default)]` for the fields
//!   that did not exist.
//! - An old lunette reading a new file gets [`Loaded::FromTheFuture`], which
//!   carries no [`TokenStore`] at all. That is the case worth designing for:
//!   rewriting a file whose fields this version cannot represent would drop
//!   them, corrupting the file rather than failing on it. There is no store to
//!   render, so there is nothing to write back.
//! - Anything else in the file is refused rather than ignored
//!   (`deny_unknown_fields`), so a typo is reported instead of silently
//!   discarding a token on the next write.
//!
//! Losing this file costs one portal dialog. It is not worth a repair path.

use std::{error::Error, fmt, fs, io, path::Path};

use serde::{Deserialize, Serialize};
use tracing::warn;

use crate::{
    monitor::name::MonitorKey,
    portal::{GrantedPersistMode, PersistMode, RestoreToken},
};

/// What this version of lunette writes.
///
/// Bumped when a field is added, not when one is first depended on: a default
/// lets a new reader parse an old file, but only the version stops an old
/// writer rewriting a new one.
pub const CURRENT_VERSION: FormatVersion = FormatVersion(1);

/// The format version the file declares.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct FormatVersion(u32);

impl fmt::Display for FormatVersion {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "version {}", self.0)
    }
}

/// The tokens lunette holds for the monitors it has mirrored.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct TokenStore {
    entries: Vec<Entry>,
}

impl TokenStore {
    #[must_use]
    pub const fn new() -> Self {
        Self {
            entries: Vec::new(),
        }
    }

    /// Reads a store from the file's text.
    ///
    /// # Errors
    ///
    /// When the text is not the format at all. A file from a later version is
    /// not an error: it is [`Loaded::FromTheFuture`], because the caller has to
    /// be able to tell "this is broken" from "this is newer than me".
    pub fn parse(text: &str) -> Result<Loaded, TokenStoreError> {
        let probe: VersionProbe = toml::from_str(text).map_err(TokenStoreError::Parse)?;
        if probe.version > CURRENT_VERSION {
            return Ok(Loaded::FromTheFuture {
                found: probe.version,
                supported: CURRENT_VERSION,
            });
        }

        let file: StoredFile = toml::from_str(text).map_err(TokenStoreError::Parse)?;
        Ok(Loaded::Store(Self {
            entries: file.monitors,
        }))
    }

    /// Renders the store as the file's text.
    ///
    /// Entries are ordered by their key, so a store that has not changed
    /// renders identically and the file does not churn between runs.
    ///
    /// # Errors
    ///
    /// When the store cannot be rendered as TOML, which needs a key or token
    /// holding something the format has no encoding for.
    pub fn render(&self) -> Result<String, TokenStoreError> {
        let mut monitors = self.entries.clone();
        monitors.sort_by_key(Entry::sort_key);

        toml::to_string_pretty(&StoredFile {
            version: CURRENT_VERSION,
            monitors,
        })
        .map_err(TokenStoreError::Render)
    }

    /// The token to offer for a monitor's next session, if one is held.
    #[must_use]
    pub fn token_for(&self, monitor: &MonitorKey) -> Option<&RestoreToken> {
        self.find(monitor).map(|entry| &entry.token)
    }

    /// What the backend granted for this monitor last time, if it said.
    ///
    /// `None` covers both "no token is held" and "the backend did not state
    /// what it granted". The two are distinguishable through
    /// [`Self::token_for`], and neither changes what lunette does next: it
    /// offers the token it has and expects a prompt regardless.
    #[must_use]
    pub fn persistence_for(&self, monitor: &MonitorKey) -> Option<PersistMode> {
        self.find(monitor).and_then(|entry| entry.persist)
    }

    /// Records what a `Start` response granted for a monitor.
    ///
    /// The response's token replaces whatever was held, because the one that
    /// was offered has just been spent. A response carrying no token means the
    /// backend did not persist the session, so the held token is spent and
    /// useless: the entry is dropped rather than left to fail silently on the
    /// next launch.
    ///
    /// The granted mode is stored, never the requested one. Backends may
    /// downgrade, and xdg-desktop-portal-wlr does (`screencast.c:171-181`), so
    /// storing what was asked for produces a record that lies about what the
    /// next run will do. [`GrantedPersistMode::Unstated`] stores nothing rather
    /// than guessing.
    pub fn record(
        &mut self,
        monitor: MonitorKey,
        token: Option<RestoreToken>,
        granted: GrantedPersistMode,
    ) {
        let Some(token) = token else {
            if self.forget(&monitor) {
                warn!(
                    %monitor,
                    "the portal granted the session without a restore token, so the token held for \
                     this monitor has been spent and the next launch will prompt",
                );
            }
            return;
        };

        let persist = match granted {
            GrantedPersistMode::Granted(mode) => Some(mode),
            GrantedPersistMode::Unstated => None,
        };

        match self.entries.iter_mut().find(|entry| entry.key == monitor) {
            Some(entry) => {
                entry.token = token;
                entry.persist = persist;
            }
            None => self.entries.push(Entry {
                key: monitor,
                token,
                persist,
            }),
        }
    }

    /// Drops a monitor's token. Reports whether one was held.
    pub fn forget(&mut self, monitor: &MonitorKey) -> bool {
        let before = self.entries.len();
        self.entries.retain(|entry| &entry.key != monitor);
        self.entries.len() != before
    }

    /// How many monitors have a token held for them.
    #[must_use]
    pub fn len(&self) -> usize {
        self.entries.len()
    }

    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    fn find(&self, monitor: &MonitorKey) -> Option<&Entry> {
        self.entries.iter().find(|entry| &entry.key == monitor)
    }
}

/// What reading the file produced.
///
/// The variants are not interchangeable, and that is the point: only
/// [`Self::Store`] and [`Self::Absent`] carry a [`TokenStore`], so a file this
/// version cannot represent has nothing that could be rendered back over it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Loaded {
    /// The file parsed.
    Store(TokenStore),
    /// No file existed. Ordinary on a first run.
    Absent,
    /// The file was written by a later lunette.
    ///
    /// Restore is unavailable this session and the file must not be rewritten:
    /// rendering this version's fields over it would drop the ones this version
    /// does not know about.
    FromTheFuture {
        found: FormatVersion,
        supported: FormatVersion,
    },
}

impl Loaded {
    /// The store to use this session, which is empty when there is none.
    ///
    /// A caller that wants to write back has to match on the variant instead:
    /// this consumes the distinction that makes writing safe, so it is for
    /// reading only.
    #[must_use]
    pub fn for_reading(self) -> TokenStore {
        match self {
            Self::Store(store) => store,
            Self::Absent | Self::FromTheFuture { .. } => TokenStore::new(),
        }
    }
}

/// Reads the store at a path.
///
/// The path is a parameter, never an environment lookup: this is a library, and
/// the process's own configuration belongs to whatever started it.
///
/// # Errors
///
/// When the file exists but cannot be read or parsed. A file that does not
/// exist is [`Loaded::Absent`].
pub fn read(path: &Path) -> Result<Loaded, TokenStoreError> {
    let text = match fs::read_to_string(path) {
        Ok(text) => text,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(Loaded::Absent),
        Err(error) => {
            return Err(TokenStoreError::Read {
                path: path.display().to_string(),
                cause: error,
            });
        }
    };

    TokenStore::parse(&text)
}

/// Writes the store to a path, replacing whatever was there.
///
/// Through a sibling temporary file and a rename, so an interrupted write
/// leaves the previous tokens rather than a truncated file. The cost of losing
/// the file is one portal dialog, but the cost of half a file is a parse error
/// on every launch until the user finds and deletes it.
///
/// # Errors
///
/// When the directory cannot be written to, or the rename fails.
pub fn write(path: &Path, store: &TokenStore) -> Result<(), TokenStoreError> {
    let text = store.render()?;
    let scratch = path.with_extension("toml.new");

    let failed = |cause| TokenStoreError::Write {
        path: path.display().to_string(),
        cause,
    };

    fs::write(&scratch, text).map_err(failed)?;
    fs::rename(&scratch, path).map_err(failed)
}

/// The file's shape.
///
/// `deny_unknown_fields` on both this and [`Entry`]: a field neither knows is a
/// typo or a stale name, and ignoring it would discard a token on the next
/// write. A file from a later version never reaches here — [`TokenStore::parse`]
/// checks the version first.
#[derive(Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct StoredFile {
    version: FormatVersion,
    #[serde(default)]
    monitors: Vec<Entry>,
}

/// One monitor's token.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Entry {
    key: MonitorKey,
    token: RestoreToken,
    /// What the backend granted, when it said. Absent means it did not.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    persist: Option<PersistMode>,
}

impl Entry {
    /// A total order over keys, for a file that does not churn.
    ///
    /// Built from the variant and its rendering rather than from [`Ord`],
    /// because [`MonitorKey`] deliberately has none: ordering identities is a
    /// presentation concern, and giving the type an `Ord` invites somebody to
    /// compare two identities with it.
    fn sort_key(&self) -> (u8, String) {
        let kind = match self.key {
            MonitorKey::Descriptor(_) => 0,
            MonitorKey::Connector(_) => 1,
            MonitorKey::Position(_) => 2,
        };
        (kind, self.key.to_string())
    }
}

/// Just enough of the file to learn which version wrote it.
///
/// No `deny_unknown_fields`, deliberately: a later version's file has fields
/// this one does not know, and refusing to read the version out of it would
/// turn "newer than me" into "corrupt".
#[derive(Debug, Deserialize)]
struct VersionProbe {
    version: FormatVersion,
}

/// Why the stored tokens could not be read or written.
#[derive(Debug)]
pub enum TokenStoreError {
    Parse(toml::de::Error),
    Render(toml::ser::Error),
    Read { path: String, cause: io::Error },
    Write { path: String, cause: io::Error },
}

impl fmt::Display for TokenStoreError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "restore tokens: ")?;
        match self {
            Self::Parse(cause) => write!(f, "the stored tokens could not be read: {cause}"),
            Self::Render(_) => f.write_str("the tokens could not be written out"),
            Self::Read { path, .. } => write!(f, "could not read {path}"),
            Self::Write { path, .. } => write!(f, "could not write {path}"),
        }
    }
}

impl Error for TokenStoreError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        match self {
            Self::Parse(cause) => Some(cause),
            Self::Render(cause) => Some(cause),
            Self::Read { cause, .. } | Self::Write { cause, .. } => Some(cause),
        }
    }
}

#[cfg(test)]
#[expect(
    clippy::expect_used,
    reason = "a failed expectation is how a test reports a failure; the ban is on production code"
)]
mod tests {
    use pretty_assertions::assert_eq;

    use super::*;
    use crate::{
        monitor::{
            geometry::LogicalPosition,
            name::{ConnectorName, MonitorName},
        },
        portal::{
            CursorPolicy, RequestProgress, ScreenCastPortal, SessionRequest, SessionResponse,
            fake::FakePortal,
        },
    };

    fn descriptor(text: &str) -> MonitorKey {
        MonitorName::new(None, Some("Acme".to_owned()), Some(text.to_owned()))
            .descriptor_or_connector()
            .expect("a monitor reporting a model has a descriptor")
    }

    fn token(text: &str) -> RestoreToken {
        RestoreToken::new(text).expect("a non-empty token")
    }

    fn store(entries: &[(&str, &str)]) -> TokenStore {
        let mut store = TokenStore::new();
        for (model, text) in entries {
            store.record(
                descriptor(model),
                Some(token(text)),
                GrantedPersistMode::Granted(PersistMode::UntilRevoked),
            );
        }
        store
    }

    fn parsed(text: &str) -> Loaded {
        TokenStore::parse(text).expect("the text is the format")
    }

    #[test]
    fn a_store_round_trips_through_its_rendered_form() {
        let mut before = store(&[("X24", "first"), ("Z9", "second")]);
        before.record(
            MonitorKey::Connector(ConnectorName::parse("DP-1").expect("a connector name")),
            Some(token("third")),
            GrantedPersistMode::Unstated,
        );
        before.record(
            MonitorKey::Position(LogicalPosition::new(1920, 0)),
            Some(token("fourth")),
            GrantedPersistMode::Granted(PersistMode::WhileRunning),
        );

        let text = before.render().expect("the store renders");

        assert_eq!(parsed(&text), Loaded::Store(before));
    }

    #[test]
    fn a_descriptor_holding_the_format_s_own_punctuation_survives_the_round_trip() {
        // The reason this is a serialised format rather than a line of text:
        // a make and model are whatever the monitor's EDID says.
        let awkward = MonitorKey::Descriptor(
            MonitorName::new(
                None,
                Some("Acme \"quoted\" = [inc]".to_owned()),
                Some("model\nwith\tcontrols".to_owned()),
            )
            .descriptor()
            .expect("a monitor reporting a make has a descriptor"),
        );

        let mut before = TokenStore::new();
        before.record(
            awkward.clone(),
            Some(token("t")),
            GrantedPersistMode::Unstated,
        );

        let after = parsed(&before.render().expect("the store renders")).for_reading();

        assert_eq!(after.token_for(&awkward), Some(&token("t")));
    }

    #[test]
    fn an_empty_store_renders_to_a_file_that_reads_back_as_empty() {
        let text = TokenStore::new().render().expect("the store renders");

        assert_eq!(parsed(&text), Loaded::Store(TokenStore::new()));
    }

    #[test]
    fn rendering_is_stable_across_the_order_the_entries_were_recorded_in() {
        // Otherwise the file churns on every launch and every write is a diff.
        assert_eq!(
            store(&[("A1", "one"), ("B2", "two")])
                .render()
                .expect("the store renders"),
            store(&[("B2", "two"), ("A1", "one")])
                .render()
                .expect("the store renders"),
        );
    }

    #[test]
    fn a_file_from_a_later_version_is_not_read_and_cannot_be_written_back() {
        // The case that corrupts rather than fails: an old writer rendering its
        // own fields over a newer file drops everything it does not know about.
        // There is no store in this variant, so there is nothing to render.
        let loaded = parsed(
            "version = 2\n\
             [[monitors]]\n\
             key = { descriptor = \"Acme X24\" }\n\
             token = \"kept\"\n\
             something-later-versions-have = true\n",
        );

        assert_eq!(
            loaded,
            Loaded::FromTheFuture {
                found: FormatVersion(2),
                supported: CURRENT_VERSION,
            },
        );
        assert!(loaded.for_reading().is_empty());
    }

    #[test]
    fn a_file_from_this_version_carrying_an_unknown_field_is_refused_rather_than_ignored() {
        // Ignoring it would discard whatever it held on the next write.
        assert!(
            TokenStore::parse(
                "version = 1\n\
                 [[monitors]]\n\
                 key = { descriptor = \"Acme X24\" }\n\
                 token = \"kept\"\n\
                 typoed = 3\n",
            )
            .is_err()
        );
    }

    #[test]
    fn an_entry_that_states_no_persistence_reads_back_as_stating_none() {
        // The field is optional, so a file written before it existed parses.
        let loaded = parsed(
            "version = 1\n\
             [[monitors]]\n\
             key = { descriptor = \"Acme X24\" }\n\
             token = \"kept\"\n",
        );
        let store = loaded.for_reading();

        assert_eq!(store.token_for(&descriptor("X24")), Some(&token("kept")));
        assert_eq!(store.persistence_for(&descriptor("X24")), None);
    }

    #[test]
    fn a_key_recorded_as_one_kind_never_reads_back_as_another() {
        // The variant name is in the file, so a connector named `DP-1` and a
        // descriptor whose text happens to be `DP-1` stay distinct.
        let connector = MonitorKey::Connector(ConnectorName::parse("DP-1").expect("a connector"));
        let lookalike = MonitorKey::Descriptor(
            MonitorName::new(None, Some("DP-1".to_owned()), Some("DP-1".to_owned()))
                .descriptor()
                .expect("a descriptor"),
        );

        let mut before = TokenStore::new();
        before.record(
            connector.clone(),
            Some(token("by-port")),
            GrantedPersistMode::Unstated,
        );
        before.record(
            lookalike.clone(),
            Some(token("by-model")),
            GrantedPersistMode::Unstated,
        );

        let after = parsed(&before.render().expect("the store renders")).for_reading();

        assert_eq!(after.token_for(&connector), Some(&token("by-port")));
        assert_eq!(after.token_for(&lookalike), Some(&token("by-model")));
    }

    #[test]
    fn a_key_naming_no_connector_the_kernel_defines_is_refused() {
        assert!(
            TokenStore::parse(
                "version = 1\n\
                 [[monitors]]\n\
                 key = { connector = \"1b4e28ba-2fa1-11d2-883f-0016d3cca427\" }\n\
                 token = \"kept\"\n",
            )
            .is_err()
        );
    }

    #[test]
    fn text_that_is_not_the_format_at_all_is_an_error_rather_than_an_empty_store() {
        assert!(TokenStore::parse("this is not toml {{{").is_err());
        assert!(
            TokenStore::parse("monitors = []").is_err(),
            "a file with no version cannot be told from a file this version wrote"
        );
    }

    #[test]
    fn recording_a_grant_replaces_the_token_that_was_just_spent() {
        // The portal invalidates the token it was given and returns a new one,
        // so a store that keeps the first has restore once and never again.
        let mut store = store(&[("X24", "first")]);
        store.record(
            descriptor("X24"),
            Some(token("second")),
            GrantedPersistMode::Granted(PersistMode::UntilRevoked),
        );

        assert_eq!(store.len(), 1);
        assert_eq!(store.token_for(&descriptor("X24")), Some(&token("second")));
    }

    #[test]
    fn a_grant_with_no_token_drops_the_one_that_was_spent_reaching_it() {
        let mut store = store(&[("X24", "first")]);
        store.record(descriptor("X24"), None, GrantedPersistMode::Unstated);

        assert_eq!(store.token_for(&descriptor("X24")), None);
        assert!(store.is_empty());
    }

    #[test]
    fn a_downgraded_persistence_mode_is_stored_as_granted_rather_than_as_requested() {
        // xdg-desktop-portal-wlr downgrades (`screencast.c:171-181`). Storing
        // the requested value produces a record that lies about the next run.
        let mut store = TokenStore::new();
        store.record(
            descriptor("X24"),
            Some(token("t")),
            GrantedPersistMode::Granted(PersistMode::WhileRunning),
        );

        assert_eq!(
            store.persistence_for(&descriptor("X24")),
            Some(PersistMode::WhileRunning),
        );
    }

    #[test]
    fn a_backend_that_states_no_persistence_leaves_none_recorded() {
        let mut store = store(&[("X24", "first")]);
        store.record(
            descriptor("X24"),
            Some(token("second")),
            GrantedPersistMode::Unstated,
        );

        assert_eq!(store.persistence_for(&descriptor("X24")), None);
    }

    #[test]
    fn forgetting_a_monitor_that_was_never_recorded_changes_nothing() {
        let mut store = store(&[("X24", "first")]);

        assert!(!store.forget(&descriptor("Z9")));
        assert_eq!(store.len(), 1);
        assert!(store.forget(&descriptor("X24")));
        assert!(store.is_empty());
    }

    #[test]
    fn each_session_offers_the_token_the_previous_one_returned() {
        // The whole point of the store, driven through the portal seam rather
        // than asserted on the store alone: session two must offer what session
        // one returned, and session three must offer what session two did.
        let mut portal = FakePortal::new();
        for text in ["from-first", "from-second"] {
            portal.will_grant(SessionResponse {
                streams: Vec::new(),
                restore_token: RestoreToken::new(text),
                granted_persist_mode: GrantedPersistMode::Granted(PersistMode::UntilRevoked),
            });
        }

        let monitor = descriptor("X24");
        let mut store = TokenStore::new();

        for _ in 0..2 {
            let request =
                SessionRequest::new(store.token_for(&monitor).cloned(), CursorPolicy::Hidden);
            let id = portal.begin(request).expect("the fake portal accepts");
            let response = portal.grant(id);
            store.record(
                monitor.clone(),
                response.restore_token,
                response.granted_persist_mode,
            );
        }

        assert_eq!(
            portal
                .requests
                .iter()
                .map(|request| request.restore_token.as_ref().map(RestoreToken::as_str))
                .collect::<Vec<_>>(),
            vec![None, Some("from-first")],
        );
        assert_eq!(store.token_for(&monitor), Some(&token("from-second")));
    }

    #[test]
    fn a_refused_session_leaves_the_stored_token_alone() {
        // A prompt the user cancels is not a reason to forget a token that may
        // still work on the next launch.
        let mut portal = FakePortal::new();
        portal.will_fail(crate::portal::PortalError::Refused { code: 1 });

        let store = store(&[("X24", "first")]);
        let id = portal
            .begin(SessionRequest::new(None, CursorPolicy::Hidden))
            .expect("the fake portal accepts");

        assert!(matches!(portal.drive(id), RequestProgress::Failed(_)));
        assert_eq!(store.token_for(&descriptor("X24")), Some(&token("first")));
        assert!(!store.is_empty());
    }

    #[test]
    fn a_descriptor_key_is_written_as_the_text_a_user_would_recognise() {
        // The rendered form is read by whoever has to delete this file, so it
        // is worth stating rather than leaving to serde's defaults.
        let mut store = TokenStore::new();
        store.record(
            descriptor("X24"),
            Some(token("t")),
            GrantedPersistMode::Granted(PersistMode::UntilRevoked),
        );

        let text = store.render().expect("the store renders");

        assert!(text.contains("version = 1"), "{text}");
        assert!(text.contains("descriptor = \"Acme X24\""), "{text}");
        assert!(text.contains("persist = \"until-revoked\""), "{text}");
    }
}
