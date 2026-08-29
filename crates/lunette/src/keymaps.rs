//! Linux-only: the compiled keymaps the main thread uses to answer Lua queries.
//!
//! The compositor thread publishes each seat's layout as text because
//! libxkbcommon is not thread-safe and a compiled keymap cannot cross a thread.
//! The main thread compiles its own copy and stores it in the cache.
//!
//! Compiling is not free. A full layout is tens of kilobytes of text, and
//! building the reverse lookup walks every key under every level-selecting
//! modifier combination. A virtual keyboard that draws its legends performs a
//! hundred lookups a frame. Each layout is compiled once per layout change,
//! and the lookups use the compiled keymap.
//!
//! # Entry invalidation
//!
//! An entry is invalidated by the identity of the published text. The content
//! is not compared: the snapshot carries an `Arc<KeymapText>` that the
//! compositor replaces when the layout changes. Comparing pointers is cheaper
//! than comparing thirty kilobytes and equally correct.

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
    /// Returns `None` when the text does not compile. The text is the
    /// compositor's own serialisation of a keymap it compiled, so a compile
    /// failure indicates a defect in the compositor. The failure is cached
    /// with the source text, so a failing layout is reported once per layout
    /// change; later queries return the cached `None` without recompiling.
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
    /// Without it, a session that creates and destroys seats accumulates a
    /// compiled layout per seat that ever existed.
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

/// A compiled keymap and the text it compiles from.
///
/// A layout that does not compile does not compile on the next query either,
/// so the failure is cached as well as the success.
struct Entry {
    text: Arc<KeymapText>,
    keymap: Option<Rc<Keymap>>,
}
