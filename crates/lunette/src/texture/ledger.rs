//! Which surface holds which texture, and what is waiting to be destroyed.
//!
//! The frame thread owns everything here. A client commits a buffer, the
//! compositor thread turns it into an image or a repacked pixel buffer, and
//! this is where the texture that results is recorded, handed out for a frame,
//! replaced, and retired.
//!
//! The bookkeeping is generic over the texture, so the rotation, the frame
//! check, the dead-handle rule, the retirement schedule, and the stabilising
//! copy can all be exercised with an integer standing in for a texture.
//! [`LovrTexture`](crate::texture::LovrTexture) is what the binary substitutes.

#[cfg(test)]
mod tests;

use std::{collections::HashMap, fmt, sync::Arc};

use lunette_compositor::protocol::{ImageHandle, ImportedBuffer, PixelSize, SurfaceId};
use tracing::warn;

use crate::{
    import::{
        GraphicsDevice, ImageArena,
        formats::{Alpha, FormatMapping, mapping_for},
    },
    texture::{FrameGeneration, SurfaceCommit},
};

/// A reference to a surface's texture, valid for one frame.
///
/// `window:getTexture()` hands one of these out. Textures rotate as the client
/// cycles its buffers, so a handle kept across a frame boundary names something
/// that no longer exists — and rather than documenting that and hoping, the
/// generation is carried along and checked at every use.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TextureRef {
    surface: SurfaceId,
    generation: FrameGeneration,
}

impl TextureRef {
    #[must_use]
    pub const fn new(surface: SurfaceId, generation: FrameGeneration) -> Self {
        Self {
            surface,
            generation,
        }
    }

    #[must_use]
    pub const fn surface(self) -> SurfaceId {
        self.surface
    }

    #[must_use]
    pub const fn generation(self) -> FrameGeneration {
        self.generation
    }
}

/// Why a [`TextureRef`] resolved to nothing.
///
/// The three cases are answered differently in Lua, which is why they are
/// distinguished here rather than collapsed into an absence. A dead handle
/// returns `false` without raising, because a client exiting mid-frame is a
/// race and taking the session down over it is worse than doing nothing. A
/// stale one raises, because it is a defect in the caller's code and silence
/// would leave it undiagnosed.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TextureUnavailable {
    /// The surface has never committed a buffer, or was forgotten.
    Unknown,
    /// The client is gone. Reads return last-known values; nothing raises.
    Dead,
    /// The handle was obtained in an earlier frame.
    Stale {
        obtained: FrameGeneration,
        current: FrameGeneration,
    },
    /// A stabilised copy could not be allocated or written. Unlike the others
    /// this is not a race with a client: the device refused, which a caller
    /// cannot recover from and should hear about.
    CopyFailed,
}

impl fmt::Display for TextureUnavailable {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "texture: ")?;
        match self {
            Self::Unknown => write!(f, "the surface has no texture"),
            Self::Dead => write!(f, "the client is gone"),
            Self::Stale { obtained, current } => write!(
                f,
                "the handle was obtained in frame {obtained} and this is frame {current}; a \
                 window's texture rotates as its client cycles buffers, so call getTexture again \
                 rather than caching it"
            ),
            Self::CopyFailed => write!(f, "the stabilised copy could not be made"),
        }
    }
}

impl std::error::Error for TextureUnavailable {}

/// Which surface holds which texture, and what is waiting to be destroyed.
///
/// Generic over the texture so the bookkeeping — the rotation, the frame
/// check, the dead-handle rule, the retirement schedule — can be exercised
/// without a graphics device. `T` is [`LovrTexture`](crate::texture::LovrTexture)
/// in the binary and a plain integer in the tests.
#[derive(Debug)]
pub struct TextureLedger<T> {
    entries: HashMap<SurfaceId, Entry<T>>,
    /// The value the next install stamps its entry with. One counter for the
    /// whole ledger, for the reason [`SurfaceCommit`] records.
    commits: SurfaceCommit,
    morgue: Morgue,
}

impl<T> Default for TextureLedger<T> {
    fn default() -> Self {
        Self {
            entries: HashMap::new(),
            commits: SurfaceCommit::INITIAL,
            morgue: Morgue::default(),
        }
    }
}

impl<T> TextureLedger<T> {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Records a surface's new texture, returning the ones it displaces.
    ///
    /// The caller destroys what comes back. It is returned rather than dropped
    /// because destroying a LÖVR texture is an FFI call this type cannot make,
    /// and because the underlying image has to be retired at the same moment —
    /// which is the second thing this does.
    ///
    /// A stabilised copy is deliberately kept across the rotation: surviving it
    /// is the whole reason to have asked for one. The exception is a surface
    /// that changed shape, which a LÖVR texture cannot follow — its dimensions
    /// are fixed at creation — so the copy is released and the next
    /// [`stabilize`] allocates one that matches.
    ///
    /// [`stabilize`]: TextureLedger::stabilize
    pub fn install(
        &mut self,
        surface: SurfaceId,
        texture: T,
        description: TextureDescription,
    ) -> Released<T> {
        self.commits = self.commits.next();

        if let Some(entry) = self.entries.get_mut(&surface) {
            let resized = entry.description.size != description.size;
            let released = Released {
                imported: entry.texture.replace(texture),
                stable: if resized { entry.stable.take() } else { None },
            };

            entry.description = description;
            entry.dead = false;
            entry.damaged = true;
            entry.commit = self.commits;
            return released;
        }

        self.entries.insert(
            surface,
            Entry {
                texture: Some(texture),
                description,
                dead: false,
                stable: None,
                damaged: true,
                commit: self.commits,
            },
        );
        Released::default()
    }

    /// Marks a surface's client as gone.
    ///
    /// The description survives, so reads keep returning last-known values, and
    /// both textures are handed back for destruction: neither an image whose
    /// client has exited nor a copy of it is going to be looked at again, since
    /// every method of a dead handle answers `false` before it reaches one.
    pub fn mark_dead(&mut self, surface: SurfaceId) -> Released<T> {
        let Some(entry) = self.entries.get_mut(&surface) else {
            return Released::default();
        };

        entry.dead = true;
        Released {
            imported: entry.texture.take(),
            stable: entry.stable.take(),
        }
    }

    /// Drops everything known about a surface, returning its textures.
    pub fn forget(&mut self, surface: SurfaceId) -> Released<T> {
        self.entries
            .remove(&surface)
            .map_or_else(Released::default, |entry| Released {
                imported: entry.texture,
                stable: entry.stable,
            })
    }

    /// Resolves a handle against the frame it is being used in.
    ///
    /// Death is checked before staleness. A handle to a window whose client
    /// exited two frames ago is both, and answering `Dead` is what makes the
    /// documented "every method returns false without raising" hold for the
    /// case a caller is most likely to hit.
    ///
    /// # Errors
    ///
    /// See [`TextureUnavailable`].
    pub fn lookup(
        &self,
        reference: TextureRef,
        current: FrameGeneration,
    ) -> Result<&T, TextureUnavailable> {
        let Some(entry) = self.entries.get(&reference.surface) else {
            return Err(TextureUnavailable::Unknown);
        };
        if entry.dead {
            return Err(TextureUnavailable::Dead);
        }
        if reference.generation != current {
            return Err(TextureUnavailable::Stale {
                obtained: reference.generation,
                current,
            });
        }

        entry.texture.as_ref().ok_or(TextureUnavailable::Unknown)
    }

    /// What is known about a surface, alive or dead.
    ///
    /// Available after death on purpose: `docs/decisions.md` records that a
    /// dead handle reports last-known values rather than nothing, so a Lua
    /// layout does not collapse the frame a window closes on.
    #[must_use]
    pub fn describe(&self, surface: SurfaceId) -> Option<TextureDescription> {
        self.entries.get(&surface).map(|entry| entry.description)
    }

    /// A live surface's texture, and the commit that installed it.
    ///
    /// For the blit path, which wants both and neither a handle nor a
    /// generation check: it runs inside the frame loop rather than from Lua, so
    /// there is no caller-held reference for a generation to guard.
    ///
    /// Absent for a surface with no texture — never committed, or dead — which
    /// is the case the blit path answers by leaving the layer as it is.
    #[must_use]
    pub fn source(&self, surface: SurfaceId) -> Option<(&T, SurfaceCommit)> {
        let entry = self.entries.get(&surface)?;
        if entry.dead {
            return None;
        }
        Some((entry.texture.as_ref()?, entry.commit))
    }

    #[must_use]
    pub fn is_dead(&self, surface: SurfaceId) -> bool {
        self.entries.get(&surface).is_some_and(|entry| entry.dead)
    }

    /// Hands out the surface's stabilised copy, allocating it on first ask.
    ///
    /// The copy is lunette's own texture, so its identity survives the client
    /// cycling its buffers — which is the entire point, and the reason
    /// [`TextureLedger::lookup`] cannot be used for it. It is brought up to
    /// date here when the source has been damaged since it was last written, so
    /// that the first call in a frame returns something current whether or not
    /// [`TextureLedger::refresh_stable`] has run.
    ///
    /// The cost is a full-surface copy on every damaged frame, which for a 4K
    /// mirror at 90 Hz is around 3 GB/s. `docs/rendering.md` records why that
    /// makes this opt-in rather than the default.
    ///
    /// # Errors
    ///
    /// See [`TextureUnavailable`]. The generation is checked here as it is for
    /// an imported texture: the returned texture outlives the frame, but the
    /// surface it belongs to may not.
    pub fn stabilize(
        &mut self,
        reference: TextureRef,
        current: FrameGeneration,
    ) -> Result<&T, TextureUnavailable>
    where
        T: CopyableTexture,
    {
        let Some(entry) = self.entries.get_mut(&reference.surface) else {
            return Err(TextureUnavailable::Unknown);
        };
        if entry.dead {
            return Err(TextureUnavailable::Dead);
        }
        if reference.generation != current {
            return Err(TextureUnavailable::Stale {
                obtained: reference.generation,
                current,
            });
        }
        let Some(source) = entry.texture.as_ref() else {
            return Err(TextureUnavailable::Unknown);
        };

        if entry.stable.is_none() {
            entry.stable = Some(
                source
                    .allocate_copy()
                    .ok_or(TextureUnavailable::CopyFailed)?,
            );
            entry.damaged = true;
        }

        let Some(stable) = entry.stable.as_ref() else {
            return Err(TextureUnavailable::CopyFailed);
        };
        if entry.damaged {
            if !source.copy_to(stable) {
                return Err(TextureUnavailable::CopyFailed);
            }
            entry.damaged = false;
        }

        Ok(stable)
    }

    /// Brings every stabilised copy up to date with the buffer behind it.
    ///
    /// Runs once a frame, after the frame's buffers have been installed and
    /// before anything draws. A surface that has not been damaged since its
    /// copy was last written is skipped, which is what makes an idle window cost
    /// nothing.
    pub fn refresh_stable(&mut self)
    where
        T: CopyableTexture,
    {
        for (surface, entry) in &mut self.entries {
            if entry.dead || !entry.damaged {
                continue;
            }
            let (Some(source), Some(stable)) = (entry.texture.as_ref(), entry.stable.as_ref())
            else {
                continue;
            };

            if source.copy_to(stable) {
                entry.damaged = false;
            } else {
                // Left damaged, so the next frame tries again rather than
                // leaving the copy silently showing an older frame for ever.
                warn!(%surface, "a stabilised surface could not be updated");
            }
        }
    }

    /// Every texture a live surface currently holds.
    ///
    /// The frame loop records the import barriers over these: an acquire before
    /// anything in the frame can sample one, and a release after. A dead
    /// surface is skipped because its texture has already been handed back.
    pub fn textures(&self) -> impl Iterator<Item = &T> {
        self.entries
            .values()
            .filter(|entry| !entry.dead)
            .flat_map(|entry| entry.texture.iter().chain(entry.stable.iter()))
    }

    /// Empties the ledger, returning every texture it held.
    ///
    /// For teardown, where the caller releases all of them at once. The images
    /// behind them are not retired: a shutdown destroys the graphics device
    /// immediately afterwards, and [`destroy_due_images`] cannot run then
    /// because the deferral it counts in frames has no frames left to count.
    #[must_use]
    pub fn take_all(&mut self) -> Vec<T> {
        self.entries
            .drain()
            .flat_map(|(_, entry)| entry.texture.into_iter().chain(entry.stable))
            .collect()
    }

    /// Schedules an image for destruction.
    pub fn retire_image(&mut self, image: ImageHandle, now: FrameGeneration) {
        self.morgue.retire(image, now);
    }

    /// The images whose deferral has elapsed.
    pub fn collect_due_images(&mut self, now: FrameGeneration) -> Vec<ImageHandle> {
        self.morgue.collect_due(now)
    }
}

/// What a surface's texture is, kept whether or not the texture still exists.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TextureDescription {
    pub size: PixelSize,
    /// Whether the fourth component is alpha or padding. An
    /// [`Alpha::Opaque`] texture is drawn with alpha forced to one; sampling it
    /// renders the surface with whatever the client happened to leave there.
    pub alpha: Alpha,
}

#[derive(Debug)]
struct Entry<T> {
    /// Absent once the client is gone, and while a replacement is being
    /// installed.
    texture: Option<T>,
    description: TextureDescription,
    dead: bool,
    /// The lunette-owned copy `window:stabilize()` hands out, present only once
    /// something has asked for one.
    stable: Option<T>,
    /// Whether the source has been replaced since the copy was last written.
    /// Set by every install, including the first, because a copy is only ever
    /// as current as the last buffer it was given.
    damaged: bool,
    /// Which install produced the texture this entry holds. The blit path
    /// compares it against what it last copied; `damaged` cannot serve both,
    /// because [`TextureLedger::refresh_stable`] clears it.
    commit: SurfaceCommit,
}

/// The textures a change to the ledger handed back for release.
///
/// Two fields rather than a list, because the caller has to be able to tell an
/// imported texture from one LÖVR allocated: only the first has an image behind
/// it that lunette destroys separately.
#[derive(Debug, PartialEq, Eq)]
pub struct Released<T> {
    /// The texture wrapping a client's buffer.
    pub imported: Option<T>,
    /// The stabilised copy, when it can no longer be kept.
    pub stable: Option<T>,
}

impl<T> Default for Released<T> {
    fn default() -> Self {
        Self {
            imported: None,
            stable: None,
        }
    }
}

impl<T> IntoIterator for Released<T> {
    type Item = T;
    type IntoIter = std::iter::Flatten<std::array::IntoIter<Option<T>, 2>>;

    /// Both textures, for a caller that releases them the same way.
    fn into_iter(self) -> Self::IntoIter {
        [self.imported, self.stable].into_iter().flatten()
    }
}

/// A texture that can be copied into another of its own shape.
///
/// The seam between the bookkeeping and the device. `window:stabilize()` needs
/// to allocate a texture and record a copy into it, and neither is something
/// [`TextureLedger`] can do for an arbitrary `T` — so both are asked of the
/// texture, and the tests answer with a counter.
pub trait CopyableTexture: Sized {
    /// Allocates a texture with this one's shape, to be copied into.
    ///
    /// `None` when the device refused.
    fn allocate_copy(&self) -> Option<Self>;

    /// Records a copy of this texture into `destination`, reporting whether it
    /// was accepted.
    fn copy_to(&self, destination: &Self) -> bool;
}

/// Images waiting out their deferral before being destroyed.
///
/// `gpu_texture_destroy` puts the image *view* into LÖVR's own morgue and
/// returns without touching the image. The image is lunette's, and freeing it
/// while a command buffer LÖVR has already recorded still names the view is a
/// use-after-free that a driver reports, at best, as a device loss several
/// frames later.
#[derive(Debug, Default)]
struct Morgue {
    pending: Vec<(ImageHandle, FrameGeneration)>,
}

impl Morgue {
    fn retire(&mut self, image: ImageHandle, now: FrameGeneration) {
        self.pending.push((image, now));
    }

    /// The images retired long enough ago to be destroyed.
    fn collect_due(&mut self, now: FrameGeneration) -> Vec<ImageHandle> {
        let mut due = Vec::new();
        self.pending.retain(|(image, retired)| {
            if now.get().saturating_sub(retired.get()) >= DESTROY_DELAY {
                due.push(*image);
                false
            } else {
                true
            }
        });
        due
    }
}

/// How many frames an image waits before it is destroyed.
///
/// One would be the minimum: LÖVR retires the view at the end of the tick the
/// texture was destroyed in. Two is used because the minimum leaves no margin
/// for a frame that submits twice, and an image is a few megabytes held for
/// sixteen milliseconds longer — a trade heavily in favour of the margin.
const DESTROY_DELAY: u64 = 2;

/// What a buffer of either kind says about the texture it becomes.
#[must_use]
pub fn describe(buffer: &ImportedBuffer) -> TextureDescription {
    match buffer {
        ImportedBuffer::Image(image) => TextureDescription {
            size: image.size,
            alpha: mapping_for(image.format)
                .map_or(Alpha::Present, |mapping: FormatMapping| mapping.alpha),
        },
        ImportedBuffer::Pixels(pixels) => TextureDescription {
            size: pixels.size(),
            // The repack forced the padding byte to one, so what arrives here
            // carries alpha whichever format the client used.
            alpha: Alpha::Present,
        },
    }
}

/// Destroys the images whose deferral has elapsed.
///
/// # Safety
///
/// This must run once per frame, and after everything in the frame that can
/// retire an image has run. There are two such producers, and the deferral is
/// only sound because both are ordered ahead of this call.
///
/// A **client's buffer** is retired by the compositor only once the client has
/// destroyed it, which it can only have done after committing a replacement — so
/// the event installing that replacement is drained in this frame or an earlier
/// one. This must therefore follow the drain: after every
/// [`TextureLedger::install`], [`mark_dead`], and [`forget`] the frame is going
/// to perform, and after the texture each of those handed back has been
/// released.
///
/// A **captured monitor frame** has no such producer. Its image is retired when
/// [`CaptureImporter`] drops the `Dmabuf` behind it, which lunette's own budget
/// decides, so the ordering argument above does not carry over. What stands in
/// for it is that the importer never releases the buffer whose image the
/// monitor's texture currently wraps, and that a monitor's texture is released
/// before its stream's buffers are. This must therefore also follow the frame's
/// capture import and its sweep for mirrors that have stopped.
///
/// Given both, LÖVR retires the view at the end of this tick and
/// [`DESTROY_DELAY`] frames of margin follow. Calling this earlier inverts the
/// ordering and frees an image a recorded command buffer still names.
///
/// [`mark_dead`]: TextureLedger::mark_dead
/// [`forget`]: TextureLedger::forget
/// [`CaptureImporter`]: crate::import::CaptureImporter
pub unsafe fn destroy_due_images<T>(
    ledger: &mut TextureLedger<T>,
    arena: &ImageArena,
    device: &Arc<GraphicsDevice>,
    now: FrameGeneration,
) {
    for image in arena.take_retired() {
        ledger.retire_image(image, now);
    }

    for image in ledger.collect_due_images(now) {
        // SAFETY: the caller's guarantee, established by the deferral.
        unsafe { arena.destroy(image, device) };
    }
}
