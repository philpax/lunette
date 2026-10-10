//! [`MonitorStreams`] and [`NodeWatch`] implementations for deterministic lifecycle tests.
//!
//! The recording source logs stream lifecycle events without starting a PipeWire
//! thread, connecting to a node, or waiting. The scripted watch reports the node
//! removals a test states.

use std::{cell::RefCell, rc::Rc};

use crate::{
    mirror::{
        nodes::NodeWatch,
        source::{MonitorStream, MonitorStreams},
    },
    portal::NodeId,
    stream::CapturedFrame,
};

/// The ordered stream events recorded by a [`RecordingSource`].
///
/// The log is shared so the lifecycle and the test observe the same events.
#[derive(Clone, Debug, Default)]
pub struct StreamLog {
    entries: Rc<RefCell<Vec<StreamEvent>>>,
}

impl StreamLog {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Returns a snapshot of the recorded events.
    #[must_use]
    pub fn entries(&self) -> Vec<StreamEvent> {
        self.entries.borrow().clone()
    }

    /// Returns opened nodes in event order, including repeated opens.
    #[must_use]
    pub fn opened(&self) -> Vec<NodeId> {
        self.entries
            .borrow()
            .iter()
            .filter_map(|event| match event {
                StreamEvent::Opened { node, .. } => Some(*node),
                StreamEvent::Paused { .. }
                | StreamEvent::Resumed { .. }
                | StreamEvent::Dropped { .. } => None,
            })
            .collect()
    }

    /// Returns nodes whose streams stopped, in event order.
    #[must_use]
    pub fn dropped(&self) -> Vec<NodeId> {
        self.entries
            .borrow()
            .iter()
            .filter_map(|event| match event {
                StreamEvent::Dropped { node } => Some(*node),
                StreamEvent::Opened { .. }
                | StreamEvent::Paused { .. }
                | StreamEvent::Resumed { .. } => None,
            })
            .collect()
    }

    fn record(&self, event: StreamEvent) {
        self.entries.borrow_mut().push(event);
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum StreamEvent {
    Opened {
        name: String,
        node: NodeId,
    },
    Paused {
        node: NodeId,
    },
    Resumed {
        node: NodeId,
    },
    /// Dropping the stream stops capture and releases its resources.
    Dropped {
        node: NodeId,
    },
}

/// A source that records lifecycle events and produces no frames.
#[derive(Clone, Debug, Default)]
pub struct RecordingSource {
    log: StreamLog,
}

impl RecordingSource {
    #[must_use]
    pub fn new(log: StreamLog) -> Self {
        Self { log }
    }
}

impl MonitorStreams for RecordingSource {
    fn open(&mut self, name: &str, node: NodeId) -> Option<Box<dyn MonitorStream>> {
        self.log.record(StreamEvent::Opened {
            name: name.to_owned(),
            node,
        });
        Some(Box::new(RecordedStream {
            log: self.log.clone(),
            node,
        }))
    }
}

#[derive(Debug)]
struct RecordedStream {
    log: StreamLog,
    node: NodeId,
}

impl MonitorStream for RecordedStream {
    fn latest(&mut self) -> Option<CapturedFrame> {
        None
    }

    fn pause(&mut self) {
        self.log.record(StreamEvent::Paused { node: self.node });
    }

    fn resume(&mut self) {
        self.log.record(StreamEvent::Resumed { node: self.node });
    }
}

impl Drop for RecordedStream {
    fn drop(&mut self) {
        self.log.record(StreamEvent::Dropped { node: self.node });
    }
}

/// A node watch that reports the removals a test queues.
///
/// Shared, so the test queues removals after the lifecycle owns the watch.
#[derive(Clone, Debug, Default)]
pub struct ScriptedNodes {
    removed: Rc<RefCell<Vec<NodeId>>>,
}

impl ScriptedNodes {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Queues a node removal for the next [`NodeWatch::take_removed`].
    pub fn remove(&self, node: NodeId) {
        self.removed.borrow_mut().push(node);
    }
}

impl NodeWatch for ScriptedNodes {
    fn take_removed(&mut self) -> Vec<NodeId> {
        self.removed.take()
    }
}
