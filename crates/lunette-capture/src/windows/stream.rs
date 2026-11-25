//! Windows-only: keeps capture and D3D11 readback off the frame thread.

use std::{
    io,
    sync::{Arc, mpsc},
    thread,
    time::Duration,
};

use ::windows::core::{Error, Result};
use lunette_compositor::protocol::PixelBuffer;
use parking_lot::Mutex;

use crate::windows::{Capture, CaptureTarget};

/// A capture's latest result. Closing and failure are terminal.
#[derive(Debug)]
pub enum CaptureUpdate {
    Frame(PixelBuffer),
    Closed,
    Failed(Error),
}

/// An active worker with a one-entry mailbox for the newest captured frame.
///
/// Dropping the stream requests cancellation. The worker releases its capture
/// resources after any in-progress readback without blocking the caller.
#[derive(Debug)]
pub struct CaptureStream {
    latest: Arc<Mutex<Option<CaptureUpdate>>>,
    stop: mpsc::SyncSender<()>,
    worker: thread::JoinHandle<()>,
}

impl CaptureStream {
    /// Starts capturing an explicitly selected surface on a dedicated thread.
    ///
    /// # Errors
    ///
    /// Returns thread creation errors directly. Capture errors arrive through
    /// the mailbox.
    pub fn start(target: CaptureTarget) -> io::Result<Self> {
        let (stop, stopping) = mpsc::sync_channel(0);
        let latest = Arc::new(Mutex::new(None));
        let mailbox = Arc::clone(&latest);
        let worker = thread::Builder::new()
            .name("windows-capture".into())
            .spawn(move || {
                if let Err(error) = capture_frames(&target, &stopping, &mailbox) {
                    *mailbox.lock() = Some(CaptureUpdate::Failed(error));
                }
            })?;
        Ok(Self {
            latest,
            stop,
            worker,
        })
    }

    /// Takes the pending update without waiting for the capture worker.
    pub fn latest(&self) -> Option<CaptureUpdate> {
        self.latest.try_lock()?.take()
    }

    /// Stops capture and waits for the worker to release its WinRT and GPU resources.
    ///
    /// # Errors
    ///
    /// Returns the worker's panic if it did not shut down normally.
    pub fn stop(self) -> thread::Result<()> {
        drop(self.stop);
        self.worker.join()
    }
}

fn capture_frames(
    target: &CaptureTarget,
    stopping: &mpsc::Receiver<()>,
    mailbox: &Mutex<Option<CaptureUpdate>>,
) -> Result<()> {
    let mut capture = Capture::open(target)?;
    loop {
        if capture.is_closed() {
            break;
        }
        match capture.read_latest() {
            Ok(Some(frame)) => *mailbox.lock() = Some(CaptureUpdate::Frame(frame)),
            Ok(None) => {}
            Err(_) if capture.is_closed() => break,
            Err(error) => return Err(error),
        }
        if stopping.recv_timeout(Duration::from_millis(16)) != Err(mpsc::RecvTimeoutError::Timeout)
        {
            return Ok(());
        }
    }
    drop(capture);
    *mailbox.lock() = Some(CaptureUpdate::Closed);
    Ok(())
}
