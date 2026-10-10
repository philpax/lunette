//! Linux-only: notices when the PipeWire nodes a portal granted go away.
//!
//! A ScreenCast session that the user stops, or that the portal backend ends, ends in two
//! observable ways. The portal emits `org.freedesktop.portal.Session.Closed`, and the backend
//! destroys the session's PipeWire nodes. The signal is addressed to the D-Bus connection that
//! created the session, which is `wlx-capture`'s private connection, and `wlx-capture` exposes
//! neither that connection nor the session handle. Its capture thread logs the stream's state
//! changes and reports none of them. Node removal is visible to any PipeWire client, so
//! [`PipewireNodeWatch`] listens to the registry on a connection of its own and reports the nodes
//! that were removed. [`crate::mirror::MirrorSet`] stops the streams on those nodes and revokes
//! the session once none of its nodes remain.
//!
//! PipeWire is an unmanaged dependency, so the watch sits behind the [`NodeWatch`] seam and the
//! lifecycle tests substitute [`crate::mirror::fake::ScriptedNodes`]. [`NodeChanges`] turns
//! registry events into removals and is pure.

use std::{
    cell::RefCell,
    collections::{HashMap, HashSet},
    error::Error,
    fmt, io, mem,
    rc::Rc,
    sync::{Arc, mpsc},
    thread::{self, JoinHandle},
};

use parking_lot::Mutex;
use pipewire::{
    channel, context::ContextRc, core::PW_ID_CORE, main_loop::MainLoopRc, types::ObjectType,
};
use tracing::{debug, warn};

use crate::portal::NodeId;

/// Reports PipeWire nodes that no longer exist.
pub trait NodeWatch {
    /// Drains the nodes removed since the previous call.
    ///
    /// PipeWire reuses identifiers, so a node removed and then added again before the call is not
    /// reported.
    fn take_removed(&mut self) -> Vec<NodeId>;
}

/// A watch that never reports a removal, for a host where PipeWire cannot be reached.
#[derive(Clone, Copy, Debug, Default)]
pub struct NoNodeWatch;

impl NodeWatch for NoNodeWatch {
    fn take_removed(&mut self) -> Vec<NodeId> {
        Vec::new()
    }
}

/// The production watch: a PipeWire registry listener on its own thread.
///
/// Dropping it stops the thread and joins it.
pub struct PipewireNodeWatch {
    changes: Arc<Mutex<NodeChanges>>,
    stop: channel::Sender<()>,
    thread: Option<JoinHandle<()>>,
}

impl PipewireNodeWatch {
    /// Connects to PipeWire and starts listening for node removals.
    ///
    /// Blocks until the connection is made or has failed. The connection is local, and this runs
    /// once at startup, never on a frame.
    ///
    /// # Errors
    ///
    /// Returns an error when the thread cannot be spawned or PipeWire cannot be reached.
    pub fn start() -> Result<Self, NodeWatchError> {
        let changes = Arc::new(Mutex::new(NodeChanges::default()));
        let (stop, stopped) = channel::channel();
        let (ready, connected) = mpsc::sync_channel(1);
        let thread = thread::Builder::new()
            .name("lunette-pipewire-nodes".to_owned())
            .spawn({
                let changes = Arc::clone(&changes);
                move || watch(&changes, stopped, &ready)
            })
            .map_err(NodeWatchError::Spawn)?;

        match connected.recv() {
            Ok(Ok(())) => Ok(Self {
                changes,
                stop,
                thread: Some(thread),
            }),
            Ok(Err(cause)) => {
                let _ = thread.join();
                Err(NodeWatchError::Connect(cause))
            }
            Err(mpsc::RecvError) => {
                let _ = thread.join();
                Err(NodeWatchError::Exited)
            }
        }
    }
}

impl NodeWatch for PipewireNodeWatch {
    fn take_removed(&mut self) -> Vec<NodeId> {
        self.changes.lock().take_removed()
    }
}

impl Drop for PipewireNodeWatch {
    fn drop(&mut self) {
        // A failed send means the loop has already quit after a connection error.
        let _ = self.stop.send(());
        if let Some(thread) = self.thread.take()
            && thread.join().is_err()
        {
            warn!("the PipeWire node watch panicked");
        }
    }
}

impl fmt::Debug for PipewireNodeWatch {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("PipewireNodeWatch").finish_non_exhaustive()
    }
}

/// Why the node watch could not start.
#[derive(Debug)]
pub enum NodeWatchError {
    Spawn(io::Error),
    Connect(pipewire::Error),
    /// The thread ended without reporting whether it connected.
    Exited,
}

impl fmt::Display for NodeWatchError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "pipewire node watch: ")?;
        match self {
            Self::Spawn(cause) => write!(f, "could not spawn its thread: {cause}"),
            Self::Connect(cause) => write!(f, "could not connect to PipeWire: {cause}"),
            Self::Exited => write!(f, "its thread ended before it connected"),
        }
    }
}

impl Error for NodeWatchError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        match self {
            Self::Spawn(cause) => Some(cause),
            Self::Connect(cause) => Some(cause),
            Self::Exited => None,
        }
    }
}

/// Runs the registry listener until [`PipewireNodeWatch`] is dropped or the connection fails.
fn watch(
    changes: &Arc<Mutex<NodeChanges>>,
    stopped: channel::Receiver<()>,
    ready: &mpsc::SyncSender<Result<(), pipewire::Error>>,
) {
    let connected = (|| {
        let main_loop = MainLoopRc::new(None)?;
        let context = ContextRc::new(&main_loop, None)?;
        let core = context.connect_rc(None)?;
        let registry = core.get_registry_rc()?;
        Ok((main_loop, core, registry))
    })();
    let (main_loop, core, registry) = match connected {
        Ok(connected) => connected,
        Err(cause) => {
            let _ = ready.send(Err(cause));
            return;
        }
    };

    // `global_remove` carries only an identifier, so the listener remembers which globals are
    // nodes.
    let nodes = Rc::new(RefCell::new(HashSet::new()));
    let _registry = registry
        .add_listener_local()
        .global({
            let nodes = Rc::clone(&nodes);
            let changes = Arc::clone(changes);
            move |global| {
                if global.type_ == ObjectType::Node {
                    nodes.borrow_mut().insert(global.id);
                    changes.lock().added(global.id);
                }
            }
        })
        .global_remove({
            let changes = Arc::clone(changes);
            move |id| {
                if nodes.borrow_mut().remove(&id) {
                    debug!(node = id, "a PipeWire node was removed");
                    changes.lock().removed(id);
                }
            }
        })
        .register();
    let _core = core
        .add_listener_local()
        .error({
            let main_loop = main_loop.clone();
            move |id, _, result, message| {
                if id == PW_ID_CORE {
                    warn!(
                        result,
                        message, "the PipeWire connection failed; a portal session that ends is no longer noticed",
                    );
                    main_loop.quit();
                }
            }
        })
        .register();
    let _stop = stopped.attach(main_loop.loop_(), {
        let main_loop = main_loop.clone();
        move |()| main_loop.quit()
    });

    let _ = ready.send(Ok(()));
    main_loop.run();
}

/// The latest registry event for each node since the previous drain.
#[derive(Debug, Default)]
struct NodeChanges {
    /// Whether each node exists after its latest event.
    present: HashMap<u32, bool>,
}

impl NodeChanges {
    fn added(&mut self, id: u32) {
        self.present.insert(id, true);
    }

    fn removed(&mut self, id: u32) {
        self.present.insert(id, false);
    }

    /// The nodes whose latest event was a removal, in ascending order.
    fn take_removed(&mut self) -> Vec<NodeId> {
        let mut removed: Vec<_> = mem::take(&mut self.present)
            .into_iter()
            .filter(|&(_, present)| !present)
            .filter_map(|(id, _)| NodeId::new(id))
            .collect();
        removed.sort_unstable();
        removed
    }
}

#[cfg(test)]
mod tests {
    use pretty_assertions::assert_eq;

    use super::*;

    fn nodes(ids: &[u32]) -> Vec<NodeId> {
        ids.iter().filter_map(|&id| NodeId::new(id)).collect()
    }

    #[test]
    fn nothing_is_removed_before_any_event() {
        assert_eq!(NodeChanges::default().take_removed(), Vec::new());
    }

    #[test]
    fn a_removed_node_is_reported_once() {
        let mut changes = NodeChanges::default();
        changes.added(42);
        changes.removed(42);

        assert_eq!(changes.take_removed(), nodes(&[42]));
        assert_eq!(changes.take_removed(), Vec::new());
    }

    #[test]
    fn an_added_node_is_not_a_removal() {
        let mut changes = NodeChanges::default();
        changes.added(42);

        assert_eq!(changes.take_removed(), Vec::new());
    }

    #[test]
    fn an_identifier_reused_before_the_drain_is_not_reported() {
        let mut changes = NodeChanges::default();
        changes.removed(42);
        changes.added(42);

        assert_eq!(changes.take_removed(), Vec::new());
    }

    #[test]
    fn a_node_removed_after_being_reused_is_reported() {
        let mut changes = NodeChanges::default();
        changes.removed(42);
        changes.added(42);
        changes.removed(42);

        assert_eq!(changes.take_removed(), nodes(&[42]));
    }

    #[test]
    fn removals_are_reported_in_ascending_order() {
        let mut changes = NodeChanges::default();
        for id in [9, 3, 7] {
            changes.removed(id);
        }
        changes.added(5);

        assert_eq!(changes.take_removed(), nodes(&[3, 7, 9]));
    }
}
