//! Frame-stable audio capture, independent of graphics and XR state.

mod observer;
mod registry;

pub use registry::{
    AudioCaptureId, AudioRegistry, AudioSnapshot, NativeAudioRegistry, NoAudioRegistry,
};
