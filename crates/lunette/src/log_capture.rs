//! Collects what the code under test logs, for tests that assert what is reported.
//!
//! One module owns the subscriber because a test binary can install only one global subscriber.

#![expect(
    clippy::expect_used,
    reason = "a failed expectation is how a test reports a failure; the ban is on production code"
)]

use std::{
    cell::RefCell,
    io::{self, Write},
    sync::{Arc, Once},
};

use parking_lot::Mutex;
use tracing_subscriber::{filter::LevelFilter, fmt::MakeWriter};

/// What the calling thread logged while collecting.
#[derive(Clone, Debug, Default)]
pub(crate) struct Logs(Arc<Mutex<Vec<u8>>>);

impl Logs {
    /// How many lines mention `needle`.
    pub(crate) fn mentioning(&self, needle: &str) -> usize {
        String::from_utf8_lossy(&self.0.lock())
            .lines()
            .filter(|line| line.contains(needle))
            .count()
    }

    /// Runs `body` with everything the calling thread logs collected into the
    /// returned `Logs`.
    pub(crate) fn capture(body: impl FnOnce()) -> Self {
        install_collecting_subscriber();
        let logs = Self::default();
        let _collecting = Collecting::start(logs.clone());
        body();
        logs
    }
}

/// Installs the one subscriber the whole test binary logs through.
///
/// `tracing` caches a callsite's `Interest` globally, so a per-thread
/// subscriber can lose a race and collect nothing. One global subscriber
/// settles the interest for every thread.
pub(crate) fn install_collecting_subscriber() {
    static INSTALLED: Once = Once::new();

    INSTALLED.call_once(|| {
        let subscriber = tracing_subscriber::fmt()
            .with_ansi(false)
            .with_max_level(LevelFilter::TRACE)
            .with_writer(ThreadCollector)
            .finish();
        tracing::subscriber::set_global_default(subscriber)
            .expect("no other subscriber is installed in the test binary");
    });
}

thread_local! {
    /// What the running thread collects into, if it is collecting.
    static COLLECTING: RefCell<Option<Logs>> = const { RefCell::new(None) };
}

/// Directs each event to whatever the thread that emitted it collects into, so
/// concurrent tests capture only their own output.
struct ThreadCollector;

impl<'a> MakeWriter<'a> for ThreadCollector {
    type Writer = ThreadWriter;

    fn make_writer(&'a self) -> Self::Writer {
        ThreadWriter(COLLECTING.with_borrow(Clone::clone))
    }
}

/// Writes to the collector the emitting thread has, and discards the line when
/// it has none.
struct ThreadWriter(Option<Logs>);

impl Write for ThreadWriter {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        if let Some(logs) = self.0.as_ref() {
            logs.0.lock().extend_from_slice(buf);
        }
        Ok(buf.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

/// Collects into `logs` until dropped, restoring the collector it replaced,
/// including when the body panics.
struct Collecting(Option<Logs>);

impl Collecting {
    fn start(logs: Logs) -> Self {
        Self(COLLECTING.with_borrow_mut(|slot| slot.replace(logs)))
    }
}

impl Drop for Collecting {
    fn drop(&mut self) {
        COLLECTING.with_borrow_mut(|slot| *slot = self.0.take());
    }
}
