//! Linux-only: the control socket, and the thread that accepts on it.
//!
//! `lunctl` hands the running session a Lua chunk and gets the values back
//! ([the Lua API](../../../docs/lua-api.md#lunctl)). This module is the transport
//! and the queue; [`eval`] is what the main thread does with a chunk once it has one,
//! [`serialise`] is what turns
//! the results into something a socket carries, and [`wire`] is what travels over
//! it.
//!
//! # The thread does not touch Lua
//!
//! `docs/architecture.md` records the rule the whole design rests on: Rust holds
//! no long-lived reference into Lua. It follows that a chunk cannot be evaluated
//! where it arrives. The control thread reads a chunk, puts it on a bounded
//! queue, and waits for an answer; the *main* thread takes it off that queue
//! between two frames, evaluates it, and answers. Nothing in this module ever
//! sees a `Lua`.
//!
//! # Why this cannot deadlock
//!
//! `lunette-compositor`'s module documentation sets out the cycle two bounded
//! channels can form when both sides block, and `crate::restart` records how the
//! compositor handshake avoids it. The control thread is a third party, and the
//! rule that keeps it out of the cycle is that **the main thread never waits on
//! it**. [`ChunkQueue::drain`] takes what is already queued and returns; it does
//! not block for a chunk, and it does not block to answer one, because the reply
//! channel has room for exactly the answer it is about to put in it.
//!
//! The control thread does wait, in one direction only, and under a bound:
//! [`REPLY_TIMEOUT`]. A session that has stopped drawing therefore costs a
//! `lunctl` invocation a wait and an answer rather than a hang.
//!
//! # Backpressure
//!
//! The queue is bounded at [`QUEUE_DEPTH`]. A client flooding chunks is answered
//! [`Reply::Busy`] rather than growing a queue the session will never work
//! through, which is the same reason the compositor's command channel is
//! bounded.

pub mod eval;
pub mod serialise;
pub mod socket;
pub mod wire;

use std::{
    io,
    net::Shutdown,
    os::unix::net::UnixStream,
    path::{Path, PathBuf},
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
        mpsc::{self, Receiver, RecvTimeoutError, SyncSender, TrySendError},
    },
    thread::{self, JoinHandle},
    time::Duration,
};

use mlua::Lua;
use tracing::{debug, info, warn};

use crate::control::eval::{Evaluation, evaluate};
pub use crate::control::{
    eval::Budget,
    socket::{BindError, ControlSocket},
    wire::Reply,
};

/// How many chunks may be waiting for the session at once.
const QUEUE_DEPTH: usize = 4;

/// How many chunks one frame boundary answers.
///
/// A bound on how much of a boundary a flood of chunks may take, rather than on
/// how many can be waiting: the rest stay queued and are answered at the next
/// boundary, a frame later.
pub const CHUNKS_PER_FRAME: usize = 4;

/// How long the control thread waits for the session to answer one chunk.
///
/// Generous, because the session answers between frames and a frame that is
/// taking a long time is not a reason to give up on it. Bounded, because a
/// session that has stopped drawing altogether would otherwise leave `lunctl`
/// hanging with nothing to report.
const REPLY_TIMEOUT: Duration = Duration::from_secs(30);

/// How long a connection has to send its chunk before it is dropped.
///
/// A client that connects and says nothing would otherwise hold the accept loop,
/// and the accept loop is serial.
const READ_TIMEOUT: Duration = Duration::from_secs(5);

/// Whether the session offers a control socket at all.
///
/// `docs/lua-api.md` requires the switch: `lunctl` is equivalent to root access
/// on the user's session, and a user who wants no evaluation endpoint must be
/// able to have none. It defaults to enabled, because in-headset iteration is
/// the reason it exists.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum ControlSwitch {
    #[default]
    Enabled,
    Disabled,
}

impl ControlSwitch {
    /// Reads the switch from what the entry point found in the environment.
    ///
    /// A value rather than a variable name, because a library does not read the
    /// environment. An unrecognised value is enabled with a warning: the failure
    /// this protects against is a typo silently *enabling* the endpoint, and a
    /// typo that silently disabled it would be a session whose `lunctl` stopped
    /// working for no visible reason.
    #[must_use]
    pub fn from_setting(setting: Option<&str>) -> Self {
        match setting.map(str::trim) {
            None | Some("") => Self::Enabled,
            Some(value) if value.eq_ignore_ascii_case("off") => Self::Disabled,
            Some(value) if value.eq_ignore_ascii_case("on") => Self::Enabled,
            Some(value) => {
                warn!(
                    "lunctl: '{value}' is not 'on' or 'off', so the control socket stays enabled; \
                     say 'off' to have none"
                );
                Self::Enabled
            }
        }
    }
}

/// Starts the control thread, unless the switch says not to.
///
/// `runtime_directory` is `$XDG_RUNTIME_DIR`, resolved by the entry point.
///
/// # Errors
///
/// As [`ControlSocket::bind`]. A session without a control socket is still a
/// session, so the caller reports rather than stopping.
pub fn start(
    switch: ControlSwitch,
    runtime_directory: &Path,
) -> Result<Option<(ControlThread, ChunkQueue)>, BindError> {
    if switch == ControlSwitch::Disabled {
        info!("lunctl: the control socket is disabled, so no chunk can be evaluated remotely");
        return Ok(None);
    }

    let socket = ControlSocket::bind(runtime_directory)?;
    Ok(Some(serve(socket)))
}

/// Runs the accept loop for an already-bound socket.
///
/// Split from [`start`] so that a test can bind its own socket in a temporary
/// directory and drive the thread against it.
#[must_use]
pub fn serve(socket: ControlSocket) -> (ControlThread, ChunkQueue) {
    let (sender, receiver) = mpsc::sync_channel(QUEUE_DEPTH);
    let stopping = Arc::new(AtomicBool::new(false));
    let path = socket.path().to_owned();

    let thread = {
        let stopping = Arc::clone(&stopping);
        thread::Builder::new()
            .name("lunette-control".to_owned())
            .spawn(move || accept_loop(&socket, &sender, &stopping))
    };

    let thread = match thread {
        Ok(handle) => Some(handle),
        Err(error) => {
            warn!("lunctl: the control thread could not be started: {error}");
            None
        }
    };

    (
        ControlThread {
            thread,
            stopping,
            path,
        },
        ChunkQueue { receiver },
    )
}

/// The accepting thread, for as long as the session wants one.
#[derive(Debug)]
pub struct ControlThread {
    thread: Option<JoinHandle<()>>,
    stopping: Arc<AtomicBool>,
    path: PathBuf,
}

impl ControlThread {
    /// The path a client connects to.
    #[must_use]
    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Stops the thread and waits for it.
    ///
    /// The flag alone would not be enough: the thread is blocked in `accept`,
    /// which no flag reaches. A connection to its own socket is what wakes it,
    /// and it checks the flag before doing anything with what it accepted.
    pub fn stop(&mut self) {
        let Some(thread) = self.thread.take() else {
            return;
        };

        self.stopping.store(true, Ordering::Release);
        if let Err(error) = UnixStream::connect(&self.path) {
            debug!(%error, "the control thread's socket could not be poked awake");
        }

        if thread.join().is_err() {
            warn!("lunctl: the control thread panicked");
        }
    }
}

impl Drop for ControlThread {
    fn drop(&mut self) {
        self.stop();
    }
}

/// Where the main thread takes chunks off.
#[derive(Debug)]
pub struct ChunkQueue {
    receiver: Receiver<Request>,
}

impl ChunkQueue {
    /// Answers up to `limit` waiting chunks, and returns.
    ///
    /// Called between frames, on the thread that owns the Lua state. It never
    /// blocks: a queue with nothing on it costs one non-blocking receive, and
    /// `answer` is called only for a chunk that is actually there — so a caller
    /// can build its view of the Lua state inside the closure rather than once a
    /// frame for nothing.
    ///
    /// `limit` bounds how much of a frame boundary a flood of chunks may take.
    ///
    /// Returns how many were answered.
    pub fn drain(&self, limit: usize, mut answer: impl FnMut(&str) -> Reply) -> usize {
        let mut answered = 0;
        while answered < limit {
            let Ok(request) = self.receiver.try_recv() else {
                break;
            };
            let reply = answer(&request.chunk);
            request.answer(reply);
            answered += 1;
        }
        answered
    }
}

/// Evaluates one chunk against the Lua state and renders the answer.
///
/// Called from the frame loop, between two frames, on the thread that owns the
/// state. Everything it obtains from Lua is consumed before it returns.
#[must_use]
pub fn answer(lua: &Lua, chunk: &str, budget: Budget) -> Reply {
    match evaluate(lua, chunk, budget, serialise::render) {
        Evaluation::Returned(values) => Reply::Returned(values),
        Evaluation::LoadFailed(message) => Reply::LoadError(message),
        Evaluation::Raised(message) => Reply::RuntimeError(message),
        Evaluation::Abandoned { after } => Reply::Abandoned { after },
        Evaluation::Unrepresentable(error) => Reply::Unrepresentable(error.to_string()),
        // Structurally unreachable from here — the frame loop is the only caller
        // and it is not itself inside a chunk — and answered rather than
        // asserted, because a client waiting on a socket deserves a reason.
        Evaluation::Reentered => {
            Reply::RuntimeError("lunctl: a chunk cannot be evaluated from inside one".to_owned())
        }
    }
}

/// One chunk, and the channel its answer goes back down.
#[derive(Debug)]
struct Request {
    chunk: String,
    reply: SyncSender<Reply>,
}

impl Request {
    /// Sends the answer back.
    ///
    /// Cannot block: the channel has room for exactly one value and this is the
    /// only send. A connection that has already given up leaves the receiver
    /// dropped, which is a discarded answer rather than an error.
    fn answer(self, reply: Reply) {
        if self.reply.send(reply).is_err() {
            debug!("a lunctl connection went away before its answer was ready");
        }
    }
}

/// Accepts connections until the session stops the thread.
fn accept_loop(socket: &ControlSocket, sender: &SyncSender<Request>, stopping: &AtomicBool) {
    for stream in socket.listener().incoming() {
        if stopping.load(Ordering::Acquire) {
            break;
        }

        match stream {
            Ok(stream) => serve_connection(stream, sender),
            Err(error) => {
                warn!("lunctl: a connection could not be accepted: {error}");
                // An accept that fails for a reason other than a transient one
                // will keep failing, and a spin on a dead listener is worse than
                // a session with no control socket.
                if !transient(&error) {
                    break;
                }
            }
        }
    }

    debug!("the control thread stopped accepting");
}

/// Whether an accept failure is worth continuing after.
fn transient(error: &io::Error) -> bool {
    matches!(
        error.kind(),
        io::ErrorKind::Interrupted | io::ErrorKind::ConnectionAborted | io::ErrorKind::WouldBlock
    )
}

/// Reads one chunk, queues it, and writes what came back.
///
/// One connection at a time, and one chunk per connection. A `lunctl` invocation
/// is a shell command rather than a session, and the accept loop being serial is
/// what keeps the number of chunks in flight equal to the queue depth rather
/// than to the number of processes that felt like connecting.
fn serve_connection(mut stream: UnixStream, sender: &SyncSender<Request>) {
    if let Err(error) = stream.set_read_timeout(Some(READ_TIMEOUT)) {
        debug!(%error, "a lunctl connection could not be given a read timeout");
    }

    let request = match wire::read_request(&mut stream) {
        Ok(request) => request,
        Err(error) => {
            debug!(%error, "a lunctl connection sent nothing that could be read");
            return;
        }
    };

    let reply = if request.version == wire::PROTOCOL_VERSION {
        submit(sender, request.chunk)
    } else {
        Reply::Incompatible {
            expected: wire::PROTOCOL_VERSION,
            found: request.version,
        }
    };

    if let Err(error) = wire::write_reply(&mut stream, &reply) {
        debug!(%error, "a lunctl answer could not be written back");
    }
    // The client reads until the peer closes, so the shutdown is what ends its
    // read rather than the process exiting eventually.
    if let Err(error) = stream.shutdown(Shutdown::Both) {
        debug!(%error, "a lunctl connection could not be shut down");
    }
}

/// Queues one chunk and waits for the session's answer.
fn submit(sender: &SyncSender<Request>, chunk: String) -> Reply {
    let (reply_sender, reply_receiver) = mpsc::sync_channel(1);
    let request = Request {
        chunk,
        reply: reply_sender,
    };

    match sender.try_send(request) {
        Ok(()) => {}
        // Backpressure rather than a growing queue: the session works through
        // chunks at one frame boundary at a time, and a client that can produce
        // them faster than that is told so.
        Err(TrySendError::Full(_)) => return Reply::Busy,
        Err(TrySendError::Disconnected(_)) => return Reply::Unanswered,
    }

    match reply_receiver.recv_timeout(REPLY_TIMEOUT) {
        Ok(reply) => reply,
        Err(RecvTimeoutError::Timeout) => {
            warn!(
                "lunctl: the session did not answer a chunk within {REPLY_TIMEOUT:?}; it may have \
                 stopped drawing"
            );
            Reply::Unanswered
        }
        Err(RecvTimeoutError::Disconnected) => Reply::Unanswered,
    }
}

#[cfg(test)]
#[expect(
    clippy::expect_used,
    reason = "a failed expectation is how a test reports a failure; the ban is on production code"
)]
mod tests {
    use std::{fs, os::unix::fs::PermissionsExt, time::Instant};

    use pretty_assertions::assert_eq;
    use tempfile::TempDir;

    use super::*;
    use crate::control::wire::{Key, TableValue, Value};

    /// A runtime directory of the shape the XDG specification requires.
    fn runtime() -> TempDir {
        let directory = TempDir::new().expect("a temporary directory can be created");
        fs::set_permissions(directory.path(), fs::Permissions::from_mode(0o700))
            .expect("the mode can be set");
        directory
    }

    /// Sends one chunk and reads the answer, as `lunctl` does.
    fn ask(path: &Path, chunk: &str) -> Reply {
        let mut stream = UnixStream::connect(path).expect("the socket accepts");
        wire::write_request(&mut stream, chunk).expect("the chunk is written");
        wire::read_reply(&mut stream).expect("an answer comes back")
    }

    /// Waits for `condition`, rather than for a duration.
    fn until(mut condition: impl FnMut() -> bool) {
        let deadline = Instant::now() + Duration::from_secs(5);
        while Instant::now() < deadline {
            if condition() {
                return;
            }
            thread::yield_now();
        }
        panic!("the condition did not hold within the bound");
    }

    #[test]
    fn a_chunk_reaches_the_session_and_its_answer_comes_back() {
        let runtime = runtime();
        let (thread, queue) = serve(ControlSocket::bind(runtime.path()).expect("the socket binds"));
        let path = thread.path().to_owned();

        let asking = thread::spawn(move || ask(&path, "return 1 + 1"));

        // The main thread's part: drain until something was there to drain.
        let mut seen = None;
        until(|| {
            queue.drain(4, |chunk| {
                seen = Some(chunk.to_owned());
                Reply::Returned(vec![Value::Integer(2)])
            }) > 0
        });

        assert_eq!(seen.as_deref(), Some("return 1 + 1"));
        assert_eq!(
            asking.join().expect("the client thread finishes"),
            Reply::Returned(vec![Value::Integer(2)]),
        );
    }

    /// The whole path `lunette-v1.AC8.1` asks for: a chunk over the socket, an
    /// evaluation on the thread that owns the state, and a nested table back.
    #[test]
    fn a_chunk_over_the_socket_is_evaluated_and_its_nested_table_comes_back() {
        let runtime = runtime();
        let (thread, queue) = serve(ControlSocket::bind(runtime.path()).expect("the socket binds"));
        let path = thread.path().to_owned();

        let asking =
            thread::spawn(move || ask(&path, "return { count = 2, names = { 'a', 'b' } }"));

        // The frame loop's part, on the thread that owns the state.
        let lua = Lua::new();
        until(|| {
            queue.drain(CHUNKS_PER_FRAME, |chunk| {
                answer(&lua, chunk, Budget::DEFAULT)
            }) > 0
        });

        let Reply::Returned(values) = asking.join().expect("the client thread finishes") else {
            panic!("the chunk returns a value");
        };
        let Value::Table(table) = &values[0] else {
            panic!("{:?} is not a table", values[0]);
        };

        // Membership rather than order: a hash part has no order of its own, and
        // LuaJIT seeds its string hash per state, so two runs can traverse the
        // same table two ways. The wire preserves whichever order it was given,
        // and that is all it promises.
        assert!(
            table.array.is_empty(),
            "the chunk returned no array part: {:?}",
            table.array
        );
        assert!(
            table
                .entries
                .contains(&(Key::String(b"count".to_vec()), Value::Integer(2))),
            "{:?}",
            table.entries
        );
        assert!(
            table.entries.contains(&(
                Key::String(b"names".to_vec()),
                Value::Table(TableValue {
                    array: vec![Value::String(b"a".to_vec()), Value::String(b"b".to_vec())],
                    entries: Vec::new(),
                })
            )),
            "a nested table arrives nested: {:?}",
            table.entries
        );
    }

    /// A chunk that never finishes must not hold the frame loop, and the client
    /// must be told what happened rather than left waiting.
    #[test]
    fn a_chunk_that_overruns_its_budget_is_answered_rather_than_stalling_the_loop() {
        let runtime = runtime();
        let (thread, queue) = serve(ControlSocket::bind(runtime.path()).expect("the socket binds"));
        let path = thread.path().to_owned();

        let asking = thread::spawn(move || ask(&path, "while true do end"));

        // The budget is what is under test here, so this duration is the
        // measurement rather than a wait for something else to happen.
        let lua = Lua::new();
        let budget = Budget::of(Duration::from_millis(50));
        until(|| queue.drain(CHUNKS_PER_FRAME, |chunk| answer(&lua, chunk, budget)) > 0);

        let reply = asking.join().expect("the client thread finishes");
        let Reply::Abandoned { after } = reply else {
            panic!("expected the budget to end it, and lunctl answered {reply:?}");
        };
        assert!(after >= Duration::from_millis(50), "{after:?}");
    }

    #[test]
    fn a_drain_with_nothing_queued_answers_nothing_and_returns() {
        let runtime = runtime();
        let (_thread, queue) =
            serve(ControlSocket::bind(runtime.path()).expect("the socket binds"));

        let mut called = false;
        let answered = queue.drain(4, |_| {
            called = true;
            Reply::Busy
        });

        assert_eq!(answered, 0);
        assert!(
            !called,
            "a frame boundary with nothing queued does no work at all"
        );
    }

    #[test]
    fn a_full_queue_applies_backpressure_rather_than_growing() {
        // Against the queue itself rather than through the socket, because what
        // is under test is what happens when the session cannot keep up, and a
        // test that had to fill the queue over a socket first would be racing
        // the very drain it wants not to happen.
        let (sender, _receiver) = mpsc::sync_channel(QUEUE_DEPTH);
        let mut queued = Vec::new();
        for index in 0..QUEUE_DEPTH {
            let (reply, receiver) = mpsc::sync_channel(1);
            sender
                .try_send(Request {
                    chunk: format!("return {index}"),
                    reply,
                })
                .expect("the queue has room until it is full");
            queued.push(receiver);
        }

        assert_eq!(submit(&sender, "return 1".to_owned()), Reply::Busy);
    }

    /// A session that stopped drawing must not leave a client hanging, and it
    /// must not claim the chunk ran either.
    #[test]
    fn a_session_that_never_answers_is_reported_rather_than_waited_on_forever() {
        let (sender, receiver) = mpsc::sync_channel(QUEUE_DEPTH);
        drop(receiver);

        assert_eq!(submit(&sender, "return 1".to_owned()), Reply::Unanswered);
    }

    #[test]
    fn a_chunk_from_another_protocol_version_is_named_rather_than_evaluated() {
        let runtime = runtime();
        let (thread, queue) = serve(ControlSocket::bind(runtime.path()).expect("the socket binds"));
        let path = thread.path().to_owned();

        let mut stream = UnixStream::connect(&path).expect("the socket accepts");
        let mut body = vec![wire::PROTOCOL_VERSION.wrapping_add(1)];
        body.extend_from_slice(b"return 1");
        let length = u32::try_from(body.len()).expect("it fits");
        io::Write::write_all(&mut stream, &length.to_le_bytes()).expect("the length is written");
        io::Write::write_all(&mut stream, &body).expect("the body is written");

        assert_eq!(
            wire::read_reply(&mut stream).expect("an answer comes back"),
            Reply::Incompatible {
                expected: wire::PROTOCOL_VERSION,
                found: wire::PROTOCOL_VERSION.wrapping_add(1),
            }
        );
        assert_eq!(
            queue.drain(4, |_| Reply::Busy),
            0,
            "nothing that could not be understood reaches the session"
        );
    }

    #[test]
    fn the_disable_switch_creates_no_socket_at_all() {
        let runtime = runtime();

        let started = start(ControlSwitch::Disabled, runtime.path()).expect("it does not fail");

        assert!(started.is_none());
        assert!(
            !runtime.path().join(socket::DIRECTORY_NAME).exists(),
            "a disabled control socket leaves no directory behind either"
        );
    }

    #[test]
    fn the_switch_defaults_to_enabled_and_only_off_disables_it() {
        assert_eq!(ControlSwitch::from_setting(None), ControlSwitch::Enabled);
        assert_eq!(
            ControlSwitch::from_setting(Some("")),
            ControlSwitch::Enabled
        );
        assert_eq!(
            ControlSwitch::from_setting(Some("off")),
            ControlSwitch::Disabled
        );
        assert_eq!(
            ControlSwitch::from_setting(Some(" OFF ")),
            ControlSwitch::Disabled
        );
        assert_eq!(
            ControlSwitch::from_setting(Some("on")),
            ControlSwitch::Enabled
        );
        // A typo leaves it enabled: the failure worth protecting against is one
        // that silently opens the endpoint, not one that silently closes it.
        assert_eq!(
            ControlSwitch::from_setting(Some("disabled")),
            ControlSwitch::Enabled
        );
    }

    #[test]
    fn stopping_the_thread_unlinks_the_socket() {
        let runtime = runtime();
        let (mut thread, _queue) =
            serve(ControlSocket::bind(runtime.path()).expect("the socket binds"));
        let path = thread.path().to_owned();
        assert!(path.exists());

        thread.stop();

        assert!(!path.exists());
    }
}
