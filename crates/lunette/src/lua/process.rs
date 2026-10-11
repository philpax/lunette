//! Linux-only: the process handle `lunette.spawn` returns.
//!
//! The handle exists before the process does. `lunette.spawn` mints the
//! identifier, queues a spawn request, and returns in the same call.
//! The request carries the identifier to the compositor. [`Process`] can
//! describe a process the compositor does not track yet.

use std::rc::Rc;

use lunette_compositor::protocol::ProcessId;

use crate::{
    control::wire::HandleKind,
    lua::{LuaTexture, Session, declarations::handle},
};

/// A process lunette started or adopted from a connecting client.
#[derive(Debug)]
pub struct Process<T> {
    id: ProcessId,
    session: Rc<Session<T>>,
}

/// Two handles are equal when they name the same process.
impl<T> PartialEq for Process<T> {
    fn eq(&self, other: &Self) -> bool {
        self.id == other.id
    }
}

impl<T> Process<T> {
    pub(crate) fn new(session: Rc<Session<T>>, id: ProcessId) -> Self {
        Self { id, session }
    }

    /// Whether the snapshot reports the process alive.
    fn alive(&self) -> bool {
        self.session
            .snapshot()
            .processes
            .iter()
            .any(|process| process.process == self.id && process.alive)
    }
}

handle! {
    /// A process lunette started or adopted from a connecting client. A spawned handle exists
    /// before the process does: `lunette.spawn` queues a request and returns in the same call.
    Process<T: LuaTexture> = HandleKind::Process;

    field id(_lua, this) -> u64 { Ok(this.id.get()) }

    /// True in three situations this field does not distinguish: the request
    /// has not reached the compositor, the process has ended, and the process
    /// never started. The caller distinguishes the last two by the outcome
    /// `lunette.onProcessExited` carries. A handle field cannot represent
    /// "not yet".
    field dead(_lua, this) -> bool { Ok(!this.alive()) }
}
