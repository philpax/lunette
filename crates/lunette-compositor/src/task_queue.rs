//! The queue WayVR's handlers fill with tasks for the drain after dispatch.
//!
//! Upstream's `SyncEventQueue` is shared with the overlay thread. lunette's
//! state owns its queue, and only the compositor thread touches it.

use std::collections::VecDeque;

/// The tasks the handlers queue for the drain after dispatch.
#[derive(Debug)]
pub struct TaskQueue<T> {
    queue: VecDeque<T>,
}

impl<T> Default for TaskQueue<T> {
    fn default() -> Self {
        Self {
            queue: VecDeque::new(),
        }
    }
}

impl<T> TaskQueue<T> {
    pub fn send(&mut self, task: T) {
        self.queue.push_back(task);
    }

    pub fn read(&mut self) -> Option<T> {
        self.queue.pop_front()
    }
}
