//! Captures the Windows default render endpoint through WASAPI loopback.

mod application;

use std::{
    collections::HashMap,
    mem::size_of,
    os::windows::io::{AsRawHandle, FromRawHandle, OwnedHandle},
    ptr, slice,
    sync::{
        Arc,
        mpsc::{self, Receiver, RecvTimeoutError, Sender, SyncSender},
    },
    thread::{self, JoinHandle},
    time::{Duration, Instant},
};

use ::windows::{
    Win32::{
        Foundation::{E_ACCESSDENIED, E_POINTER, E_UNEXPECTED, HANDLE, WAIT_FAILED},
        Media::{
            Audio::{
                AUDCLNT_BUFFERFLAGS_DATA_DISCONTINUITY, AUDCLNT_BUFFERFLAGS_SILENT,
                AUDCLNT_BUFFERFLAGS_TIMESTAMP_ERROR, AUDCLNT_E_SERVICE_NOT_RUNNING,
                AUDCLNT_E_UNSUPPORTED_FORMAT, AUDCLNT_SHAREMODE_SHARED,
                AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM, AUDCLNT_STREAMFLAGS_EVENTCALLBACK,
                AUDCLNT_STREAMFLAGS_LOOPBACK, AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY,
                IAudioCaptureClient, IAudioClient, IMMDevice, IMMDeviceEnumerator,
                MMDeviceEnumerator, WAVEFORMATEX, eMultimedia, eRender,
            },
            Multimedia::WAVE_FORMAT_IEEE_FLOAT,
        },
        System::{
            Com::{
                CLSCTX_ALL, COINIT_MULTITHREADED, CoCreateInstance, CoInitializeEx, CoTaskMemFree,
                CoUninitialize,
            },
            Threading::{CreateEventW, WaitForSingleObject},
        },
    },
    core::{Error, Result as WindowsResult},
};
use lunette_compositor::protocol::{
    AudioAttributionReply, AudioAttributionRequest, PipeWireGeneration, ProcessId,
    ProcessObservation,
};

use crate::windows::WindowsProcess;
pub use application::WindowsAudioTargets;

use super::{
    AudioBackend, AudioBackendEvent, AudioError, AudioFormat, AudioProcessCandidate, AudioProducer,
    CaptureId, CaptureState, PacketResult, PcmPacket, ProcessCaptureStatus, Source,
    UnavailableReason, audio_transport, transport::TRANSPORT_FRAMES,
};

const FORMAT: AudioFormat = AudioFormat::STEREO_F32_48K;
const FRAME_BYTES: usize = FORMAT.channels() as usize * size_of::<f32>();
const PACKET_POLL: Duration = Duration::from_millis(8);
const ENDPOINT_POLL: Duration = Duration::from_secs(1);
static SILENCE: [u8; TRANSPORT_FRAMES * FRAME_BYTES] = [0; TRANSPORT_FRAMES * FRAME_BYTES];

pub struct WasapiAudioBackend {
    events: Receiver<AudioBackendEvent>,
    publish: Sender<AudioBackendEvent>,
    targets: WindowsAudioTargets,
    workers: HashMap<CaptureId, Worker>,
    retiring: Vec<JoinHandle<()>>,
}

struct Worker {
    stop: SyncSender<()>,
    thread: JoinHandle<()>,
}

impl WasapiAudioBackend {
    #[must_use]
    pub fn new(targets: WindowsAudioTargets) -> Self {
        let (publish, events) = mpsc::channel();
        Self {
            events,
            publish,
            targets,
            workers: HashMap::new(),
            retiring: Vec::new(),
        }
    }
}

impl Default for WasapiAudioBackend {
    fn default() -> Self {
        Self::new(WindowsAudioTargets::default())
    }
}

impl Drop for WasapiAudioBackend {
    fn drop(&mut self) {
        self.shutdown();
    }
}

impl AudioBackend for WasapiAudioBackend {
    fn start(&mut self, capture: CaptureId, source: Source) -> Result<(), AudioError> {
        if self.workers.contains_key(&capture) {
            return Err(AudioError::CapacityExceeded);
        }
        let process = match source {
            Source::System => None,
            Source::Process(process) => {
                let Some(target) = self.targets.get(process) else {
                    return self
                        .publish
                        .send(AudioBackendEvent::State {
                            capture,
                            generation: PipeWireGeneration(0),
                            state: CaptureState::Unavailable {
                                reason: UnavailableReason::UnresolvedAttribution,
                                detail: "the Windows process is unavailable for audio capture"
                                    .into(),
                            },
                        })
                        .map_err(|_| AudioError::WorkerStopped);
                };
                Some(target)
            }
        };
        let (stop, stopping) = mpsc::sync_channel(0);
        let publish = self.publish.clone();
        let thread = thread::Builder::new()
            .name("lunette-wasapi".into())
            .spawn(move || capture_output(capture, process, &publish, &stopping))
            .map_err(|error| AudioError::WorkerStart(error.to_string()))?;
        self.workers.insert(capture, Worker { stop, thread });
        Ok(())
    }

    fn stop(&mut self, capture: CaptureId) {
        if let Some(worker) = self.workers.remove(&capture) {
            drop(worker.stop);
            self.retiring.push(worker.thread);
        }
    }

    fn poll(&mut self) -> Vec<AudioBackendEvent> {
        let mut index = 0;
        while index < self.retiring.len() {
            if self.retiring[index].is_finished() {
                let _ = self.retiring.swap_remove(index).join();
            } else {
                index += 1;
            }
        }
        self.events.try_iter().collect()
    }

    fn take_process_candidates(&mut self) -> Vec<AudioProcessCandidate> {
        Vec::new()
    }

    fn observe_process(
        &mut self,
        _candidate: AudioProcessCandidate,
        _observation: ProcessObservation,
    ) -> Result<(), AudioError> {
        Ok(())
    }

    fn take_attribution_requests(&mut self) -> Vec<AudioAttributionRequest> {
        Vec::new()
    }

    fn attribution_reply(&mut self, _reply: AudioAttributionReply) -> Result<(), AudioError> {
        Ok(())
    }

    fn set_process_status(
        &mut self,
        _process: ProcessId,
        _status: ProcessCaptureStatus,
    ) -> Result<(), AudioError> {
        Ok(())
    }

    fn shutdown(&mut self) {
        for (_, worker) in self.workers.drain() {
            drop(worker.stop);
            self.retiring.push(worker.thread);
        }
        for thread in self.retiring.drain(..) {
            let _ = thread.join();
        }
    }
}

fn capture_output(
    capture: CaptureId,
    process: Option<Arc<WindowsProcess>>,
    events: &Sender<AudioBackendEvent>,
    stop: &Receiver<()>,
) {
    let state = |generation, state| {
        events
            .send(AudioBackendEvent::State {
                capture,
                generation,
                state,
            })
            .is_ok()
    };
    let mut generation = PipeWireGeneration(0);
    let _apartment = match Apartment::enter() {
        Ok(apartment) => apartment,
        Err(error) => {
            state(
                generation,
                unavailable(UnavailableReason::NoServer, "Initialize COM", &error),
            );
            return;
        }
    };
    let target = if let Some(process) = process {
        Target::Application(process)
    } else {
        // SAFETY: this capture worker owns the active COM apartment.
        match unsafe { CoCreateInstance(&MMDeviceEnumerator, None, CLSCTX_ALL) } {
            Ok(devices) => Target::System(devices),
            Err(error) => {
                state(
                    generation,
                    unavailable(UnavailableReason::NoServer, "Open Windows Audio", &error),
                );
                return;
            }
        }
    };

    let mut last_failure = None;
    while stop.recv_timeout(Duration::ZERO) == Err(RecvTimeoutError::Timeout) {
        if target.ended() {
            state(generation, CaptureState::Ended);
            return;
        }
        let outcome = match target.open(stop) {
            Ok(Some(mut stream)) => {
                let Some(next) = generation.0.checked_add(1) else {
                    state(generation, CaptureState::Ended);
                    return;
                };
                generation = PipeWireGeneration(next);
                last_failure = None;
                let (mut producer, consumer) = audio_transport(generation);
                if events
                    .send(AudioBackendEvent::Transport {
                        capture,
                        generation,
                        consumer,
                    })
                    .is_err()
                    || !state(generation, CaptureState::Active { provenance: None })
                {
                    return;
                }
                stream.capture(&target, stop, &mut producer)
            }
            Ok(None) => return,
            Err(failure) => Err(failure),
        };
        match outcome {
            Ok(StreamExit::Stopped) => return,
            Ok(StreamExit::ProcessEnded) => {
                state(generation, CaptureState::Ended);
                return;
            }
            Ok(StreamExit::EndpointChanged) => {
                if !state(generation, CaptureState::Starting) {
                    return;
                }
            }
            Err(failure) => {
                if last_failure.as_ref() != Some(&failure) && !state(generation, failure.clone()) {
                    return;
                }
                last_failure = Some(failure);
                if stop.recv_timeout(ENDPOINT_POLL) != Err(RecvTimeoutError::Timeout) {
                    return;
                }
            }
        }
    }
}

enum Target {
    System(IMMDeviceEnumerator),
    Application(Arc<WindowsProcess>),
}

impl Target {
    fn open(&self, stop: &Receiver<()>) -> Result<Option<Loopback>, CaptureState> {
        match self {
            Self::System(devices) => {
                let device = default_endpoint(devices).map_err(|error| {
                    unavailable(
                        UnavailableReason::NoDefaultSink,
                        "Find the default Windows output",
                        &error,
                    )
                })?;
                Loopback::from_endpoint(&device).map(Some).map_err(|error| {
                    unavailable(
                        UnavailableReason::GraphFailure,
                        "Start WASAPI loopback",
                        &error,
                    )
                })
            }
            Self::Application(process) => {
                let open = || -> WindowsResult<Option<Loopback>> {
                    let Some(client) = application::activate(process, stop)? else {
                        return Ok(None);
                    };
                    Loopback::from_client(client, None).map(Some)
                };
                open().map_err(|error| {
                    unavailable(
                        UnavailableReason::GraphFailure,
                        "Start application audio",
                        &error,
                    )
                })
            }
        }
    }

    fn ended(&self) -> bool {
        match self {
            Self::System(_) => false,
            Self::Application(process) => process.exit_code().is_ok_and(|code| code.is_some()),
        }
    }
}

fn unavailable(fallback: UnavailableReason, operation: &str, error: &Error) -> CaptureState {
    let reason = match error.code() {
        AUDCLNT_E_SERVICE_NOT_RUNNING => UnavailableReason::NoServer,
        AUDCLNT_E_UNSUPPORTED_FORMAT => UnavailableReason::UnsupportedFormat,
        E_ACCESSDENIED => UnavailableReason::PermissionDenied,
        _ => fallback,
    };
    CaptureState::Unavailable {
        reason,
        detail: format!("{operation}: {error}"),
    }
}

struct Apartment;

impl Apartment {
    fn enter() -> WindowsResult<Self> {
        // SAFETY: initializes COM only on this dedicated worker thread.
        unsafe { CoInitializeEx(None, COINIT_MULTITHREADED) }.ok()?;
        Ok(Self)
    }
}

impl Drop for Apartment {
    fn drop(&mut self) {
        // SAFETY: one matching call on the thread that initialized this apartment.
        unsafe { CoUninitialize() };
    }
}

fn default_endpoint(devices: &IMMDeviceEnumerator) -> WindowsResult<IMMDevice> {
    // SAFETY: the enumerator belongs to the capture worker's live apartment.
    unsafe { devices.GetDefaultAudioEndpoint(eRender, eMultimedia) }
}

fn endpoint_id(device: &IMMDevice) -> WindowsResult<Vec<u16>> {
    // SAFETY: GetId returns a caller-owned, null-terminated COM allocation.
    let id = unsafe { device.GetId() }?;
    if id.is_null() {
        return Err(Error::from_hresult(E_POINTER));
    }
    // SAFETY: the allocation remains valid until the matching CoTaskMemFree.
    unsafe {
        let name = id.as_wide().to_vec();
        CoTaskMemFree(Some(id.0.cast()));
        Ok(name)
    }
}

enum StreamExit {
    Stopped,
    EndpointChanged,
    ProcessEnded,
}

struct Loopback {
    client: IAudioClient,
    packets: IAudioCaptureClient,
    endpoint: Option<Vec<u16>>,
    maximum_frames: u32,
    previous_end: Option<u64>,
    event: Option<OwnedHandle>,
}

impl Loopback {
    fn from_endpoint(device: &IMMDevice) -> WindowsResult<Self> {
        let endpoint = endpoint_id(device)?;
        // SAFETY: this device belongs to the active worker COM apartment.
        let client: IAudioClient = unsafe { device.Activate(CLSCTX_ALL, None) }?;
        Self::from_client(client, Some(endpoint))
    }

    fn from_client(client: IAudioClient, endpoint: Option<Vec<u16>>) -> WindowsResult<Self> {
        let format = WAVEFORMATEX {
            wFormatTag: WAVE_FORMAT_IEEE_FLOAT as u16,
            nChannels: u16::from(FORMAT.channels()),
            nSamplesPerSec: FORMAT.sample_rate(),
            nAvgBytesPerSec: FORMAT.sample_rate() * FRAME_BYTES as u32,
            nBlockAlign: FRAME_BYTES as u16,
            wBitsPerSample: (size_of::<f32>() * 8) as u16,
            cbSize: 0,
        };
        let event = if endpoint.is_none() {
            // SAFETY: creates a private, unnamed auto-reset event with a transferred handle.
            let handle = unsafe { CreateEventW(None, false, false, None) }?;
            // SAFETY: the event API above transferred ownership.
            Some(unsafe { OwnedHandle::from_raw_handle(handle.0) })
        } else {
            None
        };
        let flags = AUDCLNT_STREAMFLAGS_LOOPBACK
            | AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM
            | if event.is_some() {
                AUDCLNT_STREAMFLAGS_EVENTCALLBACK
            } else {
                AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY
            };
        tracing::trace!(
            application = event.is_some(),
            "initializing a WASAPI client"
        );
        // SAFETY: the interfaces stay on the active worker apartment. WASAPI copies the format on Initialize.
        unsafe {
            client.Initialize(
                AUDCLNT_SHAREMODE_SHARED,
                flags,
                if endpoint.is_some() { 1_000_000 } else { 0 },
                0,
                &raw const format,
                None,
            )?;
            let maximum_frames = client.GetBufferSize()?;
            let packets = client.GetService()?;
            if let Some(event) = &event {
                client.SetEventHandle(HANDLE(event.as_raw_handle()))?;
            }
            client.Start()?;
            tracing::trace!(application = event.is_some(), "started a WASAPI client");
            Ok(Self {
                client,
                packets,
                endpoint,
                maximum_frames,
                previous_end: None,
                event,
            })
        }
    }

    fn capture(
        &mut self,
        target: &Target,
        stop: &Receiver<()>,
        producer: &mut AudioProducer,
    ) -> Result<StreamExit, CaptureState> {
        let mut endpoint_check = Instant::now() + ENDPOINT_POLL;
        loop {
            for _ in 0..64 {
                match self.read(producer) {
                    Ok(true) => {}
                    Ok(false) => break,
                    Err(error) => {
                        return Err(unavailable(
                            UnavailableReason::GraphFailure,
                            "Read Windows output",
                            &error,
                        ));
                    }
                }
            }
            let wait = if let Some(event) = &self.event {
                // SAFETY: the stream owns the event throughout this bounded, non-alertable wait.
                if unsafe {
                    WaitForSingleObject(
                        HANDLE(event.as_raw_handle()),
                        PACKET_POLL.as_millis() as u32,
                    )
                } == WAIT_FAILED
                {
                    return Err(unavailable(
                        UnavailableReason::GraphFailure,
                        "Wait for application audio",
                        &Error::from_thread(),
                    ));
                }
                Duration::ZERO
            } else {
                PACKET_POLL
            };
            if stop.recv_timeout(wait) != Err(RecvTimeoutError::Timeout) {
                return Ok(StreamExit::Stopped);
            }
            if target.ended() {
                return Ok(StreamExit::ProcessEnded);
            }
            let now = Instant::now();
            if now >= endpoint_check
                && let Target::System(devices) = target
            {
                let latest = default_endpoint(devices).and_then(|device| endpoint_id(&device));
                if latest.ok() != self.endpoint || self.endpoint.is_none() {
                    return Ok(StreamExit::EndpointChanged);
                }
                endpoint_check = now + ENDPOINT_POLL;
            }
        }
    }

    fn read(&mut self, producer: &mut AudioProducer) -> WindowsResult<bool> {
        // SAFETY: no unreleased buffer exists, and only this thread reads this capture client.
        if unsafe { self.packets.GetNextPacketSize() }? == 0 {
            return Ok(false);
        }
        let mut data = ptr::null_mut();
        let (mut frames, mut flags, mut position) = (0, 0, 0);
        // SAFETY: WASAPI writes only the provided output fields. The buffer remains valid through ReleaseBuffer.
        unsafe {
            self.packets.GetBuffer(
                &raw mut data,
                &raw mut frames,
                &raw mut flags,
                Some(&raw mut position),
                None,
            )?
        };
        if frames == 0 {
            return Ok(false);
        }

        let timestamp_valid = flags & AUDCLNT_BUFFERFLAGS_TIMESTAMP_ERROR.0 as u32 == 0;
        let jumped = self
            .previous_end
            .filter(|_| timestamp_valid)
            .map_or(0, |end| position.saturating_sub(end));
        if jumped > 0
            || self.previous_end.is_some()
                && flags & AUDCLNT_BUFFERFLAGS_DATA_DISCONTINUITY.0 as u32 != 0
        {
            producer.discontinuity(jumped);
        }
        self.previous_end = timestamp_valid.then(|| position.saturating_add(u64::from(frames)));

        let consumed = if frames > self.maximum_frames || frames as usize > TRANSPORT_FRAMES {
            None
        } else {
            let length = frames as usize * FRAME_BYTES;
            if flags & AUDCLNT_BUFFERFLAGS_SILENT.0 as u32 != 0 {
                Some(&SILENCE[..length])
            } else if data.is_null() {
                None
            } else {
                // SAFETY: this packet is still acquired and validated against the stream buffer size.
                Some(unsafe { slice::from_raw_parts(data, length) })
            }
        };
        let terminal = if let Some(bytes) = consumed {
            producer.push(PcmPacket {
                bytes,
                offset: 0,
                size: bytes.len(),
                stride: FRAME_BYTES as i32,
                format: Some(FORMAT),
            }) == PacketResult::IdentifierExhausted
        } else {
            producer.discontinuity(u64::from(frames));
            false
        };
        // SAFETY: releases the exact number of frames acquired above, including silent or invalid packets.
        unsafe { self.packets.ReleaseBuffer(frames) }?;
        if terminal {
            return Err(Error::new(
                E_UNEXPECTED,
                "WASAPI audio timing counters exhausted",
            ));
        }
        Ok(true)
    }
}

impl Drop for Loopback {
    fn drop(&mut self) {
        // SAFETY: the worker still owns a started audio client and its COM apartment.
        let _ = unsafe { self.client.Stop() };
    }
}
