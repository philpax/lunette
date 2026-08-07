//! Linux-only: the process handle `lunette.spawn` returns.
//!
//! The handle exists before the process does. `lunette.spawn` queues a request
//! and returns in the same call, so the identifier is minted on this side and
//! the compositor is told to use it — which is why [`Process`] can describe
//! something the compositor has not heard of yet.

use std::{cell::RefCell, rc::Rc};

use lunette_compositor::protocol::{Pid, ProcessId, ProcessSnapshot};
use mlua::{UserData, UserDataFields};

use crate::{
    control::{serialise::HANDLE_METAFIELD, wire::HandleKind},
    lua::Session,
};

/// A process lunette started, or adopted from outside.
#[derive(Debug)]
pub struct Process<T> {
    id: ProcessId,
    session: Rc<Session<T>>,
    known: RefCell<Known>,
}

impl<T> Process<T> {
    pub(crate) fn new(session: Rc<Session<T>>, id: ProcessId) -> Self {
        Self {
            id,
            session,
            known: RefCell::new(Known {
                pid: None,
                external: false,
            }),
        }
    }

    /// Brings the cache up to date, reporting whether the process is running.
    ///
    /// False in three different situations, and deliberately not distinguished
    /// here: the request has not reached the compositor yet, the process has
    /// ended, and the process never started. The last two are told apart by
    /// `lovr.lunprocessexited`, which carries the outcome; a handle field
    /// cannot, because a handle has no way to say "not yet".
    fn refresh(&self) -> bool {
        let snapshot = self.session.snapshot();
        let Some(process) = snapshot
            .processes
            .iter()
            .find(|process| process.process == self.id)
        else {
            return false;
        };

        *self.known.borrow_mut() = Known::from(process);
        process.alive
    }
}

/// The last thing each field of a process was known to be.
#[derive(Clone, Copy, Debug)]
struct Known {
    pid: Option<Pid>,
    external: bool,
}

impl From<&ProcessSnapshot> for Known {
    fn from(process: &ProcessSnapshot) -> Self {
        Self {
            pid: process.pid,
            external: process.external,
        }
    }
}

impl<T: 'static> UserData for Process<T> {
    fn add_fields<F: UserDataFields<Self>>(fields: &mut F) {
        // How `lunctl` recognises a handle. A metafield rather than a field,
        // so it is invisible to `pairs` and to ordinary indexing; the
        // serialiser reads it off the metatable and refuses any other
        // userdata, which is how a LÖVR `Texture` comes to be reported rather
        // than stringified.
        fields.add_meta_field(HANDLE_METAFIELD, HandleKind::Process.as_str());

        fields.add_field_method_get("id", |_, process| Ok(process.id.get()));

        fields.add_field_method_get("alive", |_, process| Ok(process.refresh()));

        // Absent until the child has been forked, and for an adopted process
        // whose pid could not be read.
        fields.add_field_method_get("pid", |_, process| {
            process.refresh();
            Ok(process.known.borrow().pid.map(Pid::get))
        });

        // Whether the process connected from outside rather than being spawned.
        fields.add_field_method_get("external", |_, process| {
            process.refresh();
            Ok(process.known.borrow().external)
        });
    }
}
