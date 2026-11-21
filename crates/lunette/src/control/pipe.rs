//! Local Windows control transport authenticated by the session's logon SID.

use std::{
    ffi::c_void,
    fs::OpenOptions,
    io::{self, Read, Write},
    mem::size_of,
    os::windows::{
        ffi::OsStrExt,
        fs::OpenOptionsExt,
        io::{AsRawHandle, FromRawHandle, OwnedHandle},
    },
    path::{Path, PathBuf},
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
        mpsc::{self, SyncSender},
    },
    thread::{self, JoinHandle},
    time::{Duration, Instant},
};

use tracing::{debug, warn};
use windows::{
    Win32::{
        Foundation::{
            ERROR_BROKEN_PIPE, ERROR_IO_PENDING, ERROR_PIPE_BUSY, ERROR_PIPE_CONNECTED,
            ERROR_PIPE_NOT_CONNECTED, HANDLE, HLOCAL, LocalFree, WAIT_TIMEOUT,
        },
        Security::{
            Authorization::{
                ConvertSidToStringSidW, ConvertStringSecurityDescriptorToSecurityDescriptorW,
                SDDL_REVISION_1,
            },
            GetTokenInformation, PSECURITY_DESCRIPTOR, PSID, SECURITY_ATTRIBUTES, TOKEN_GROUPS,
            TOKEN_INFORMATION_CLASS, TOKEN_MANDATORY_LABEL, TOKEN_QUERY, TokenIntegrityLevel,
            TokenLogonSid,
        },
        Storage::FileSystem::{
            FILE_FLAG_FIRST_PIPE_INSTANCE, FILE_FLAG_OVERLAPPED, PIPE_ACCESS_DUPLEX, ReadFile,
            SECURITY_IDENTIFICATION, WriteFile,
        },
        System::{
            IO::{CancelIoEx, GetOverlappedResult, GetOverlappedResultEx, OVERLAPPED},
            Pipes::{
                ConnectNamedPipe, CreateNamedPipeW, DisconnectNamedPipe,
                GetNamedPipeServerProcessId, PIPE_READMODE_BYTE, PIPE_REJECT_REMOTE_CLIENTS,
                PIPE_TYPE_BYTE, PIPE_WAIT, WaitNamedPipeW,
            },
            Threading::{
                CreateEventW, GetCurrentProcess, OpenProcess, OpenProcessToken,
                PROCESS_QUERY_LIMITED_INFORMATION,
            },
        },
    },
    core::{BOOL, Error, HRESULT, PCWSTR, PWSTR},
};

use super::{
    ChunkQueue, ControlSwitch, QUEUE_DEPTH, READ_TIMEOUT, Request, submit, wire, write_answer,
};

const LOCAL_PREFIX: &str = r"\\.\pipe\";
const ANSWER_TIMEOUT: Duration = Duration::from_secs(35);
const POLL: Duration = Duration::from_millis(40);
const PIPE_BUFFER: u32 = 64 * 1024;

#[derive(Debug)]
pub struct PipeThread {
    control: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
}

impl Drop for PipeThread {
    fn drop(&mut self) {
        self.control.store(true, Ordering::Release);
        if let Some(thread) = self.thread.take()
            && thread.join().is_err()
        {
            warn!("lunctl: the Windows control worker panicked");
        }
    }
}

/// The default pipe for this Windows sign-in session.
///
/// # Errors
///
/// Returns an error when Windows cannot identify the current logon.
pub fn default_path() -> io::Result<PathBuf> {
    Ok(Identity::current()?.path())
}

#[derive(Debug, PartialEq, Eq)]
struct Identity {
    logon: String,
    integrity: String,
}

impl Identity {
    fn current() -> io::Result<Self> {
        // SAFETY: Windows supplies a pseudo-handle limited to the current process.
        Self::of(unsafe { GetCurrentProcess() })
    }

    fn path(&self) -> PathBuf {
        PathBuf::from(format!(
            "{LOCAL_PREFIX}lunette-0-{}-{}",
            self.logon, self.integrity
        ))
    }

    fn of(process: HANDLE) -> io::Result<Self> {
        let mut token = HANDLE::default();
        // SAFETY: process remains live for the call and token is writable.
        unsafe { OpenProcessToken(process, TOKEN_QUERY, &raw mut token) }.map_err(io_error)?;
        // SAFETY: OpenProcessToken returned an owned handle.
        let _token = unsafe { OwnedHandle::from_raw_handle(token.0) };
        let logon = token_information::<TOKEN_GROUPS>(token, TokenLogonSid)?;
        // SAFETY: Windows initialized a suitably aligned TOKEN_GROUPS.
        let groups = unsafe { &*logon.as_ptr().cast::<TOKEN_GROUPS>() };
        if groups.GroupCount != 1 {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "no unique Windows logon SID is available",
            ));
        }
        let integrity = token_information::<TOKEN_MANDATORY_LABEL>(token, TokenIntegrityLevel)?;
        // SAFETY: Windows initialized a suitably aligned TOKEN_MANDATORY_LABEL.
        let label = unsafe { &*integrity.as_ptr().cast::<TOKEN_MANDATORY_LABEL>() };
        Ok(Self {
            logon: sid_string(groups.Groups[0].Sid)?,
            integrity: sid_string(label.Label.Sid)?,
        })
    }
}

/// Creates the pipe before spawning the control worker.
///
/// # Errors
///
/// Returns an error if the ACL cannot be created, another process owns the endpoint, or the worker
/// cannot start. The caller can continue without control.
pub fn start(switch: ControlSwitch) -> io::Result<Option<(PipeThread, ChunkQueue)>> {
    if switch == ControlSwitch::Disabled {
        return Ok(None);
    }
    let identity = Identity::current()?;
    start_at(&identity.path(), &identity).map(Some)
}

fn start_at(path: &Path, identity: &Identity) -> io::Result<(PipeThread, ChunkQueue)> {
    let descriptor = local_descriptor(identity)?;
    let security = SECURITY_ATTRIBUTES {
        nLength: size_of::<SECURITY_ATTRIBUTES>() as u32,
        lpSecurityDescriptor: descriptor.0,
        bInheritHandle: BOOL(0),
    };
    let path = wide_pipe_path(path)?;
    // SAFETY: the UTF-16 path and descriptor remain live for the call. Windows copies the ACL.
    let handle = unsafe {
        CreateNamedPipeW(
            PCWSTR(path.as_ptr()),
            PIPE_ACCESS_DUPLEX | FILE_FLAG_FIRST_PIPE_INSTANCE | FILE_FLAG_OVERLAPPED,
            PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
            1,
            PIPE_BUFFER,
            PIPE_BUFFER,
            5_000,
            Some(&raw const security),
        )
    };
    if handle.is_invalid() {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: a successful CreateNamedPipeW transfers ownership.
    let handle = unsafe { OwnedHandle::from_raw_handle(handle.0) };
    let (sender, receiver) = mpsc::sync_channel(QUEUE_DEPTH);
    let control = Arc::new(AtomicBool::new(false));
    let worker_control = Arc::clone(&control);
    let thread = thread::Builder::new()
        .name("lunette-control".into())
        .spawn(move || {
            let mut stream = PipeStream {
                handle,
                deadline: None,
                stopping: Some(worker_control),
            };
            serve(&mut stream, &sender);
        })?;
    Ok((
        PipeThread {
            control,
            thread: Some(thread),
        },
        ChunkQueue { receiver },
    ))
}

fn serve(stream: &mut PipeStream, sender: &SyncSender<Request>) {
    while !stream.stopping() {
        stream.deadline = None;
        // SAFETY: the pipe owns this connect operation, and I/O is completed or cancelled before returning.
        let connection = unsafe {
            stream.perform(|handle, overlapped| ConnectNamedPipe(handle, Some(overlapped)))
        };
        match connection {
            Ok(_) => {}
            Err(error) if error.raw_os_error() == Some(ERROR_PIPE_CONNECTED.0 as i32) => {}
            Err(error) if !stream.stopping() => {
                warn!(%error, "lunctl: the Windows control pipe stopped accepting connections");
                break;
            }
            Err(_) => break,
        }
        if !stream.stopping() {
            serve_client(stream, sender);
        }
        // SAFETY: all overlapped operations on this server instance have completed.
        let _ = unsafe { DisconnectNamedPipe(stream.handle()) };
    }
}

fn serve_client(stream: &mut PipeStream, sender: &SyncSender<Request>) {
    stream.deadline = Some(Instant::now() + READ_TIMEOUT);
    let reply = match wire::read_request(stream) {
        Err(error) => wire::Reply::Malformed(error.to_string()),
        Ok(request) => match request.version_mismatch(wire::PROTOCOL_VERSION) {
            Some(reply) => reply,
            None => submit(sender, request.chunk, stream.stopping.as_deref()),
        },
    };
    stream.deadline = Some(Instant::now() + READ_TIMEOUT);
    write_answer(stream, &reply);
    // DisconnectNamedPipe discards unread data. The client acknowledges that it received the frame.
    let mut read = [0];
    if let Err(error) = stream.read_exact(&mut read)
        && error.kind() != io::ErrorKind::UnexpectedEof
        && !stream.stopping()
    {
        debug!(%error, "lunctl: the client did not acknowledge its pipe reply");
    }
}

/// One local client connection, with a bounded deadline for overlapped I/O.
#[derive(Debug)]
pub struct PipeStream {
    handle: OwnedHandle,
    deadline: Option<Instant>,
    stopping: Option<Arc<AtomicBool>>,
}

impl PipeStream {
    /// Opens a local named pipe without granting the server impersonation access.
    ///
    /// # Errors
    ///
    /// Returns an error if the path is invalid, the pipe is absent, or it remains busy.
    pub fn connect(path: &Path) -> io::Result<Self> {
        let name = wide_pipe_path(path)?;
        let identity = Identity::current()?;
        let deadline = Instant::now() + READ_TIMEOUT;
        loop {
            match OpenOptions::new()
                .read(true)
                .write(true)
                .custom_flags(FILE_FLAG_OVERLAPPED.0)
                .security_qos_flags(SECURITY_IDENTIFICATION.0)
                .open(path)
            {
                Ok(file) => {
                    let stream = Self {
                        handle: file.into(),
                        deadline: Some(Instant::now() + ANSWER_TIMEOUT),
                        stopping: None,
                    };
                    stream.verify_server(&identity)?;
                    return Ok(stream);
                }
                Err(error)
                    if error.raw_os_error() == Some(ERROR_PIPE_BUSY.0 as i32)
                        && Instant::now() < deadline =>
                {
                    // SAFETY: name is a live, null-terminated local pipe name.
                    let wait = deadline
                        .saturating_duration_since(Instant::now())
                        .as_millis()
                        .max(1);
                    unsafe { WaitNamedPipeW(PCWSTR(name.as_ptr()), wait as u32) }
                        .ok()
                        .map_err(io_error)?;
                }
                Err(error) => return Err(error),
            }
        }
    }

    fn handle(&self) -> HANDLE {
        HANDLE(self.handle.as_raw_handle())
    }

    fn verify_server(&self, identity: &Identity) -> io::Result<()> {
        let mut pid = 0;
        // SAFETY: this is a connected pipe client and pid is writable.
        unsafe { GetNamedPipeServerProcessId(self.handle(), &raw mut pid) }.map_err(io_error)?;
        // SAFETY: Windows validates the PID and gives us an owned query handle.
        let server = unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid) }
            .map_err(io_error)?;
        // SAFETY: keep the queried process object alive through the identity comparison.
        let _server = unsafe { OwnedHandle::from_raw_handle(server.0) };
        if Identity::of(server)? != *identity {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "the pipe server belongs to a different Windows logon or integrity level",
            ));
        }
        Ok(())
    }

    fn stopping(&self) -> bool {
        self.stopping
            .as_deref()
            .is_some_and(|flag| flag.load(Ordering::Acquire))
    }

    fn wait_interval(&self) -> Duration {
        self.deadline.map_or(POLL, |end| {
            POLL.min(end.saturating_duration_since(Instant::now()))
        })
    }

    /// Starting an operation may give Windows access to caller-owned storage until it completes.
    /// The caller must keep that storage alive throughout this call.
    unsafe fn perform(
        &self,
        start: impl FnOnce(HANDLE, *mut OVERLAPPED) -> windows::core::Result<()>,
    ) -> io::Result<usize> {
        if self.stopping() {
            return Err(io::Error::from(io::ErrorKind::ConnectionAborted));
        }
        // SAFETY: creates a private event for a single overlapped operation.
        let event = unsafe { CreateEventW(None, true, false, None) }.map_err(io_error)?;
        // SAFETY: CreateEventW returned an owned kernel handle.
        let _event = unsafe { OwnedHandle::from_raw_handle(event.0) };
        let mut operation = OVERLAPPED {
            hEvent: event,
            ..OVERLAPPED::default()
        };
        let handle = self.handle();
        let mut bytes = 0;
        match start(handle, &raw mut operation) {
            Ok(()) => {
                // SAFETY: a completed operation still refers to this handle and stack storage.
                unsafe { GetOverlappedResult(handle, &raw const operation, &raw mut bytes, false) }
                    .map_err(io_error)?;
                return Ok(bytes as usize);
            }
            Err(error) if error.code() == HRESULT::from_win32(ERROR_IO_PENDING.0) => {}
            Err(error) => return Err(io_error(error)),
        }

        loop {
            let interval = self.wait_interval();
            if interval.is_zero() || self.stopping() {
                // SAFETY: a cancelled operation can still access its buffers until the result has
                // been collected. Cancel and wait before any borrowed storage leaves scope.
                unsafe {
                    let _ = CancelIoEx(handle, Some(&raw const operation));
                    let _ = GetOverlappedResult(handle, &raw const operation, &raw mut bytes, true);
                }
                return Err(io::Error::from(if self.stopping() {
                    io::ErrorKind::ConnectionAborted
                } else {
                    io::ErrorKind::TimedOut
                }));
            }
            // SAFETY: the active operation and all buffers are live until Windows returns a result.
            match unsafe {
                GetOverlappedResultEx(
                    handle,
                    &raw const operation,
                    &raw mut bytes,
                    interval.as_millis().max(1) as u32,
                    false,
                )
            } {
                Ok(()) => return Ok(bytes as usize),
                Err(error) if error.code() == HRESULT::from_win32(WAIT_TIMEOUT.0) => {}
                Err(error) => return Err(io_error(error)),
            }
        }
    }
}

impl Read for PipeStream {
    fn read(&mut self, into: &mut [u8]) -> io::Result<usize> {
        if into.is_empty() {
            return Ok(0);
        }
        // SAFETY: the borrowed buffer outlives the complete or cancelled operation.
        match unsafe { self.perform(|handle, op| ReadFile(handle, Some(into), None, Some(op))) } {
            Err(error) if matches!(error.raw_os_error(), Some(code) if code == ERROR_BROKEN_PIPE.0 as i32 || code == ERROR_PIPE_NOT_CONNECTED.0 as i32) => {
                Ok(0)
            }
            result => result,
        }
    }
}

impl Write for PipeStream {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        if bytes.is_empty() {
            return Ok(0);
        }
        // SAFETY: the borrowed bytes outlive the complete or cancelled operation.
        unsafe { self.perform(|handle, op| WriteFile(handle, Some(bytes), None, Some(op))) }
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

fn wide_pipe_path(path: &Path) -> io::Result<Vec<u16>> {
    if !path.to_str().is_some_and(|name| {
        name.get(..LOCAL_PREFIX.len())
            .is_some_and(|prefix| prefix.eq_ignore_ascii_case(LOCAL_PREFIX))
    }) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "expected a local Windows named pipe",
        ));
    }
    let wide: Vec<_> = path.as_os_str().encode_wide().collect();
    if wide.contains(&0) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "pipe path contains a NUL",
        ));
    }
    Ok(wide.into_iter().chain([0]).collect())
}

fn token_information<T>(token: HANDLE, class: TOKEN_INFORMATION_CLASS) -> io::Result<Vec<usize>> {
    let mut length = 0;
    // SAFETY: a null buffer queries the size; a successful query below validates the result.
    let _ = unsafe { GetTokenInformation(token, class, None, 0, &raw mut length) };
    if (length as usize) < size_of::<T>() {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "Windows token identity is unavailable",
        ));
    }
    let mut storage = vec![0usize; (length as usize).div_ceil(size_of::<usize>())];
    // SAFETY: storage has the required size and pointer alignment for TOKEN_GROUPS.
    unsafe {
        GetTokenInformation(
            token,
            class,
            Some(storage.as_mut_ptr().cast()),
            length,
            &raw mut length,
        )
    }
    .map_err(io_error)?;
    Ok(storage)
}

fn sid_string(source: PSID) -> io::Result<String> {
    if source.0.is_null() {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "Windows returned an empty token SID",
        ));
    }
    let mut sid = PWSTR::null();
    // SAFETY: the SID belongs to the token result above, and sid is a writable output pointer.
    unsafe { ConvertSidToStringSidW(source, &raw mut sid) }.map_err(io_error)?;
    let _memory = LocalAllocation(sid.0.cast());
    // SAFETY: ConvertSidToStringSidW returned a null-terminated string owned above.
    unsafe { sid.to_string() }.map_err(io::Error::other)
}

fn local_descriptor(identity: &Identity) -> io::Result<LocalAllocation> {
    let sddl: Vec<_> = format!(
        "D:P(A;;GA;;;{})S:(ML;;NWNR;;;{})",
        identity.logon, identity.integrity
    )
    .encode_utf16()
    .chain([0])
    .collect();
    let mut descriptor = PSECURITY_DESCRIPTOR::default();
    // SAFETY: the SDDL uses Windows' own logon SID and is UTF-16 terminated. The result is owned.
    unsafe {
        ConvertStringSecurityDescriptorToSecurityDescriptorW(
            PCWSTR(sddl.as_ptr()),
            SDDL_REVISION_1,
            &raw mut descriptor,
            None,
        )
    }
    .map_err(io_error)?;
    Ok(LocalAllocation(descriptor.0))
}

struct LocalAllocation(*mut c_void);

impl Drop for LocalAllocation {
    fn drop(&mut self) {
        // SAFETY: the descriptor and SID APIs allocate local memory and transfer ownership.
        let _ = unsafe { LocalFree(Some(HLOCAL(self.0))) };
    }
}

fn io_error(error: Error) -> io::Error {
    let code = error.code().0 as u32;
    if code & 0xffff_0000 == 0x8007_0000 {
        io::Error::from_raw_os_error((code & 0xffff) as i32)
    } else {
        io::Error::other(error)
    }
}

#[cfg(test)]
#[expect(
    clippy::expect_used,
    reason = "the test reports failures through expectations"
)]
mod tests {
    use super::*;
    use crate::control::{CHUNKS_PER_FRAME, answer, wire::Reply};
    use std::sync::atomic::AtomicU32;

    fn endpoint() -> (Identity, PathBuf) {
        static NEXT: AtomicU32 = AtomicU32::new(0);
        let identity = Identity::current().expect("a Windows logon has an identity");
        let path = PathBuf::from(format!(
            "{LOCAL_PREFIX}lunette-test-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        (identity, path)
    }

    #[test]
    fn local_pipe_evaluates_and_answers_then_accepts_a_second_connection() {
        let (identity, path) = endpoint();
        let (_worker, queue) = start_at(&path, &identity).expect("the control pipe starts");
        assert!(
            start_at(&path, &identity).is_err(),
            "the first instance owns its name"
        );
        let lua = crate::test_lua::session_lua();
        for _ in 0..2 {
            let path = path.clone();
            let client = thread::spawn(move || {
                let mut stream = PipeStream::connect(&path).expect("connect over a local pipe");
                wire::write_request(&mut stream, "return 42").expect("send the request");
                let reply = wire::read_reply(&mut stream).expect("read an answer");
                stream.write_all(&[0]).expect("acknowledge the reply");
                reply
            });
            let deadline = Instant::now() + Duration::from_secs(5);
            while queue.drain(CHUNKS_PER_FRAME, |chunk| answer(&lua, chunk)) == 0 {
                assert!(
                    Instant::now() < deadline,
                    "the request never reached the Lua thread"
                );
                thread::sleep(Duration::from_millis(5));
            }
            assert_eq!(
                client.join().expect("the client finishes"),
                Reply::Returned(vec![wire::Value::Integer(42)])
            );
        }
    }

    #[test]
    fn a_stalled_peer_cannot_prevent_shutdown() {
        let (identity, path) = endpoint();
        let (worker, _queue) = start_at(&path, &identity).expect("the control pipe starts");
        let _client = PipeStream::connect(&path).expect("a client connects");
        let before = Instant::now();
        drop(worker);
        assert!(before.elapsed() < Duration::from_secs(2));
    }

    #[test]
    fn remote_pipe_names_are_rejected_before_opening() {
        let result = PipeStream::connect(Path::new(r"\\remote\pipe\lunette"));
        assert_eq!(
            result
                .expect_err("only local Windows paths are supported")
                .kind(),
            io::ErrorKind::InvalidInput
        );
    }
}
