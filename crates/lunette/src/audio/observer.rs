//! Bounded asynchronous process observations for audio attribution.

use std::{
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
        mpsc::{self, Receiver, SyncSender, TrySendError},
    },
    thread::{self, JoinHandle},
};

use lunette_capture::audio::{AudioError, AudioProcessCandidate};
use lunette_compositor::{
    protocol::{AudioAttributionReply, ProcessObservation},
    spawn::ProcessInspector,
};

#[derive(Clone, Copy)]
pub(super) enum ObservationJob {
    Candidate(AudioProcessCandidate),
    Reply(AudioAttributionReply),
}

pub(super) struct CandidateObserver {
    jobs: Option<SyncSender<ObservationJob>>,
    results: Option<Receiver<(ObservationJob, ProcessObservation)>>,
    shutdown: Arc<AtomicBool>,
    join: Option<JoinHandle<()>>,
}

impl CandidateObserver {
    pub(super) fn new(inspector: Box<dyn ProcessInspector>) -> Result<Self, AudioError> {
        let (jobs, input) = mpsc::sync_channel::<ObservationJob>(64);
        let (output, results) = mpsc::sync_channel(64);
        let shutdown = Arc::new(AtomicBool::new(false));
        let stopping = Arc::clone(&shutdown);
        let join = thread::Builder::new()
            .name("lunette-audio-processes".into())
            .spawn(move || {
                while let Ok(job) = input.recv() {
                    if stopping.load(Ordering::Acquire) {
                        break;
                    }
                    let pid = match job {
                        ObservationJob::Candidate(candidate) => candidate.pid,
                        ObservationJob::Reply(reply) => reply.request.candidate.pid(),
                    };
                    let observation = inspector.observe(pid);
                    if output.send((job, observation)).is_err() {
                        break;
                    }
                }
            })
            .map_err(|error| AudioError::WorkerStart(error.to_string()))?;
        Ok(Self {
            jobs: Some(jobs),
            results: Some(results),
            shutdown,
            join: Some(join),
        })
    }

    pub(super) fn submit(&self, job: ObservationJob) -> Result<(), AudioError> {
        self.jobs
            .as_ref()
            .ok_or(AudioError::WorkerStopped)?
            .try_send(job)
            .map_err(|error| match error {
                TrySendError::Full(_) => AudioError::CommandQueueFull,
                TrySendError::Disconnected(_) => AudioError::WorkerStopped,
            })
    }

    pub(super) fn poll(&self) -> Vec<(ObservationJob, ProcessObservation)> {
        self.results
            .as_ref()
            .map_or_else(Vec::new, |results| results.try_iter().take(64).collect())
    }
}

impl Drop for CandidateObserver {
    fn drop(&mut self) {
        self.shutdown.store(true, Ordering::Release);
        // Disconnect results before joining so a full output queue cannot block shutdown.
        self.results.take();
        self.jobs.take();
        if let Some(join) = self.join.take()
            && join.join().is_err()
        {
            tracing::error!("audio process observer panicked during shutdown");
        }
    }
}

#[cfg(test)]
pub(super) mod tests_support {
    use super::*;

    pub(crate) struct ObserverControl {
        pub jobs: Receiver<ObservationJob>,
        pub results: SyncSender<(ObservationJob, ProcessObservation)>,
    }

    pub(crate) fn controlled() -> (CandidateObserver, ObserverControl) {
        let (jobs, input) = mpsc::sync_channel(64);
        let (output, results) = mpsc::sync_channel(64);
        (
            CandidateObserver {
                jobs: Some(jobs),
                results: Some(results),
                shutdown: Arc::new(AtomicBool::new(false)),
                join: None,
            },
            ObserverControl {
                jobs: input,
                results: output,
            },
        )
    }
}
