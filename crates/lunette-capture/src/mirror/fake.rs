//! A [`MonitorStreams`] that opens nothing, for the lifecycle's tests.
//!
//! PipeWire is an unmanaged dependency and a stream is a thread, so the
//! transitions are exercised against a source that records what it was asked to
//! open and what was dropped. Nothing here spawns a thread, connects to a node,
//! or waits.

use std::{cell::RefCell, rc::Rc};

use crate::{
    mirror::source::{MonitorStream, MonitorStreams},
    portal::NodeId,
    stream::{CapturedFrame, FrameCounts},
};

/// What a [`RecordingSource`] was asked to do, in the order it was asked.
///
/// Shared rather than owned, so the copy the lifecycle holds and the copy the
/// test reads are the same log.
#[derive(Clone, Debug, Default)]
pub struct StreamLog {
    entries: Rc<RefCell<Vec<StreamEvent>>>,
}

impl StreamLog {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Everything recorded so far.
    #[must_use]
    pub fn entries(&self) -> Vec<StreamEvent> {
        self.entries.borrow().clone()
    }

    /// The nodes opened so far, in order, including repeats.
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

    /// The nodes whose streams have been stopped, in order.
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

/// One thing that happened to a stream.
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
    /// The stream was released, which is what stopping is.
    Dropped {
        node: NodeId,
    },
}

/// A source whose streams produce nothing and record everything.
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

/// A stream that carries no frames and reports its own end.
#[derive(Debug)]
struct RecordedStream {
    log: StreamLog,
    node: NodeId,
}

impl MonitorStream for RecordedStream {
    fn latest(&mut self) -> Option<CapturedFrame> {
        None
    }

    fn counts(&self) -> FrameCounts {
        FrameCounts::default()
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
