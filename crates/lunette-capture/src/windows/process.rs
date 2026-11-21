//! Retains native Windows process identities and reads child output without waiting.

use std::{
    io::{self, Read},
    os::windows::{
        io::{AsHandle, AsRawHandle, FromRawHandle, OwnedHandle},
        process::CommandExt,
    },
    process::{Child, Command, Stdio},
};

use ::windows::Win32::{
    Foundation::{ERROR_BROKEN_PIPE, FILETIME, HANDLE, WAIT_OBJECT_0, WAIT_TIMEOUT},
    System::{
        Pipes::PeekNamedPipe,
        Threading::{
            CREATE_NO_WINDOW, GetExitCodeProcess, GetProcessTimes, OpenProcess,
            PROCESS_QUERY_LIMITED_INFORMATION, PROCESS_SYNCHRONIZE, WaitForSingleObject,
        },
    },
};
use lunette_compositor::protocol::{Pid, ProcessInstance};

/// A process instance backed by a handle to the original kernel object.
#[derive(Debug)]
pub struct WindowsProcess {
    handle: OwnedHandle,
    instance: ProcessInstance,
}

impl WindowsProcess {
    /// Opens an existing application with query and wait access.
    ///
    /// # Errors
    ///
    /// Returns an error if the process cannot be inspected.
    pub fn open(pid: u32) -> io::Result<Self> {
        // SAFETY: OpenProcess validates the identifier and returns an owned handle.
        let handle = unsafe {
            OpenProcess(
                PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_SYNCHRONIZE,
                false,
                pid,
            )
            .map_err(io::Error::other)?
        };
        // SAFETY: the successful call above transferred ownership of this handle.
        Self::from_owned(unsafe { OwnedHandle::from_raw_handle(handle.0) }, pid)
    }

    /// Captures a launched child's identity from its already-open process handle.
    ///
    /// # Errors
    ///
    /// Returns an error if the handle cannot be duplicated or inspected.
    pub fn from_child(child: &Child) -> io::Result<Self> {
        Self::from_owned(child.as_handle().try_clone_to_owned()?, child.id())
    }

    fn from_owned(handle: OwnedHandle, pid: u32) -> io::Result<Self> {
        let pid = i32::try_from(pid)
            .ok()
            .and_then(Pid::new)
            .ok_or_else(|| io::Error::other("process identifier is outside the supported range"))?;
        let mut created = FILETIME::default();
        let mut exited = FILETIME::default();
        let mut kernel = FILETIME::default();
        let mut user = FILETIME::default();
        // SAFETY: the handle is live and each output is distinct writable storage.
        unsafe {
            GetProcessTimes(
                HANDLE(handle.as_raw_handle()),
                &raw mut created,
                &raw mut exited,
                &raw mut kernel,
                &raw mut user,
            )
        }
        .map_err(io::Error::other)?;
        let start = u64::from(created.dwHighDateTime) << 32 | u64::from(created.dwLowDateTime);
        Ok(Self {
            handle,
            instance: ProcessInstance::new(pid, start),
        })
    }

    #[must_use]
    pub fn instance(&self) -> ProcessInstance {
        self.instance
    }

    /// Returns the exit status once the process object has signalled.
    ///
    /// # Errors
    ///
    /// Returns a Win32 error if the process cannot be observed.
    pub fn exit_code(&self) -> io::Result<Option<i32>> {
        let handle = HANDLE(self.handle.as_raw_handle());
        // SAFETY: the owned process handle grants synchronize access. A zero timeout never waits.
        match unsafe { WaitForSingleObject(handle, 0) } {
            WAIT_TIMEOUT => Ok(None),
            WAIT_OBJECT_0 => {
                let mut code = 0;
                // SAFETY: the process handle remains open and code is writable.
                unsafe { GetExitCodeProcess(handle, &raw mut code) }.map_err(io::Error::other)?;
                Ok(Some(code as i32))
            }
            _ => Err(io::Error::last_os_error()),
        }
    }
}

/// Pipes output and prevents console executables from opening a shell window.
pub fn configure_child(command: &mut Command) {
    command
        .creation_flags(CREATE_NO_WINDOW.0)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
}

/// Reads only bytes already available from a child's exclusively held read end.
///
/// # Errors
///
/// Returns an I/O error if the pipe cannot be queried or read.
pub fn read_child_pipe(pipe: &mut (impl AsHandle + Read), buffer: &mut [u8]) -> io::Result<usize> {
    let mut available = 0;
    // SAFETY: the caller owns this pipe's only reader and the byte count is writable.
    let result = unsafe {
        PeekNamedPipe(
            HANDLE(pipe.as_handle().as_raw_handle()),
            None,
            0,
            None,
            Some(&raw mut available),
            None,
        )
    };
    if result.is_err() {
        let error = io::Error::last_os_error();
        return if error.raw_os_error() == Some(ERROR_BROKEN_PIPE.0 as i32) {
            Ok(0)
        } else {
            Err(error)
        };
    }
    let length = buffer.len().min(available as usize);
    if length == 0 {
        return Ok(0);
    }
    pipe.read(&mut buffer[..length])
}
