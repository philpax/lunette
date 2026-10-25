//! Promotes hot functions with native code generated on a worker thread, so compiling a large function never lands inside a frame.
//!
//! The Lua thread takes a job between frames, the worker compiles it, and a later step binds it. One job is in flight at a time, which keeps
//! the handoff bounded and the binding order the order in which functions became hot.

use std::{
    io,
    sync::mpsc::{Receiver, SyncSender, TryRecvError, sync_channel},
    thread::{self, JoinHandle},
};

use mlua::Lua;

use crate::execution::{HotJob, InstructionBudget, bind_hot, discard_hot, take_hot};

/// Owns the compile worker for one VM in [`super::ExecutionMode::Tiered`].
///
/// [`Promoter::shutdown`] runs before the VM closes. Dropping a promoter instead waits for the job in flight and leaks it, because
/// discarding needs the VM; its functions stay pinned until the VM closes.
pub struct Promoter {
    budget: InstructionBudget,
    worker: Option<Worker>,
    compiling: bool,
}

struct Worker {
    jobs: SyncSender<HotJob>,
    compiled: Receiver<HotJob>,
    thread: JoinHandle<()>,
}

impl Promoter {
    /// Starts the compile worker.
    pub fn spawn(budget: InstructionBudget) -> io::Result<Self> {
        // Each channel holds the single job in flight, so neither side blocks while sending it.
        let (jobs, pending) = sync_channel::<HotJob>(1);
        let (finished, compiled) = sync_channel::<HotJob>(1);
        let thread = thread::Builder::new()
            .name("luau-compile".into())
            .spawn(move || {
                for mut job in pending {
                    job.compile();
                    // A promoter that is gone cannot discard the job on its VM, and dropping a job leaks it.
                    if finished.send(job).is_err() {
                        break;
                    }
                }
            })?;
        Ok(Self {
            budget,
            worker: Some(Worker {
                jobs,
                compiled,
                thread,
            }),
            compiling: false,
        })
    }

    /// Binds the job the worker finished, if any, then hands it the next functions to compile. Returns how many functions were bound.
    ///
    /// It runs between frames on the Lua thread that owns `lua`, which is the VM every job of this promoter comes from.
    pub fn step(&mut self, lua: &Lua) -> mlua::Result<usize> {
        let worker = self.worker.as_ref().ok_or_else(stopped)?;
        let mut bound = 0;
        if self.compiling {
            match worker.compiled.try_recv() {
                Ok(job) => {
                    self.compiling = false;
                    bound = bind_hot(lua, job)?;
                }
                Err(TryRecvError::Empty) => return Ok(0),
                Err(TryRecvError::Disconnected) => return Err(stopped()),
            }
        }
        if let Some(job) = take_hot(lua, self.budget)? {
            // The worker is idle and its queue empty, so this never waits.
            worker.jobs.send(job).map_err(|_| stopped())?;
            self.compiling = true;
        }
        Ok(bound)
    }

    /// Waits for the job in flight, discards it, and stops the worker. It runs on the Lua thread before the VM closes.
    pub fn shutdown(mut self, lua: &Lua) -> mlua::Result<()> {
        let Some(worker) = self.worker.take() else {
            return Ok(());
        };
        let Worker {
            jobs,
            compiled,
            thread,
        } = worker;
        drop(jobs);
        let mut result = Ok(());
        if self.compiling {
            self.compiling = false;
            result = match compiled.recv() {
                Ok(job) => discard_hot(lua, job),
                Err(_) => Err(stopped()),
            };
        }
        if thread.join().is_err() {
            result = result.and(Err(mlua::Error::runtime(
                "lua execution: the compile worker panicked",
            )));
        }
        result
    }
}

impl Drop for Promoter {
    fn drop(&mut self) {
        let Some(Worker {
            jobs,
            compiled,
            thread,
        }) = self.worker.take()
        else {
            return;
        };
        drop(jobs);
        // The worker must finish reading the job before the VM can close. Only the VM could discard it, so dropping it leaks it.
        if self.compiling {
            drop(compiled.recv());
        }
        drop(thread.join());
    }
}

fn stopped() -> mlua::Error {
    mlua::Error::runtime("lua execution: the compile worker has stopped")
}
