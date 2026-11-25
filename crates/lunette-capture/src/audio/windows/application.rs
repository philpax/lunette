//! Activates process-tree WASAPI loopback while retaining the original process object.

use std::{
    collections::HashMap,
    mem::{ManuallyDrop, size_of},
    sync::{
        Arc,
        mpsc::{self, Receiver, RecvTimeoutError, SyncSender},
    },
    time::{Duration, Instant},
};

use ::windows::{
    Win32::{
        Foundation::{E_POINTER, ERROR_TIMEOUT},
        Media::Audio::{
            AUDIOCLIENT_ACTIVATION_PARAMS, AUDIOCLIENT_ACTIVATION_PARAMS_0,
            AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK, AUDIOCLIENT_PROCESS_LOOPBACK_PARAMS,
            ActivateAudioInterfaceAsync, IActivateAudioInterfaceAsyncOperation,
            IActivateAudioInterfaceCompletionHandler,
            IActivateAudioInterfaceCompletionHandler_Impl, IAudioClient,
            PROCESS_LOOPBACK_MODE_INCLUDE_TARGET_PROCESS_TREE,
            VIRTUAL_AUDIO_DEVICE_PROCESS_LOOPBACK,
        },
        System::{
            Com::{
                BLOB, IAgileObject, IAgileObject_Impl,
                StructuredStorage::{
                    PROPVARIANT, PROPVARIANT_0, PROPVARIANT_0_0, PROPVARIANT_0_0_0,
                },
            },
            Variant::VT_BLOB,
        },
    },
    core::{Error, HRESULT, Interface, Ref, Result as WindowsResult, implement},
};
use lunette_compositor::protocol::ProcessId;
use parking_lot::Mutex;

use crate::windows::WindowsProcess;

/// Shares the host's registered Windows process instances with audio capture workers.
#[derive(Clone, Debug, Default)]
pub struct WindowsAudioTargets(Arc<Mutex<HashMap<ProcessId, Arc<WindowsProcess>>>>);

impl WindowsAudioTargets {
    pub fn register(&self, id: ProcessId, process: Arc<WindowsProcess>) {
        self.0.lock().insert(id, process);
    }

    pub fn remove(&self, id: ProcessId) {
        self.0.lock().remove(&id);
    }

    pub(super) fn get(&self, id: ProcessId) -> Option<Arc<WindowsProcess>> {
        self.0.lock().get(&id).cloned()
    }
}

#[implement(IActivateAudioInterfaceCompletionHandler, IAgileObject)]
struct Completed {
    sender: SyncSender<()>,
    // Windows retains the callback until activation completes, including after cancellation.
    _parameters: Box<AUDIOCLIENT_ACTIVATION_PARAMS>,
    _target: Arc<WindowsProcess>,
}

impl IAgileObject_Impl for Completed_Impl {}

impl IActivateAudioInterfaceCompletionHandler_Impl for Completed_Impl {
    fn ActivateCompleted(
        &self,
        _activateoperation: Ref<IActivateAudioInterfaceAsyncOperation>,
    ) -> WindowsResult<()> {
        let _ = self.sender.try_send(());
        Ok(())
    }
}

pub(super) fn activate(
    target: &Arc<WindowsProcess>,
    stop: &Receiver<()>,
) -> WindowsResult<Option<IAudioClient>> {
    let mut parameters = Box::new(AUDIOCLIENT_ACTIVATION_PARAMS {
        ActivationType: AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK,
        Anonymous: AUDIOCLIENT_ACTIVATION_PARAMS_0 {
            ProcessLoopbackParams: AUDIOCLIENT_PROCESS_LOOPBACK_PARAMS {
                TargetProcessId: target.instance().pid().get() as u32,
                ProcessLoopbackMode: PROCESS_LOOPBACK_MODE_INCLUDE_TARGET_PROCESS_TREE,
            },
        },
    });
    // The binding's PROPVARIANT destructor clears and frees VT_BLOB storage. This value borrows
    // the activation bytes from the callback and must never free them.
    let input = ManuallyDrop::new(PROPVARIANT {
        Anonymous: PROPVARIANT_0 {
            Anonymous: ManuallyDrop::new(PROPVARIANT_0_0 {
                vt: VT_BLOB,
                Anonymous: PROPVARIANT_0_0_0 {
                    blob: BLOB {
                        cbSize: size_of::<AUDIOCLIENT_ACTIVATION_PARAMS>() as u32,
                        pBlobData: (&raw mut *parameters).cast(),
                    },
                },
                ..PROPVARIANT_0_0::default()
            }),
        },
    });
    let (sender, complete) = mpsc::sync_channel(1);
    let callback: IActivateAudioInterfaceCompletionHandler = Completed {
        sender,
        _parameters: parameters,
        _target: Arc::clone(target),
    }
    .into();
    // SAFETY: the worker owns a COM apartment, the blob points into the retained callback, and the
    // callback is agile and thread-safe. The PROPVARIANT borrows its blob and is never cleared.
    tracing::trace!("requesting WASAPI process activation");
    let operation = unsafe {
        ActivateAudioInterfaceAsync(
            VIRTUAL_AUDIO_DEVICE_PROCESS_LOOPBACK,
            &IAudioClient::IID,
            Some(&raw const *input),
            &callback,
        )
    }?;
    tracing::trace!("Windows accepted the process activation request");

    let deadline = Instant::now() + Duration::from_secs(4);
    loop {
        if stop.recv_timeout(Duration::ZERO) != Err(RecvTimeoutError::Timeout) {
            return Ok(None);
        }
        if complete.recv_timeout(Duration::from_millis(16)).is_ok() {
            break;
        }
        if Instant::now() >= deadline {
            return Err(Error::from_hresult(HRESULT::from_win32(ERROR_TIMEOUT.0)));
        }
    }
    let mut status = HRESULT(0);
    let mut audio = None;
    tracing::trace!("WASAPI process activation completed");
    // SAFETY: the callback signalled completion, operation belongs to this apartment, and its results
    // are written into initialized caller storage.
    unsafe { operation.GetActivateResult(&raw mut status, &raw mut audio) }?;
    status.ok()?;
    audio
        .ok_or_else(|| Error::from_hresult(E_POINTER))?
        .cast()
        .map(Some)
}
