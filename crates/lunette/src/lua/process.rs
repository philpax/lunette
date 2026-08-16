//! Linux-only: the process handle `lunette.spawn` returns.
//!
//! The handle exists before the process does. `lunette.spawn` queues a request
//! and returns in the same call, so the identifier is minted on this side and
//! the compositor is told to use it — which is why [`Process`] can describe
//! something the compositor has not heard of yet.

use std::{cell::RefCell, rc::Rc};

use lunette_compositor::protocol::{Pid, ProcessId, ProcessSnapshot};

use crate::{
    control::wire::HandleKind,
    lua::{LuaTexture, Session, declarations::handle},
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

handle! {
    /// A process lunette started, or adopted from outside. The handle exists before the process does: `lunette.spawn` queues a request and returns in the same call.
    Process<T: LuaTexture> = HandleKind::Process;

    field id(_lua, this) -> u64 { Ok(this.id.get()) }

    /// False in three situations this deliberately does not distinguish: the request has not reached the compositor, the process has ended, and the process never started. `lovr.lunprocessexited` tells the last two apart.
    field alive(_lua, this) -> bool { Ok(this.refresh()) }

    /// Absent until the child has been forked, and for an adopted process whose pid could not be read.
    field pid(_lua, this) -> Option<i32> {
        this.refresh();
        Ok(this.known.borrow().pid.map(Pid::get))
    }

    /// Whether the process connected from outside rather than being spawned.
    field external(_lua, this) -> bool {
        this.refresh();
        Ok(this.known.borrow().external)
    }
}
