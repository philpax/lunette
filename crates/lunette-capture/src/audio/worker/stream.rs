//! Linux-only: owned PipeWire monitor stream and allocation-free PCM callback.

use std::{
    io::Cursor,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
};

use lunette_compositor::protocol::PipeWireGeneration;
use pipewire::{self as pw, properties::properties, spa};
use spa::{
    param::audio::AudioInfoRaw,
    pod::{Pod, serialize::PodSerializer},
};

use crate::audio::{
    AudioBackendEvent, AudioConsumer, AudioFormat, AudioProducer, CaptureId, GraphObjectState,
    NodeIdentity, PcmPacket, UnavailableReason, audio_transport, worker::PipeWireAudioConfig,
};

pub(super) struct Monitor {
    consumer: Option<AudioConsumer>,
    _listener: pw::stream::StreamListener<CallbackData>,
    _stream: pw::stream::StreamRc,
    epoch: PipeWireGeneration,
    failed: Arc<AtomicBool>,
    streaming: Arc<AtomicBool>,
    negotiated: Arc<AtomicBool>,
    valid: Arc<AtomicBool>,
}

impl Monitor {
    pub(super) fn state(&self) -> GraphObjectState {
        if self.failed.load(Ordering::Relaxed) {
            return GraphObjectState::Unavailable {
                reason: UnavailableReason::GraphFailure,
                detail: "monitor stream disconnected or entered an error state".into(),
            };
        }
        if self.negotiated.load(Ordering::Relaxed) && !self.valid.load(Ordering::Relaxed) {
            return GraphObjectState::Unavailable {
                reason: UnavailableReason::UnsupportedFormat,
                detail: "monitor format is not stereo F32LE at 48000 Hz".into(),
            };
        }
        if self.streaming.load(Ordering::Relaxed) && self.valid.load(Ordering::Relaxed) {
            GraphObjectState::Streaming
        } else {
            GraphObjectState::Starting
        }
    }
    pub(super) fn take_transport(&mut self, capture: CaptureId) -> Option<AudioBackendEvent> {
        if self.state() != GraphObjectState::Streaming {
            return None;
        }
        self.consumer
            .take()
            .map(|consumer| AudioBackendEvent::Transport {
                capture,
                generation: self.epoch,
                consumer,
            })
    }
    pub(super) fn new(
        core: &pw::core::CoreRc,
        target: NodeIdentity,
        config: &PipeWireAudioConfig,
        epoch: PipeWireGeneration,
    ) -> Result<Self, String> {
        let (producer, consumer) = audio_transport(epoch);
        let stream = pw::stream::StreamRc::new(core.clone(), "lunette audio monitor", properties! {
            "media.type" => "Audio", "media.category" => "Capture", "media.role" => "Music",
            "media.class" => "Stream/Input/Audio", "stream.capture.sink" => "true", "node.dont-fallback" => "true",
            "node.dont-reconnect" => "true", "target.object" => target.serial.0.to_string(),
            "node.name" => format!("{}.monitor.{}", config.owner_tag, epoch.0), "lunette.audio.owner" => config.owner_tag.as_str()
        }).map_err(|error| error.to_string())?;
        let failed = Arc::new(AtomicBool::new(false));
        let streaming = Arc::new(AtomicBool::new(false));
        let negotiated = Arc::new(AtomicBool::new(false));
        let valid = Arc::new(AtomicBool::new(false));
        let listener = stream
            .add_local_listener_with_user_data(CallbackData {
                producer,
                format: None,
                failed: failed.clone(),
                streaming: streaming.clone(),
                negotiated: negotiated.clone(),
                valid: valid.clone(),
            })
            .state_changed(|_, data, _, state| {
                data.failed.store(
                    matches!(
                        state,
                        pw::stream::StreamState::Error(_) | pw::stream::StreamState::Unconnected
                    ),
                    Ordering::Relaxed,
                );
                data.streaming.store(
                    matches!(state, pw::stream::StreamState::Streaming),
                    Ordering::Relaxed,
                );
            })
            .param_changed(|_, data, id, param| {
                if id != spa::param::ParamType::Format.as_raw() {
                    return;
                }
                data.format = None;
                let mut info = AudioInfoRaw::new();
                if let Some(param) = param
                    && info.parse(param).is_ok()
                    && info.format() == spa::param::audio::AudioFormat::F32LE
                    && info.position()[..2]
                        == [
                            spa::sys::SPA_AUDIO_CHANNEL_FL,
                            spa::sys::SPA_AUDIO_CHANNEL_FR,
                        ]
                {
                    data.format = u8::try_from(info.channels())
                        .ok()
                        .and_then(|channels| AudioFormat::negotiate(info.rate(), channels));
                }
                data.valid.store(data.format.is_some(), Ordering::Relaxed);
                data.negotiated.store(param.is_some(), Ordering::Relaxed);
            })
            .process(|stream, data| {
                let Some(mut buffer) = stream.dequeue_buffer() else {
                    return;
                };
                let planes = buffer.datas_mut();
                if planes.len() != 1 {
                    let _ = data.producer.push(PcmPacket {
                        bytes: &[],
                        offset: 0,
                        size: 0,
                        stride: 0,
                        format: None,
                    });
                    return;
                }
                let plane = &mut planes[0];
                let offset = plane.chunk().offset() as usize;
                let size = plane.chunk().size() as usize;
                let stride = plane.chunk().stride();
                let bytes = plane.data().map(|bytes| &bytes[..]).unwrap_or(&[]);
                if data.producer.push(PcmPacket {
                    bytes,
                    offset,
                    size,
                    stride,
                    format: data.format,
                }) == crate::audio::PacketResult::IdentifierExhausted
                {
                    data.failed.store(true, Ordering::Relaxed);
                }
            })
            .register()
            .map_err(|error| error.to_string())?;
        let mut info = AudioInfoRaw::new();
        info.set_format(spa::param::audio::AudioFormat::F32LE);
        info.set_rate(48_000);
        info.set_channels(2);
        let mut positions = [0; 64];
        positions[0] = spa::sys::SPA_AUDIO_CHANNEL_FL;
        positions[1] = spa::sys::SPA_AUDIO_CHANNEL_FR;
        info.set_position(positions);
        let object = spa::pod::Object {
            type_: spa::utils::SpaTypes::ObjectParamFormat.as_raw(),
            id: spa::param::ParamType::EnumFormat.as_raw(),
            properties: info.into(),
        };
        let values =
            PodSerializer::serialize(Cursor::new(Vec::new()), &spa::pod::Value::Object(object))
                .map_err(|error| format!("format serialization: {error:?}"))?
                .0
                .into_inner();
        let pod = Pod::from_bytes(&values).ok_or("invalid serialized format")?;
        stream
            .connect(
                spa::utils::Direction::Input,
                None,
                pw::stream::StreamFlags::AUTOCONNECT
                    | pw::stream::StreamFlags::MAP_BUFFERS
                    | pw::stream::StreamFlags::DONT_RECONNECT,
                &mut [pod],
            )
            .map_err(|error| error.to_string())?;
        Ok(Self {
            consumer: Some(consumer),
            _listener: listener,
            _stream: stream,
            epoch,
            failed,
            streaming,
            negotiated,
            valid,
        })
    }
}
struct CallbackData {
    producer: AudioProducer,
    format: Option<AudioFormat>,
    failed: Arc<AtomicBool>,
    streaming: Arc<AtomicBool>,
    negotiated: Arc<AtomicBool>,
    valid: Arc<AtomicBool>,
}
