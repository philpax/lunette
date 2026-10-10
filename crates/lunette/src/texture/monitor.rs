//! Which mirrored monitor holds which texture, and which image is behind it.
//!
//! The image is recorded because [`DmabufImporter`] returns the same image for
//! a recurring PipeWire buffer, and wrapping it again would allocate a fresh
//! texture over the same memory.
//!
//! [`DmabufImporter`]: crate::import::dmabuf::DmabufImporter

use std::collections::HashMap;

use lunette_capture::{monitor::MonitorKey, stream::FrameTransform};
use lunette_compositor::protocol::ImageHandle;

use crate::texture::TextureDescription;

/// Which monitor holds which texture, and which image is behind it.
#[derive(Debug)]
pub struct MonitorTextures<T> {
    entries: HashMap<MonitorKey, Entry<T>>,
}

impl<T> Default for MonitorTextures<T> {
    fn default() -> Self {
        Self {
            entries: HashMap::new(),
        }
    }
}

impl<T> MonitorTextures<T> {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Which image this monitor's texture wraps, if it holds one.
    ///
    /// An image named here must not be retired, and [`CaptureImporter::import`]
    /// does not evict it.
    ///
    /// [`CaptureImporter::import`]: crate::import::CaptureImporter::import
    #[must_use]
    pub fn image(&self, monitor: &MonitorKey) -> Option<ImageHandle> {
        self.entries.get(monitor).and_then(|entry| entry.image)
    }

    /// Records a monitor's new texture and the transform of the frame it shows,
    /// returning the texture it displaces.
    ///
    /// The image is `None` for a texture uploaded from shared memory. The
    /// caller releases what comes back, because destroying a LÖVR texture is an
    /// FFI call this type cannot make.
    pub fn install(
        &mut self,
        monitor: MonitorKey,
        image: Option<ImageHandle>,
        texture: T,
        description: TextureDescription,
        transform: FrameTransform,
    ) -> Option<T> {
        self.entries
            .insert(
                monitor,
                Entry {
                    texture,
                    image,
                    description,
                    transform,
                },
            )
            .map(|displaced| displaced.texture)
    }

    /// The texture a monitor's mirror last produced.
    ///
    /// No frame generation is checked, because the one caller consumes the
    /// answer inside a single Lua call.
    #[must_use]
    pub fn texture(&self, monitor: &MonitorKey) -> Option<&T> {
        self.entries.get(monitor).map(|entry| &entry.texture)
    }

    /// What a monitor's texture is, for a caller that needs the size without
    /// the texture.
    #[must_use]
    pub fn describe(&self, monitor: &MonitorKey) -> Option<TextureDescription> {
        self.entries.get(monitor).map(|entry| entry.description)
    }

    /// The transform of the currently presented capture, including identity
    /// Undefined.
    #[must_use]
    pub fn frame_transform(&self, monitor: &MonitorKey) -> Option<FrameTransform> {
        self.entries.get(monitor).map(|entry| entry.transform)
    }

    /// Updates capture metadata when a buffer or uploaded texture is reused.
    pub fn refresh_frame(&mut self, monitor: &MonitorKey, transform: FrameTransform) {
        if let Some(entry) = self.entries.get_mut(monitor) {
            entry.transform = transform;
        }
    }

    /// Drops what is held for a monitor, returning its texture.
    ///
    /// A texture nothing will refresh is a still picture that looks live, which
    /// is worse than no picture.
    pub fn forget(&mut self, monitor: &MonitorKey) -> Option<T> {
        self.entries.remove(monitor).map(|entry| entry.texture)
    }

    /// Which monitors hold a texture.
    ///
    /// Cloned, not borrowed, because the caller queries the mirror lifecycle,
    /// reachable from the same session, about each in turn.
    #[must_use]
    pub fn monitors(&self) -> Vec<MonitorKey> {
        self.entries.keys().cloned().collect()
    }

    /// Every texture a mirrored monitor currently holds.
    ///
    /// The frame loop records the import barriers over these, because an
    /// imported image needs an acquire before the frame samples it.
    pub fn textures(&self) -> impl Iterator<Item = &T> {
        self.entries.values().map(|entry| &entry.texture)
    }

    /// Empties the ledger, returning every texture it held. For teardown.
    #[must_use]
    pub fn take_all(&mut self) -> Vec<T> {
        self.entries
            .drain()
            .map(|(_, entry)| entry.texture)
            .collect()
    }
}

#[derive(Debug)]
struct Entry<T> {
    texture: T,
    /// Which image the texture wraps, so a recurring PipeWire buffer is not
    /// re-wrapped.
    image: Option<ImageHandle>,
    description: TextureDescription,
    transform: FrameTransform,
}

#[cfg(test)]
#[expect(
    clippy::expect_used,
    reason = "a failed expectation is how a test reports a failure; the ban is on production code"
)]
mod tests {
    use lunette_capture::monitor::{ConnectorKind, ConnectorName};
    use lunette_compositor::protocol::PixelSize;
    use pretty_assertions::assert_eq;

    use super::*;
    use crate::import::formats::Alpha;

    fn monitor(index: u32) -> MonitorKey {
        MonitorKey::Connector(ConnectorName::new(ConnectorKind::DisplayPort, index))
    }

    fn image(raw: u64) -> ImageHandle {
        ImageHandle::new(raw).expect("a non-zero image handle")
    }

    fn description() -> TextureDescription {
        TextureDescription {
            size: PixelSize::new(1920, 1080),
            alpha: Alpha::Opaque,
        }
    }

    #[test]
    fn capture_transform_refreshes_reused_and_refilled_textures() {
        for imported in [false, true] {
            let mut textures = MonitorTextures::new();
            textures.install(
                monitor(1),
                imported.then(|| image(7)),
                10_u32,
                description(),
                FrameTransform::Undefined,
            );
            for transform in [
                FrameTransform::Undefined,
                FrameTransform::Normal,
                FrameTransform::Rotated90,
                FrameTransform::Rotated180,
                FrameTransform::Rotated270,
                FrameTransform::Flipped,
                FrameTransform::Flipped90,
                FrameTransform::Flipped180,
                FrameTransform::Flipped270,
            ] {
                textures.refresh_frame(&monitor(1), transform);
                assert_eq!(textures.frame_transform(&monitor(1)), Some(transform));
                assert_eq!(textures.texture(&monitor(1)), Some(&10));
                assert_eq!(textures.image(&monitor(1)), imported.then(|| image(7)));
            }
            textures.forget(&monitor(1));
            assert_eq!(textures.frame_transform(&monitor(1)), None);
        }
    }

    #[test]
    fn installing_over_a_monitor_hands_back_the_texture_it_displaced() {
        let mut textures = MonitorTextures::new();
        textures.install(
            monitor(1),
            Some(image(1)),
            10_u32,
            description(),
            FrameTransform::Undefined,
        );

        let displaced = textures.install(
            monitor(1),
            Some(image(2)),
            11_u32,
            description(),
            FrameTransform::Undefined,
        );

        assert_eq!(displaced, Some(10));
        assert_eq!(textures.texture(&monitor(1)), Some(&11));
    }

    #[test]
    fn forgetting_a_monitor_hands_its_texture_back_and_stops_naming_it() {
        // A texture left behind by a dismissed mirror would be a still picture
        // that looks live.
        let mut textures = MonitorTextures::new();
        textures.install(
            monitor(1),
            Some(image(1)),
            10_u32,
            description(),
            FrameTransform::Undefined,
        );

        assert_eq!(textures.forget(&monitor(1)), Some(10));
        assert_eq!(textures.texture(&monitor(1)), None);
        assert_eq!(
            textures.textures().count(),
            0,
            "a texture already handed back must not be named in a barrier"
        );
    }

    #[test]
    fn teardown_hands_back_every_texture_once() {
        let mut textures = MonitorTextures::new();
        textures.install(
            monitor(1),
            Some(image(1)),
            10_u32,
            description(),
            FrameTransform::Undefined,
        );
        textures.install(
            monitor(2),
            Some(image(2)),
            20_u32,
            description(),
            FrameTransform::Undefined,
        );

        let mut taken = textures.take_all();
        taken.sort_unstable();

        assert_eq!(taken, vec![10, 20]);
        assert!(textures.take_all().is_empty());
        assert_eq!(textures.texture(&monitor(1)), None);
    }
}
