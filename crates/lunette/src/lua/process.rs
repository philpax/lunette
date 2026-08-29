//! Linux-only: the process handle `lunette.spawn` returns.
//!
//! The handle exists before the process does. `lunette.spawn` mints the
//! identifier, queues a spawn request, and returns in the same call.
//! The request carries the identifier to the compositor. [`Process`] can
//! describe a process the compositor does not track yet.

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

/// The last known value of each field of a process.
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
    /// A process lunette started, or adopted from outside. The handle exists
    /// before the process does: `lunette.spawn` queues a request and returns
    /// in the same call.
    Process<T: LuaTexture> = HandleKind::Process;

    field id(_lua, this) -> u64 { Ok(this.id.get()) }

    /// False in three situations this field does not distinguish: the request
    /// has not reached the compositor, the process has ended, and the process
    /// never started. The caller distinguishes the last two by the outcome
    /// `lovr.lunprocessexited` carries. A handle field cannot represent
    /// "not yet".
    field alive(_lua, this) -> bool { Ok(this.refresh()) }

    /// Absent until the child is forked, and for an adopted process whose pid cannot be read.
    field pid(_lua, this) -> Option<i32> {
        this.refresh();
        Ok(this.known.borrow().pid.map(Pid::get))
    }

    /// Whether the process connected from outside. An external process has no
    /// spawn request from lunette.
    field external(_lua, this) -> bool {
        this.refresh();
        Ok(this.known.borrow().external)
    }
}
