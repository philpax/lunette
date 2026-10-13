//! Linux-only: the control socket, and the thread that accepts on it.
//!
//! `lunctl` sends the running session a Lua chunk and receives the values
//! back ([the Lua API](../../../docs/development/native/lua-api.md#lunctl)). The module provides
//! the transport and the queue. [`eval`] evaluates a chunk on the main thread.
//! [`serialise`] turns the results into a form a socket carries. [`wire`] is
//! that form, and it travels over the socket.
//!
//! # Threads and Lua
//!
//! `docs/development/architecture.md` records the rule the design follows: Rust holds no
//! long-lived reference into Lua. A chunk cannot be evaluated where it
//! arrives. The control thread reads a chunk, puts it on a bounded queue, and
//! waits for an answer. The main thread takes the chunk off that queue between
//! two frames, evaluates it, and answers. The control thread never touches a
//! `Lua`.
//!
//! # Deadlock avoidance
//!
//! `lunette-compositor`'s module documentation sets out the cycle two bounded
//! channels can form when both sides block, and `crate::restart` records how
//! the compositor handshake avoids it. The control thread is a third party.
//! The rule that keeps it out of the cycle: the main thread never waits on it.
//! [`ChunkQueue::drain`] takes what is already queued and returns. It does not
//! block for a chunk, and it cannot block to answer one. The reply channel has
//! room for exactly one value, the answer.
//!
//! The control thread waits in one direction, under the bound [`REPLY_TIMEOUT`].
//! A session that has stopped drawing costs a `lunctl` invocation a wait and
//! an answer, not a hang.
//!
//! # Backpressure
//!
//! The queue is bounded at [`QUEUE_DEPTH`]. A client flooding chunks receives
//! [`Reply::Busy`] and cannot grow the queue. The session works through the
//! queue one frame boundary at a time, and the compositor's command channel is
//! bounded for the same reason.

pub mod eval;
pub mod identifier;
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

use tracing::{debug, info, warn};

pub use crate::control::{
    eval::answer,
    socket::{BindError, ControlSocket},
    wire::Reply,
};

/// How many chunks may be waiting for the session at once.
const QUEUE_DEPTH: usize = 4;

/// How many chunks one frame boundary answers.
///
/// A bound on how much of a boundary a flood of chunks may take, not on how
/// many can be waiting. The rest stay queued and are answered at the next
/// boundary, a frame later.
pub const CHUNKS_PER_FRAME: usize = 4;

/// How long the control thread waits for the session to answer one chunk.
///
/// The wait is generous, because the session answers between frames and a
/// long frame is not a reason to end the wait. The wait is bounded, because
/// a session that has stopped drawing would otherwise leave `lunctl` waiting
/// indefinitely with nothing to report.
const REPLY_TIMEOUT: Duration = Duration::from_secs(30);

/// How long a connection has to send its chunk. After that time, the
/// connection is dropped.
///
/// A client that connects and sends nothing would otherwise hold the accept
/// loop, and the accept loop is serial.
const READ_TIMEOUT: Duration = Duration::from_secs(5);

/// Whether the session offers a control socket.
///
/// `docs/development/native/lua-api.md` requires the switch: `lunctl` is equivalent to root access
/// on the user's session, and a user who wants no evaluation endpoint must be
/// able to have none. The switch defaults to enabled, because in-headset
/// iteration is the purpose of the endpoint.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum ControlSwitch {
    #[default]
    Enabled,
    Disabled,
}

impl ControlSwitch {
    /// Reads the switch from the value the entry point read from the environment.
    ///
    /// The argument is the value, not the variable name, because a library does
    /// not read the environment.
    ///
    /// Unset and empty mean enabled, so any other value is an attempt to
    /// disable. An unrecognised value is an attempt to disable with the wrong
    /// spelling: `false`, `0`, `no`, `disabled`. Answering such a value with a
    /// socket that evaluates arbitrary Lua would be the failure the switch
    /// prevents. The warning goes to stderr; a user who set the variable in a
    /// systemd unit may never read it, so the return value reports the
    /// decision. Anything that is not `on` is off.
    #[must_use]
    pub fn from_setting(setting: Option<&str>) -> Self {
        match setting.map(str::trim) {
            None | Some("") => Self::Enabled,
            Some(value) if value.eq_ignore_ascii_case("on") => Self::Enabled,
            Some(value) if value.eq_ignore_ascii_case("off") => Self::Disabled,
            Some(value) => {
                warn!(
                    "lunctl: '{value}' is not 'on' or 'off', so the control socket is disabled; \
                     say 'on' to have one"
                );
                Self::Disabled
            }
        }
    }
}

/// Starts the control thread unless the switch disables it.
///
/// `runtime_directory` is `$XDG_RUNTIME_DIR`, resolved by the entry point.
///
/// # Errors
///
/// As [`ControlSocket::bind`]. A session without a control socket is still a
/// session, so the caller reports and continues.
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
/// Split from [`start`]; a test can bind its own socket in a temporary
/// directory and run the thread against it.
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

/// The accepting thread, for the session's lifetime.
#[derive(Debug)]
pub struct ControlThread {
    thread: Option<JoinHandle<()>>,
    stopping: Arc<AtomicBool>,
    path: PathBuf,
}

impl ControlThread {
    /// Stops the thread and waits for it.
    ///
    /// The flag alone is not enough: the thread is blocked in `accept`, which
    /// no flag reaches. A connection to the thread's own socket wakes it, and
    /// the thread checks the flag before doing anything with what it accepted.
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
    /// `answer` runs when a chunk is present. A caller can build its view of the
    /// Lua state inside the closure, so an empty queue builds nothing. Nothing
    /// obtained from Lua outlives the call.
    ///
    /// `limit` bounds how much of a frame boundary a flood of chunks may take.
    ///
    /// Returns how many it answered.
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

/// One chunk, and the channel that carries its answer back.
#[derive(Debug)]
struct Request {
    chunk: String,
    reply: SyncSender<Reply>,
}

impl Request {
    /// Sends the answer back.
    ///
    /// Cannot block: the channel has room for exactly one value, and this is
    /// the single send. A connection that has already gone away leaves the
    /// receiver dropped, so the send fails and the answer is discarded.
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
                // keeps failing, and a spin on a dead listener is worse than
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

/// Reads one chunk, queues it, and writes what comes back.
///
/// One connection at a time, and one chunk per connection. A `lunctl`
/// invocation is a shell command, not a session. The serial accept loop means
/// at most `QUEUE_DEPTH` chunks are in flight at once.
fn serve_connection(mut stream: UnixStream, sender: &SyncSender<Request>) {
    if let Err(error) = stream.set_read_timeout(Some(READ_TIMEOUT)) {
        debug!(%error, "a lunctl connection could not be given a read timeout");
    }

    let reply = match wire::read_request(&mut stream) {
        // A chunk that could not be read is still answered. Closing on one
        // reaches the client as an end of file, which the client reports as a
        // session it could not reach. The session is present.
        Err(error) => Reply::Malformed(error.to_string()),
        Ok(request) => match request.version_mismatch(wire::PROTOCOL_VERSION) {
            None => submit(sender, request.chunk),
            Some(reply) => reply,
        },
    };

    write_answer(&mut stream, &reply);
    // The client reads until the peer closes, so the shutdown ends its read;
    // the process exiting eventually is not enough.
    if let Err(error) = stream.shutdown(Shutdown::Both) {
        debug!(%error, "a lunctl connection could not be shut down");
    }
}

/// Writes one answer, and reports when the answer itself does not fit.
///
/// A reply larger than a frame is the one write failure with a remedy.
/// `wire::write_frame` refuses an oversized body before writing any of it, so
/// the stream is untouched and the substitute is the first thing on it.
/// Every other failure is in the connection itself, where a second write would
/// fail again.
fn write_answer(stream: &mut UnixStream, reply: &Reply) {
    let Err(error) = wire::write_reply(stream, reply) else {
        return;
    };

    let wire::WireError::TooLarge { length } = error else {
        debug!(%error, "a lunctl answer could not be written back");
        return;
    };

    debug!(%length, "a lunctl answer was larger than one frame carries");
    let oversized = Reply::Oversized {
        length: u64::try_from(length).unwrap_or(u64::MAX),
    };
    if let Err(error) = wire::write_reply(stream, &oversized) {
        debug!(%error, "a lunctl connection could not be told its answer was too large");
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
        // Backpressure, not a growing queue: the session works through chunks
        // one frame boundary at a time, and a client that produces them faster
        // receives [`Reply::Busy`].
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

    /// Waits for `condition`, not for a duration.
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

    /// The whole path: a chunk over the socket, an evaluation on the thread
    /// that owns the state, and a nested table back.
    #[test]
    fn a_chunk_over_the_socket_is_evaluated_and_its_nested_table_comes_back() {
        let runtime = runtime();
        let socket = ControlSocket::bind(runtime.path()).expect("the socket binds");
        let path = socket.path().to_owned();
        let (_thread, queue) = serve(socket);

        let asking =
            thread::spawn(move || ask(&path, "return { count = 2, names = { 'a', 'b' } }"));

        // The frame loop's part, on the thread that owns the state.
        let lua = crate::test_lua::session_lua();
        until(|| queue.drain(CHUNKS_PER_FRAME, |chunk| answer(&lua, chunk)) > 0);

        let Reply::Returned(values) = asking.join().expect("the client thread finishes") else {
            panic!("the chunk returns a value");
        };
        let Value::Table(table) = &values[0] else {
            panic!("{:?} is not a table", values[0]);
        };

        // Membership, not order: a hash part has no order of its own, so
        // the traversal order is not something to assert on. The wire
        // preserves whichever order it received, and specifies no stronger
        // guarantee.
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
        // Against the queue itself, not through the socket. The case under
        // test is a session that cannot keep up, and filling the queue over a
        // socket first would race the drain the test observes.
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

    /// A session that stopped drawing must not leave a client waiting, and the
    /// answer must not report that the chunk ran.
    #[test]
    fn a_session_that_never_answers_is_reported_rather_than_waited_on_forever() {
        let (sender, receiver) = mpsc::sync_channel(QUEUE_DEPTH);
        drop(receiver);

        assert_eq!(submit(&sender, "return 1".to_owned()), Reply::Unanswered);
    }

    #[test]
    fn a_chunk_from_another_protocol_version_is_named_rather_than_evaluated() {
        let runtime = runtime();
        let socket = ControlSocket::bind(runtime.path()).expect("the socket binds");
        let path = socket.path().to_owned();
        let (_thread, queue) = serve(socket);

        let mut stream = UnixStream::connect(&path).expect("the socket accepts");
        let mut body = vec![wire::PROTOCOL_VERSION.wrapping_add(1)];
        body.extend_from_slice(b"return 1");
        let length = u32::try_from(body.len()).expect("it fits");
        io::Write::write_all(&mut stream, &length.to_le_bytes()).expect("the length is written");
        io::Write::write_all(&mut stream, &body).expect("the body is written");

        assert_eq!(
            wire::read_reply(&mut stream).expect("an answer comes back"),
            Reply::Incompatible {
                session: wire::PROTOCOL_VERSION,
                client: wire::PROTOCOL_VERSION.wrapping_add(1),
            }
        );
        assert_eq!(
            queue.drain(4, |_| Reply::Busy),
            0,
            "nothing that could not be understood reaches the session"
        );
    }

    /// A request that cannot be read is answered too, for the same reason.
    #[test]
    fn a_request_that_cannot_be_read_is_answered_rather_than_closed_on() {
        let runtime = runtime();
        let socket = ControlSocket::bind(runtime.path()).expect("the socket binds");
        let path = socket.path().to_owned();
        let (_thread, queue) = serve(socket);

        let mut stream = UnixStream::connect(&path).expect("the socket accepts");
        // A well-formed frame whose chunk is not text. Lua source in some other
        // encoding is a mistake to report, not to compile.
        let body = vec![wire::PROTOCOL_VERSION, 0xff, 0xfe];
        let length = u32::try_from(body.len()).expect("it fits");
        io::Write::write_all(&mut stream, &length.to_le_bytes()).expect("the length is written");
        io::Write::write_all(&mut stream, &body).expect("the body is written");

        let reply = wire::read_reply(&mut stream).expect("an answer comes back");
        assert!(matches!(reply, Reply::Malformed(_)), "{reply:?}");
        assert_eq!(
            queue.drain(4, |_| Reply::Busy),
            0,
            "nothing that could not be read reaches the session"
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
    fn the_switch_defaults_to_enabled_and_anything_but_on_disables_it() {
        assert_eq!(ControlSwitch::from_setting(None), ControlSwitch::Enabled);
        assert_eq!(
            ControlSwitch::from_setting(Some("")),
            ControlSwitch::Enabled
        );
        assert_eq!(
            ControlSwitch::from_setting(Some("on")),
            ControlSwitch::Enabled
        );
        assert_eq!(
            ControlSwitch::from_setting(Some(" ON ")),
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
        // Every spelling of "off" a user might reach for. Unset already means
        // enabled, so a value that is neither word is a misspelled attempt to
        // disable, and the endpoint must not open for it.
        for spelling in ["disabled", "false", "0", "no", "of", "OFFF"] {
            assert_eq!(
                ControlSwitch::from_setting(Some(spelling)),
                ControlSwitch::Disabled,
                "'{spelling}' must not open the endpoint"
            );
        }
    }

    #[test]
    fn stopping_the_thread_unlinks_the_socket() {
        let runtime = runtime();
        let socket = ControlSocket::bind(runtime.path()).expect("the socket binds");
        let path = socket.path().to_owned();
        let (mut thread, _queue) = serve(socket);
        assert!(path.exists());

        thread.stop();

        assert!(!path.exists());
    }
}
