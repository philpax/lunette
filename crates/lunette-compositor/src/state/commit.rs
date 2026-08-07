//! Ported from WayVR (https://github.com/wayvr-org/wayvr), backend/wayvr/comp.rs (the `CompositorHandler::commit` path at :229-322), at commit 98f800c644719d3f23a20e50bd3237c29a8082cb.
//! Copyright (c) the WayVR authors (galister, oo8dev). Licensed GPL-3.0-only.
//!
//! What happens when a client commits.
//!
//! One commit carries a buffer, a transform, a scale, and a list of frame
//! callbacks. Turning that into an image on the graphics device, an owned
//! buffer, and a window with a size is the whole of this file.
//!
//! The state is gathered under the surface's lock and acted on outside it. An
//! import can be slow and a send into a bounded channel can wait, and neither
//! should happen while a lock a later handler needs is held.

use smithay::{
    backend::renderer::{BufferType, buffer_type},
    reexports::{
        wayland_protocols::wp::content_type::v1::server::wp_content_type_v1,
        wayland_server::protocol::{
            wl_buffer::WlBuffer, wl_callback::WlCallback, wl_surface::WlSurface,
        },
    },
    wayland::{
        compositor::{BufferAssignment, SurfaceAttributes, with_states},
        content_type::ContentTypeSurfaceCachedState,
        dmabuf::get_dmabuf,
        shm::with_buffer_contents,
    },
};
use tracing::warn;

use crate::{
    protocol::{ContentType, Event, ImportedBuffer, PixelSize, SurfaceId},
    state::compositor::CompositorState,
    surface::{BufferScale, BufferTransform, ShmFormat, ShmLayout, SurfaceContent},
};

impl CompositorState {
    /// Applies one client commit.
    ///
    /// The state is gathered under the surface's lock and acted on outside it,
    /// so nothing that can block — an import, a send into a bounded channel —
    /// happens while the lock is held.
    pub(super) fn apply_commit(&mut self, surface: &WlSurface) {
        let committed = with_states(surface, |states| {
            // Read inside the same `with_states` as the attributes, and from
            // `current()` rather than `pending()`: `wp_content_type_v1` is
            // double-buffered like everything else a client sets, so the value
            // that takes effect is the one this commit promoted.
            let content_type = content_type(
                *states
                    .cached_state
                    .get::<ContentTypeSurfaceCachedState>()
                    .current()
                    .content_type(),
            );

            let mut guard = states.cached_state.get::<SurfaceAttributes>();
            let attributes = guard.current();
            Committed {
                buffer: attributes.buffer.take(),
                transform: attributes.buffer_transform,
                scale: attributes.buffer_scale,
                callbacks: std::mem::take(&mut attributes.frame_callbacks),
                content_type,
            }
        });

        let id = self.surfaces.id_for(surface);

        if !committed.callbacks.is_empty() {
            self.frame_callbacks
                .entry(id)
                .or_default()
                .extend(committed.callbacks);
        }

        match committed.buffer {
            Some(BufferAssignment::NewBuffer(buffer)) => {
                self.attach_buffer(id, &buffer, committed.transform, committed.scale);
            }
            Some(BufferAssignment::Removed) => self.unmap_surface(id),
            None => {}
        }

        self.remember_content_type(id, committed.content_type);
        self.remember_committed_size(id);
    }

    /// Records what the client says a surface is drawing.
    ///
    /// Reported through the snapshot rather than acted on. The hint is thinly
    /// adopted, so a client playing video may set nothing at all; Lua combines
    /// it with a commit-rate heuristic and decides what to exempt from
    /// throttling.
    fn remember_content_type(&mut self, id: SurfaceId, content_type: ContentType) {
        if let Some(window) = self.windows.by_surface_mut(id)
            && window.remember_content_type(content_type)
        {
            self.touch();
        }
    }

    /// Imports a newly attached buffer and takes ownership of it.
    fn attach_buffer(
        &mut self,
        id: SurfaceId,
        buffer: &WlBuffer,
        transform: smithay::reexports::wayland_server::protocol::wl_output::Transform,
        scale: i32,
    ) {
        let Some(transform) = BufferTransform::from_protocol(transform) else {
            warn!(
                ?transform,
                "unrecognised buffer transform; releasing the buffer"
            );
            buffer.release();
            return;
        };
        let Some(scale) = BufferScale::from_protocol(scale) else {
            warn!(
                scale,
                "a buffer scale below one is a protocol error; releasing the buffer"
            );
            buffer.release();
            return;
        };

        let imported = match buffer_type(buffer) {
            Some(BufferType::Dma) => self.import_dmabuf(id, buffer, transform, scale),
            Some(BufferType::Shm) => self.import_shm(id, buffer, transform, scale),
            Some(other) => {
                warn!(?other, "unsupported buffer type; releasing the buffer");
                false
            }
            None => {
                warn!("a buffer of no recognised type was attached; releasing it");
                false
            }
        };

        if !imported {
            buffer.release();
        }
    }

    /// Imports a dmabuf and retains its `wl_buffer` until the next one arrives.
    ///
    /// Returns whether the caller still owns the buffer. A dmabuf is held for
    /// as long as lunette samples it, which is the rule
    /// `SurfaceBufWithImageContainer` implements upstream; shared memory is
    /// copied out and released immediately.
    pub(super) fn import_dmabuf(
        &mut self,
        id: SurfaceId,
        buffer: &WlBuffer,
        transform: BufferTransform,
        scale: BufferScale,
    ) -> bool {
        let Ok(dmabuf) = get_dmabuf(buffer) else {
            warn!("a buffer reported as a dmabuf carried no dmabuf");
            return false;
        };

        let image = match self.importer.import_dmabuf(dmabuf) {
            Ok(image) => image,
            Err(error) => {
                warn!(%error, "could not import a client dmabuf");
                return false;
            }
        };

        self.buffers.retain(id, buffer.clone());
        self.record_content(
            id,
            SurfaceContent {
                size: image.size,
                transform,
                scale,
            },
        );
        self.report(Event::BufferImported {
            surface: id,
            buffer: ImportedBuffer::Image(image),
        });
        self.report(Event::SurfaceDamaged { surface: id });
        true
    }

    /// Imports a shared-memory buffer, which is copied and released at once.
    fn import_shm(
        &mut self,
        id: SurfaceId,
        buffer: &WlBuffer,
        transform: BufferTransform,
        scale: BufferScale,
    ) -> bool {
        let outcome = with_buffer_contents(buffer, |pointer, length, data| {
            let Some(format) = ShmFormat::from_protocol(data.format) else {
                return Err(format!("unsupported wl_shm format {:?}", data.format));
            };

            let size = match (u32::try_from(data.width), u32::try_from(data.height)) {
                (Ok(width), Ok(height)) => PixelSize::new(width, height),
                _ => return Err("a wl_shm buffer declared a negative size".to_owned()),
            };
            let Ok(stride) = u32::try_from(data.stride) else {
                return Err("a wl_shm buffer declared a negative stride".to_owned());
            };
            let Ok(offset) = usize::try_from(data.offset) else {
                return Err("a wl_shm buffer declared a negative offset".to_owned());
            };

            let needed = usize::try_from(stride)
                .ok()
                .and_then(|stride| stride.checked_mul(size.height as usize))
                .and_then(|bytes| bytes.checked_add(offset))
                .filter(|needed| *needed <= length);
            let Some(needed) = needed else {
                return Err("a wl_shm buffer is smaller than its own stride implies".to_owned());
            };

            // Only what the layout describes. A pool holds every buffer a
            // client cycles through, so copying to the end of it would copy the
            // whole pool on every commit rather than the one buffer committed.
            let described = needed - offset;

            // SAFETY: `with_buffer_contents` guarantees the pointer addresses
            // `length` readable bytes of the client's pool for the duration of
            // this call, and the bounds check above keeps the slice inside it.
            let pixels = unsafe { std::slice::from_raw_parts(pointer.add(offset), described) };

            Ok((
                pixels.to_vec(),
                ShmLayout {
                    size,
                    stride,
                    format,
                },
            ))
        });

        let (pixels, layout) = match outcome {
            Ok(Ok(gathered)) => gathered,
            Ok(Err(reason)) => {
                warn!(reason, "rejected a shared-memory buffer");
                return false;
            }
            Err(error) => {
                warn!(%error, "could not read a shared-memory buffer");
                return false;
            }
        };

        let packed = match self.importer.import_shm(&pixels, layout) {
            Ok(packed) => packed,
            Err(error) => {
                warn!(%error, "could not import a client's shared-memory buffer");
                return false;
            }
        };

        // Whatever this surface last committed is no longer being sampled: the
        // copy above replaces it. A surface that falls back from dmabuf to
        // shared memory — which modifier renegotiation makes a client do
        // mid-session — would otherwise leave its last dmabuf pinned until it
        // unmapped, holding the client's graphics memory for a buffer lunette
        // has stopped reading.
        self.buffers.forget(id);

        self.record_content(
            id,
            SurfaceContent {
                size: layout.size,
                transform,
                scale,
            },
        );
        self.report(Event::BufferImported {
            surface: id,
            buffer: ImportedBuffer::Pixels(packed),
        });
        self.report(Event::SurfaceDamaged { surface: id });
        // The copy is taken, so the client may reuse the buffer at once.
        false
    }

    fn record_content(&mut self, id: SurfaceId, content: SurfaceContent) {
        if self.contents.insert(id, content) != Some(content) {
            self.touch();
        }
    }

    /// Notices a toplevel's first mapped buffer and its size changes.
    fn remember_committed_size(&mut self, id: SurfaceId) {
        let Some(content) = self.contents.get(&id).copied() else {
            return;
        };
        let bounds = self.output_bounds(
            self.windows
                .by_surface(id)
                .map_or(crate::state::DEFAULT_OUTPUT, crate::window::Window::output),
        );
        let Some(window) = self.windows.by_surface_mut(id) else {
            return;
        };

        // A client may change its own size limits at any commit, so they are
        // re-read rather than captured once when the toplevel was created.
        window.refresh_constraints(bounds);
        let change = window.remember_committed_size(content.logical_size());
        let opened = change.mapped.then(|| window.id());

        if change.is_visible() {
            self.touch();
        }
        if let Some(window) = opened {
            self.report(Event::WindowOpened { window });
        }
    }

    /// Handles a commit that removed a surface's buffer.
    ///
    /// Attaching a null buffer to an xdg-toplevel unmaps it, and the protocol
    /// says the client may then re-map it by committing again. So the window is
    /// reported closed but keeps its identifier, and re-mapping reports it
    /// opened rather than creating a second one.
    ///
    /// [`Event::SurfaceGone`] is reported after the window's own closure, so the
    /// frame thread sees the window die before the surface's texture is dropped
    /// — the order the two events describe the same moment in.
    pub(super) fn unmap_surface(&mut self, id: SurfaceId) {
        self.buffers.forget(id);
        self.contents.remove(&id);
        self.touch();

        if let Some(window) = self.windows.by_surface_mut(id)
            && window.unmap()
        {
            let window = window.id();
            self.report(Event::WindowClosed { window });
        }

        self.report(Event::SurfaceGone { surface: id });
    }

    /// Forgets everything keyed on a surface that is going away.
    ///
    /// Dropping the retained `wl_buffer` is what makes the client's dmabuf
    /// collectable. Noticing that is the sweep the thread runs after every
    /// dispatch, and this happens inside one.
    pub(super) fn forget_surface(&mut self, surface: &WlSurface) {
        let Some(id) = self.surfaces.forget(surface) else {
            return;
        };

        // Dropped rather than answered. The surface is gone, so the client's
        // `wl_callback` objects went with it and answering one would be a
        // protocol error against a destroyed resource.
        self.frame_callbacks.remove(&id);
        self.forget_pacing(id);
        self.buffers.forget(id);
        self.contents.remove(&id);
        self.report(Event::SurfaceGone { surface: id });
    }
}

/// What one commit carried, gathered under the surface's lock.
struct Committed {
    buffer: Option<BufferAssignment>,
    transform: smithay::reexports::wayland_server::protocol::wl_output::Transform,
    scale: i32,
    callbacks: Vec<WlCallback>,
    content_type: ContentType,
}

/// The protocol's content-type hint as lunette's own closed set.
///
/// `wp_content_type_v1::Type` is `#[non_exhaustive]`, so a variant added to the
/// protocol later arrives here as a value this match does not name. It is
/// reported as [`ContentType::None`], which is the protocol's own default and
/// the honest answer: lunette does not know what the client meant.
fn content_type(reported: wp_content_type_v1::Type) -> ContentType {
    match reported {
        wp_content_type_v1::Type::Photo => ContentType::Photo,
        wp_content_type_v1::Type::Video => ContentType::Video,
        wp_content_type_v1::Type::Game => ContentType::Game,
        _ => ContentType::None,
    }
}
