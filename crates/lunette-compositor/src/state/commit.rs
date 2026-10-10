//! Adapted from the `CompositorHandler::commit` path in WayVR's
//! `backend/wayvr/comp.rs` (https://github.com/wayvr-org/wayvr), at commit
//! 98f800c644719d3f23a20e50bd3237c29a8082cb.
//! Copyright (c) the WayVR authors (galister, oo8dev). Licensed GPL-3.0-only.

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
        shell::xdg::XdgToplevelSurfaceData,
        shm::with_buffer_contents,
    },
};
use tracing::warn;

use crate::{
    protocol::{ContentType, Event, ImportedBuffer, PixelSize, SurfaceId},
    state::{compositor::CompositorState, outputs::logical_size},
    surface::{BufferScale, BufferTransform, ShmFormat, ShmLayout, SurfaceContent},
};

impl CompositorState {
    /// Applies one client commit. It releases the surface-state lock before imports
    /// and event sends, which may block.
    pub(super) fn apply_commit(&mut self, surface: &WlSurface) {
        let committed = with_states(surface, |states| {
            // Content-type is double-buffered; read the current value promoted by this commit.
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

    /// Records the client's content-type hint for Lua's throttling policy.
    fn remember_content_type(&mut self, id: SurfaceId, content_type: ContentType) {
        if let Some(window) = self.windows.by_surface_mut(id)
            && window.remember_content_type(content_type)
        {
            self.touch();
        }
    }

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

    /// Imports a dmabuf and retains its `wl_buffer` while lunette samples the image.
    /// The caller releases the buffer only when this returns `false`.
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

    /// Copies a shared-memory buffer into compositor-owned pixels and returns `false`
    /// so the caller releases the client's `wl_buffer`.
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

            // Copy only the committed buffer, not the rest of the client's pool.
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

        // The copied pixels no longer depend on the previous dmabuf, so release its
        // retained `wl_buffer` before recording the replacement.
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
        false
    }

    fn record_content(&mut self, id: SurfaceId, content: SurfaceContent) {
        if self.contents.insert(id, content) != Some(content) {
            self.touch();
        }
    }

    fn remember_committed_size(&mut self, id: SurfaceId) {
        let Some(content) = self.contents.get(&id).copied() else {
            return;
        };
        let bounds = self.output_bounds(
            self.windows
                .by_surface(id)
                .map_or(crate::state::DEFAULT_OUTPUT, |window| window.output),
        );
        let Some(window) = self.windows.by_surface_mut(id) else {
            return;
        };

        // Size limits can change at any commit, so refresh them before sizing.
        window.refresh_constraints(bounds);
        // Only a commit that acknowledged the pending configure settles it.
        let configure_serial = with_states(window.toplevel.wl_surface(), |states| {
            states
                .data_map
                .get::<XdgToplevelSurfaceData>()
                .and_then(|data| data.lock().ok().and_then(|data| data.current_serial))
        });
        let opened = window.map().then_some(window.id);
        let resized =
            window.remember_committed_size(logical_size(content.logical_size()), configure_serial);

        if opened.is_some() || resized {
            self.touch();
        }
        if let Some(window) = opened {
            self.report(Event::WindowOpened { window });
        }
    }

    /// Unmaps a surface after a null-buffer commit. A later commit may remap the
    /// same window, so its identifier remains stable. Reports `WindowClosed`
    /// before `SurfaceGone` so consumers observe the window before its texture
    /// is dropped.
    pub(super) fn unmap_surface(&mut self, id: SurfaceId) {
        self.buffers.forget(id);
        self.contents.remove(&id);
        self.touch();

        if let Some(window) = self.windows.by_surface_mut(id)
            && window.unmap()
        {
            let window = window.id;
            self.report(Event::WindowClosed { window });
        }

        self.report(Event::SurfaceGone { surface: id });
    }

    /// Releases the state retained for a destroyed surface. Dropping its retained
    /// `wl_buffer` allows the client's dmabuf to be collected.
    pub(super) fn forget_surface(&mut self, surface: &WlSurface) {
        let Some(id) = self.surfaces.forget(surface) else {
            return;
        };

        // The surface's callbacks are destroyed with it; answering them would
        // be a protocol error.
        self.frame_callbacks.remove(&id);
        self.forget_pacing(id);
        self.buffers.forget(id);
        self.contents.remove(&id);
        self.report(Event::SurfaceGone { surface: id });
    }
}

struct Committed {
    buffer: Option<BufferAssignment>,
    transform: smithay::reexports::wayland_server::protocol::wl_output::Transform,
    scale: i32,
    callbacks: Vec<WlCallback>,
    content_type: ContentType,
}

/// Converts the protocol's non-exhaustive content-type hint to lunette's closed
/// set. Unknown future variants become [`ContentType::None`].
fn content_type(reported: wp_content_type_v1::Type) -> ContentType {
    match reported {
        wp_content_type_v1::Type::Photo => ContentType::Photo,
        wp_content_type_v1::Type::Video => ContentType::Video,
        wp_content_type_v1::Type::Game => ContentType::Game,
        _ => ContentType::None,
    }
}
