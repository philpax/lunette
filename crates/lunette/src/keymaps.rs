//! Linux-only: the compiled keymaps the main thread answers Lua's queries from.
//!
//! The compositor thread publishes each seat's layout as text, because
//! libxkbcommon is not thread-safe and a compiled keymap cannot cross a thread.
//! The main thread compiles its own copy, and this module holds those copies.
//!
//! A full layout is tens of kilobytes of text, and building the reverse lookup
//! walks every key under every level-selecting modifier combination. A virtual
//! keyboard drawing its legends asks a hundred questions a frame. This cache
//! avoids recompiling on each query.
//!
//! ## Entry invalidation
//!
//! Invalidation uses the identity of the published text, not its content. The
//! snapshot carries an `Arc<KeymapText>` that the compositor replaces only when
//! the layout actually changes, so a pointer comparison is both cheaper than
//! comparing thirty kilobytes and exactly as correct.

use std::{collections::HashMap, rc::Rc, sync::Arc};

use lunette_compositor::{
    keymap::Keymap,
    protocol::{KeymapText, SeatId},
};
use tracing::warn;

/// One compiled keymap per seat, rebuilt when the seat's layout changes.
#[derive(Default)]
pub struct KeymapCache {
    entries: HashMap<SeatId, Entry>,
}

impl KeymapCache {
    /// The compiled form of a seat's published layout.
    ///
    /// `None` when the text does not compile, which should not happen — it is
    /// the compositor's own serialisation of a keymap it compiled — and which
    /// is reported rather than retried, because retrying reports it once per
    /// query.
    pub fn compiled(&mut self, seat: SeatId, text: &Arc<KeymapText>) -> Option<Rc<Keymap>> {
        if let Some(entry) = self.entries.get(&seat)
            && Arc::ptr_eq(&entry.text, text)
        {
            return entry.keymap.clone();
        }

        let keymap = match Keymap::from_text(text) {
            Ok(keymap) => Some(Rc::new(keymap)),
            Err(error) => {
                warn!(
                    %seat,
                    %error,
                    "a seat's published keymap did not compile, so its layout cannot be queried",
                );
                None
            }
        };

        self.entries.insert(
            seat,
            Entry {
                text: Arc::clone(text),
                keymap: keymap.clone(),
            },
        );
        keymap
    }

    /// Drops what is held for seats the snapshot no longer lists.
    ///
    /// Called once a frame. Without it a session that creates and destroys
    /// seats accumulates a compiled layout per seat that ever existed.
    pub fn retain(&mut self, live: &[SeatId]) {
        self.entries.retain(|seat, _| live.contains(seat));
    }
}

impl std::fmt::Debug for KeymapCache {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("KeymapCache")
            .field("seats", &self.entries.len())
            .finish()
    }
}

/// The text a compilation came from, and what came out of it.
///
/// The failure is cached as well as the success. A layout that does not compile
/// will not compile on the next query either, and reporting it once per frame
/// is already more than it deserves.
struct Entry {
    text: Arc<KeymapText>,
    keymap: Option<Rc<Keymap>>,
}
