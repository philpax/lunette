//! The virtual monitors clients are shown, and what changing one means.
//!
//! [`crate::output::OutputRegistry`] owns the `wl_output` globals and the modes;
//! this is what the compositor does around them. Creating and destroying an
//! output is a global going up or coming down, and reconfiguring one is a fanout
//! nothing else performs: the registry sends `wl_output.mode`, and every surface
//! on that output is owed a `wl_surface.preferred_buffer_scale`, a fractional
//! preference, and a toplevel configure at the matching logical size. A client
//! told its monitor changed and not told its own new scale renders sharp content
//! at the wrong size.
//!
//! Split out of `compositor.rs` as a self-contained concern.

use smithay::{
    reexports::wayland_server::{Resource, protocol::wl_surface::WlSurface},
    utils::{Logical, Size, Transform},
    wayland::{
        compositor::{send_surface_state, with_states},
        fractional_scale::with_fractional_scale,
    },
};
use tracing::{debug, info, warn};

use crate::{
    output::{OutputEntry, integer_scale},
    protocol::{OutputId, OutputMode, PixelSize},
    state::{CompositorState, DEFAULT_OUTPUT, compositor::ClientState},
};

impl CompositorState {
    /// Creates a virtual monitor and advertises its global.
    ///
    /// A duplicate identifier is reported and dropped rather than replacing the
    /// output that holds it: the clients already bound to that one would be
    /// silently reconfigured to a mode nobody asked them to take.
    pub(super) fn create_output(&mut self, output: OutputId, mode: OutputMode) {
        match self.outputs.create(&self.display, output, mode) {
            Ok(()) => {
                info!(%output, "an output was created");
                self.touch();
            }
            Err(error) => warn!(%error, "could not create an output"),
        }
    }

    /// Changes an output's mode, and tells everything on it.
    ///
    /// The `wl_output` events are the registry's; the per-surface scales and the
    /// toplevel configures are [`CompositorState::rescale_output`]'s. A client
    /// told its monitor changed and not told its own new scale keeps rendering
    /// at the old one.
    pub(super) fn reconfigure_output(&mut self, output: OutputId, mode: OutputMode) {
        match self.outputs.reconfigure(output, mode) {
            Ok(()) => {
                self.rescale_output(output);
                self.touch();
            }
            Err(error) => warn!(%error, "could not reconfigure an output"),
        }
    }

    /// Withdraws an output.
    ///
    /// The default output is refused. It is what a client that was assigned no
    /// output is shown, and every adopted client is one of those, so a session
    /// without it has clients that can see no monitor at all.
    pub(super) fn destroy_output(&mut self, output: OutputId) {
        if output == DEFAULT_OUTPUT {
            debug!("the default output cannot be destroyed; a client assigned none needs it");
            return;
        }

        match self.outputs.destroy(&self.display, output) {
            Ok(()) => self.touch(),
            Err(error) => warn!(%error, "could not destroy an output"),
        }
    }

    /// Tells everything on an output that its mode changed.
    ///
    /// Three things travel together, and a client that gets only some of them
    /// renders at the wrong size: the scales, through
    /// [`CompositorState::send_surface_scale`]; the size limits, which are
    /// clamped against the output and so move with it; and a configure at the
    /// new logical bounds.
    ///
    /// Each window is reconfigured at the size it last committed, clamped into
    /// the new bounds. So an output that shrank — which is what raising the
    /// scale of a fixed resolution does — pulls its windows in, and an output
    /// that grew leaves them where Lua put them.
    pub(super) fn rescale_output(&mut self, output: OutputId) {
        for surface in self.outputs.surfaces() {
            if self.output_of(&surface) == output {
                self.send_surface_scale(&surface);
            }
        }

        let bounds = self.output_bounds(output);
        for window in self.windows.on_output(output) {
            window.refresh_constraints(bounds);
            let size = logical_size(window.size());
            window.request_size(size, bounds);
        }
    }

    /// The mode an output is advertising, or the default output's when it has
    /// been destroyed, which is the fallback [`CompositorState::output_bounds`]
    /// takes for the same reason.
    pub(super) fn mode_of(&self, output: OutputId) -> OutputMode {
        self.outputs
            .get(output)
            .or_else(|| self.outputs.get(DEFAULT_OUTPUT))
            .map_or(self.config.output, OutputEntry::mode)
    }

    /// The output a surface's client is shown, which is the one it was assigned
    /// or the default when it was assigned none.
    pub(super) fn output_of(&self, surface: &WlSurface) -> OutputId {
        assigned_output(surface).unwrap_or(DEFAULT_OUTPUT)
    }

    /// The logical size a window on `output` is configured against.
    ///
    /// A window whose client was assigned no output is bounded by the default
    /// one, which is also the output that client is shown. So is a window whose
    /// assigned output has since been destroyed: the bounds have to be some
    /// size, and the one every unassigned client is already using is the least
    /// surprising.
    pub(super) fn output_bounds(&self, output: OutputId) -> Size<i32, Logical> {
        self.outputs
            .get(output)
            .or_else(|| self.outputs.get(DEFAULT_OUTPUT))
            .map_or_else(
                || logical_size(self.config.output.size),
                |entry| entry.logical_size(),
            )
    }

    /// The logical size a surface's client is configured against.
    ///
    /// For the paths that hold a surface and no window: a toplevel being
    /// created, a popup being constrained, a fullscreen request.
    pub(super) fn surface_bounds(&self, surface: &WlSurface) -> Size<i32, Logical> {
        self.output_bounds(self.output_of(surface))
    }

    /// Tells one surface the scale of the output its client is shown.
    ///
    /// Both numbers, because a client is owed both. `wp_fractional_scale_v1`
    /// carries the exact scale in 120ths, which is what a client renders at;
    /// `wl_surface.preferred_buffer_scale` carries the whole number a client
    /// without the fractional protocol renders at, and it is the ceiling rather
    /// than the floor so that a client on a 1.5 scale is not told its monitor is
    /// unscaled. The matching logical size travels separately, as an xdg-toplevel
    /// configure; sending a scale without one produces sharp content at the
    /// wrong size, which reads as a bug in the client.
    ///
    /// Set whether or not the client has asked for a `wp_fractional_scale_v1`
    /// yet. smithay replays a pre-set value when the object is created
    /// (`fractional_scale/mod.rs:160-166`), so pre-setting is what avoids a
    /// first frame at the wrong scale.
    ///
    /// # Thread affinity
    ///
    /// `with_fractional_scale` inserts into the surface's user data with the
    /// non-threadsafe `get_or_insert` (`fractional_scale/mod.rs:253-263`), which
    /// records the calling thread and answers `None` to every other one — so a
    /// second thread would insert a second entry and the two would diverge in
    /// silence. Everything here runs on the compositor thread, which is the only
    /// thing that dispatches [`CompositorState`].
    pub(super) fn send_surface_scale(&self, surface: &WlSurface) {
        let mode = self.mode_of(self.output_of(surface));

        with_states(surface, |states| {
            send_surface_state(
                surface,
                states,
                integer_scale(mode.scale),
                Transform::Normal,
            );
            with_fractional_scale(states, |fractional| {
                fractional.set_preferred_scale(mode.scale.get());
            });
        });
    }

    /// Tells a newly created surface which output it is on and at what scale.
    pub(super) fn send_initial_surface_state(&mut self, surface: &WlSurface) {
        self.outputs.enter(surface);
        self.send_surface_scale(surface);
    }
}

/// Converts a pixel size to smithay's logical coordinate space.
///
/// The two are the same at scale one, which is the only scale Phase 2 uses;
/// Phase 8 is what makes the distinction real.
pub(super) fn logical_size(size: PixelSize) -> Size<i32, Logical> {
    #[expect(
        clippy::cast_possible_wrap,
        reason = "a size beyond two billion pixels is not a mode any hardware or protocol carries"
    )]
    Size::new(size.width as i32, size.height as i32)
}

/// The output a surface's client was assigned, if it was assigned one.
fn assigned_output(surface: &WlSurface) -> Option<OutputId> {
    surface.client()?.get_data::<ClientState>()?.output()
}
