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
    reexports::wayland_server::{
        Resource,
        protocol::{wl_buffer::WlBuffer, wl_callback::WlCallback, wl_surface::WlSurface},
    },
    wayland::{
        compositor::{BufferAssignment, SurfaceAttributes, with_states},
        dmabuf::get_dmabuf,
        shm::with_buffer_contents,
    },
};
use tracing::warn;

use crate::{
    protocol::{Event, PixelSize, SurfaceId},
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
            let mut guard = states.cached_state.get::<SurfaceAttributes>();
            let attributes = guard.current();
            Committed {
                buffer: attributes.buffer.take(),
                transform: attributes.buffer_transform,
                scale: attributes.buffer_scale,
                callbacks: std::mem::take(&mut attributes.frame_callbacks),
            }
        });

        let id = self.surfaces.id_for(surface);

        if !committed.callbacks.is_empty() {
            self.frame_callbacks
                .entry(surface.id())
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

        self.remember_committed_size(id);
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
    fn import_dmabuf(
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
        self.report(Event::BufferImported { surface: id, image });
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
                .and_then(|bytes| bytes.checked_add(offset));
            match needed {
                Some(needed) if needed <= length => {}
                _ => {
                    return Err("a wl_shm buffer is smaller than its own stride implies".to_owned());
                }
            }

            // SAFETY: `with_buffer_contents` guarantees the pointer addresses
            // `length` readable bytes of the client's pool for the duration of
            // this call, and the bounds check above keeps the slice inside it.
            let pixels =
                unsafe { std::slice::from_raw_parts(pointer.add(offset), length - offset) };

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

        let image = match self.importer.import_shm(&pixels, layout) {
            Ok(image) => image,
            Err(error) => {
                warn!(%error, "could not import a client's shared-memory buffer");
                return false;
            }
        };

        self.record_content(
            id,
            SurfaceContent {
                size: layout.size,
                transform,
                scale,
            },
        );
        self.report(Event::BufferImported { surface: id, image });
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
        let bounds = self.output_logical_size();
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
    pub(super) fn unmap_surface(&mut self, id: SurfaceId) {
        self.buffers.forget(id);
        self.contents.remove(&id);
        self.touch();

        let Some(window) = self.windows.by_surface_mut(id) else {
            return;
        };
        if window.unmap() {
            let window = window.id();
            self.report(Event::WindowClosed { window });
        }
    }

    /// Forgets everything keyed on a surface that is going away.
    pub(super) fn forget_surface(&mut self, surface: &WlSurface) {
        self.frame_callbacks.remove(&surface.id());
        if let Some(id) = self.surfaces.forget(surface) {
            self.buffers.forget(id);
            self.contents.remove(&id);
        }
    }
}

/// What one commit carried, gathered under the surface's lock.
struct Committed {
    buffer: Option<BufferAssignment>,
    transform: smithay::reexports::wayland_server::protocol::wl_output::Transform,
    scale: i32,
    callbacks: Vec<WlCallback>,
}
