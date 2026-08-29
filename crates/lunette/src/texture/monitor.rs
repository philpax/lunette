//! Which mirrored monitor holds which texture.
//!
//! The counterpart to [`TextureLedger`](crate::texture::TextureLedger), a
//! separate type keyed by monitor. A surface's ledger carries a death flag, a
//! damage flag, a stabilised copy, and a morgue, because a Wayland client can
//! exit mid-frame and a configuration can keep a copy that outlives the
//! frame. A monitor has none of those: it is the user's own screen, it does
//! not exit, and its texture rotates solely when PipeWire cycles the small
//! buffer pool it negotiated.
//!
//! A monitor needs one thing a surface does not: the image behind the texture.
//! [`DmabufImporter`] caches on the buffer it receives and returns the image
//! it already made for a recurring PipeWire buffer. Without a record of which
//! image is installed, every frame from that buffer allocates a fresh LOVR
//! texture over the same memory. [`MonitorTextures::image`] is that record;
//! the second and later frames from the same buffer reuse the image.
//!
//! Generic over the texture for the reason the surface ledger is: the
//! bookkeeping needs no graphics device, so the tests substitute an integer.
//!
//! [`DmabufImporter`]: crate::import::dmabuf::DmabufImporter

use std::collections::HashMap;

use lunette_capture::monitor::MonitorKey;
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
    /// An image named here must not be retired: [`CaptureImporter::import`] does
    /// not evict it. The frame loop compares the value against the image the
    /// last import returned before wrapping, because wrapping the same image
    /// again allocates a texture over memory a texture already covers.
    ///
    /// [`CaptureImporter::import`]: crate::import::CaptureImporter::import
    #[must_use]
    pub fn image(&self, monitor: &MonitorKey) -> Option<ImageHandle> {
        self.entries.get(monitor).map(|entry| entry.image)
    }

    /// Records a monitor's new texture, returning the one it displaces.
    ///
    /// The caller releases what comes back. Destroying a LOVR texture is an
    /// FFI call this type cannot make, and [`TextureLedger::install`] returns
    /// the displaced texture for the same reason.
    ///
    /// [`TextureLedger::install`]: crate::texture::TextureLedger::install
    pub fn install(
        &mut self,
        monitor: MonitorKey,
        image: ImageHandle,
        texture: T,
        description: TextureDescription,
    ) -> Option<T> {
        self.entries
            .insert(
                monitor,
                Entry {
                    texture,
                    image,
                    description,
                },
            )
            .map(|displaced| displaced.texture)
    }

    /// The texture a monitor's mirror last produced.
    ///
    /// No frame generation is checked, unlike the surface ledger's `lookup`.
    /// The one caller builds and consumes the answer inside a single Lua call.
    /// The value it hands on is LOVR's own `Texture` object, not a reference
    /// this type could invalidate. `docs/lua-api.md` prescribes the rule:
    /// never cache the result across a frame.
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

    /// Drops what is held for a monitor, returning its texture.
    ///
    /// For a dismissed mirror or an unplugged monitor. Both stop producing
    /// frames. A texture nothing will refresh is a still picture that looks
    /// live, which is worse than no picture.
    pub fn forget(&mut self, monitor: &MonitorKey) -> Option<T> {
        self.entries.remove(monitor).map(|entry| entry.texture)
    }

    /// Which monitors hold a texture.
    ///
    /// Cloned, not borrowed, because the one caller, the frame loop's sweep
    /// for mirrors that have stopped, queries the mirror lifecycle about each
    /// in turn. The lifecycle is reachable from the same session this borrow
    /// would come from.
    #[must_use]
    pub fn monitors(&self) -> Vec<MonitorKey> {
        self.entries.keys().cloned().collect()
    }

    /// Every texture a mirrored monitor currently holds.
    ///
    /// The frame loop records the import barriers over these, alongside the
    /// surface ledger's. An imported image needs an acquire before the frame
    /// samples it, whether a client or PipeWire produced it.
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

    #[must_use]
    pub fn len(&self) -> usize {
        self.entries.len()
    }

    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }
}

#[derive(Debug)]
struct Entry<T> {
    texture: T,
    /// Which image the texture wraps, so a recurring PipeWire buffer is
    /// recognised and not re-wrapped.
    image: ImageHandle,
    description: TextureDescription,
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
    fn a_monitors_texture_comes_back_under_its_own_key() {
        let mut textures = MonitorTextures::new();
        textures.install(monitor(1), image(1), 10_u32, description());
        textures.install(monitor(2), image(2), 20_u32, description());

        assert_eq!(textures.texture(&monitor(1)), Some(&10));
        assert_eq!(textures.texture(&monitor(2)), Some(&20));
    }

    #[test]
    fn a_monitor_that_has_produced_nothing_holds_no_texture() {
        let textures = MonitorTextures::<u32>::new();

        assert_eq!(textures.texture(&monitor(1)), None);
        assert_eq!(textures.describe(&monitor(1)), None);
    }

    #[test]
    fn a_recurring_buffer_is_recognised_so_it_is_not_wrapped_again() {
        // PipeWire cycles a small fixed pool, so almost every frame after the
        // first few arrives on an image that is already installed.
        let mut textures = MonitorTextures::new();
        textures.install(monitor(1), image(7), 10_u32, description());

        assert_eq!(textures.image(&monitor(1)), Some(image(7)));
        assert_eq!(textures.image(&monitor(2)), None);
    }

    #[test]
    fn installing_over_a_monitor_hands_back_the_texture_it_displaced() {
        let mut textures = MonitorTextures::new();
        textures.install(monitor(1), image(1), 10_u32, description());

        let displaced = textures.install(monitor(1), image(2), 11_u32, description());

        assert_eq!(displaced, Some(10));
        assert_eq!(textures.texture(&monitor(1)), Some(&11));
        assert_eq!(textures.len(), 1);
    }

    #[test]
    fn the_first_install_for_a_monitor_displaces_nothing() {
        let mut textures = MonitorTextures::new();

        assert_eq!(
            textures.install(monitor(1), image(1), 10_u32, description()),
            None
        );
    }

    #[test]
    fn forgetting_a_monitor_hands_its_texture_back_and_stops_naming_it() {
        // A dismissed mirror produces no further frames, so a texture left
        // behind would be a still picture that looks live.
        let mut textures = MonitorTextures::new();
        textures.install(monitor(1), image(1), 10_u32, description());

        assert_eq!(textures.forget(&monitor(1)), Some(10));
        assert_eq!(textures.texture(&monitor(1)), None);
        assert_eq!(
            textures.textures().count(),
            0,
            "a texture already handed back must not be named in a barrier"
        );
    }

    #[test]
    fn forgetting_a_monitor_twice_is_not_an_error() {
        let mut textures = MonitorTextures::<u32>::new();

        assert_eq!(textures.forget(&monitor(1)), None);
    }

    #[test]
    fn every_installed_texture_is_offered_a_barrier() {
        let mut textures = MonitorTextures::new();
        textures.install(monitor(1), image(1), 10_u32, description());
        textures.install(monitor(2), image(2), 20_u32, description());

        let mut seen: Vec<u32> = textures.textures().copied().collect();
        seen.sort_unstable();

        assert_eq!(seen, vec![10, 20]);
    }

    #[test]
    fn teardown_hands_back_every_texture_once() {
        let mut textures = MonitorTextures::new();
        textures.install(monitor(1), image(1), 10_u32, description());
        textures.install(monitor(2), image(2), 20_u32, description());

        let mut taken = textures.take_all();
        taken.sort_unstable();

        assert_eq!(taken, vec![10, 20]);
        assert!(textures.take_all().is_empty());
        assert!(textures.is_empty());
    }

    #[test]
    fn the_description_records_the_size_a_frame_arrived_at() {
        // The size recorded here is what a mirrored monitor reports, and it
        // must match the captured output's resolution.
        let mut textures = MonitorTextures::new();
        textures.install(monitor(1), image(1), 10_u32, description());

        assert_eq!(
            textures.describe(&monitor(1)).map(|held| held.size),
            Some(PixelSize::new(1920, 1080)),
        );
    }
}
