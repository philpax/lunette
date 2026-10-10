//! Coordinates virtual outputs and propagates their modes and scales to clients.
//!
//! [`crate::output::OutputRegistry`] owns the `wl_output` globals and modes. This
//! module sends the corresponding surface scales and toplevel configures.

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
    /// Rejects a duplicate identifier. Replacing the existing output would
    /// silently reconfigure its bound clients.
    pub(super) fn create_output(&mut self, output: OutputId, mode: OutputMode) {
        match self.outputs.create(&self.display, output, mode) {
            Ok(()) => {
                info!(%output, "an output was created");
                self.touch();
            }
            Err(error) => warn!(%error, "could not create an output"),
        }
    }

    /// Updates the registry, surface scales, and toplevel configures together.
    /// A client that receives only the registry event keeps rendering at the old
    /// scale.
    pub(super) fn reconfigure_output(&mut self, output: OutputId, mode: OutputMode) {
        match self.outputs.reconfigure(output, mode) {
            Ok(()) => {
                self.rescale_output(output);
                self.touch();
            }
            Err(error) => warn!(%error, "could not reconfigure an output"),
        }
    }

    /// Refuses to withdraw the default output because unassigned clients use it.
    pub(super) fn destroy_output(&mut self, output: OutputId) {
        if output == DEFAULT_OUTPUT {
            debug!("the default output cannot be destroyed; a client assigned none needs it");
            return;
        }

        let orphaned = match self.outputs.destroy(&self.display, output) {
            Ok(surfaces) => surfaces,
            Err(error) => {
                warn!(%error, "could not destroy an output");
                return;
            }
        };

        self.adopt_orphans(output, &orphaned);
        self.touch();
    }

    /// Reassigns clients, surfaces, and windows from a withdrawn output to the
    /// default. The default global is re-advertised when client assignments
    /// change, so clients that already read the registry can see it.
    fn adopt_orphans(&mut self, withdrawn: OutputId, orphaned: &[WlSurface]) {
        self.assignments
            .retain(|_, assigned| *assigned != withdrawn);

        // Collect clients before looking up client data. Both operations acquire
        // the backend lock, so nesting them would deadlock.
        let backend = self.display.backend_handle();
        let mut connected = Vec::new();
        backend.with_all_clients(|client| connected.push(client));

        let mut reassigned = false;
        for client in connected {
            let Some(state) = backend
                .get_client_data(client)
                .ok()
                .and_then(|data| data.downcast_arc::<ClientState>().ok())
            else {
                continue;
            };
            if state.disconnected() || state.output() != Some(withdrawn) {
                continue;
            }
            state.assign(None);
            reassigned = true;
        }

        for surface in orphaned {
            let output = self.output_of(surface);
            self.outputs.enter(surface, output);
        }
        self.windows.move_to_output(withdrawn, DEFAULT_OUTPUT);

        if reassigned && let Err(error) = self.outputs.readvertise(&self.display, DEFAULT_OUTPUT) {
            warn!(%error, "could not re-advertise the default output");
        }
        self.rescale_output(DEFAULT_OUTPUT);
    }

    /// Updates surface scales, size limits, and toplevel configures together.
    /// Windows keep their committed size when it fits the new bounds and are
    /// clamped when it does not.
    pub(super) fn rescale_output(&mut self, output: OutputId) {
        for surface in self.outputs.surfaces_on(output) {
            self.send_surface_scale(&surface);
        }

        let bounds = self.output_bounds(output);
        for window in self.windows.on_output(output) {
            window.refresh_constraints(bounds);
            let size = logical_size(window.size());
            window.request_size(size, bounds);
        }
    }

    /// Returns the mode for `output`, falling back to the default output and then
    /// to the configured output mode.
    pub(super) fn mode_of(&self, output: OutputId) -> OutputMode {
        self.outputs
            .get(output)
            .or_else(|| self.outputs.get(DEFAULT_OUTPUT))
            .map_or(self.config.output, OutputEntry::mode)
    }

    pub(super) fn output_of(&self, surface: &WlSurface) -> OutputId {
        assigned_output(surface).unwrap_or(DEFAULT_OUTPUT)
    }

    /// Returns logical bounds for `output`, falling back to the default output and
    /// then to the configured output size.
    pub(super) fn output_bounds(&self, output: OutputId) -> Size<i32, Logical> {
        self.outputs
            .get(output)
            .or_else(|| self.outputs.get(DEFAULT_OUTPUT))
            .map_or_else(
                || logical_size(self.config.output.size),
                |entry| entry.logical_size(),
            )
    }

    /// Returns the logical bounds used to configure a surface's client.
    ///
    /// An unassigned client, or one whose assigned output is unavailable, uses
    /// the default output's bounds.
    pub(super) fn surface_bounds(&self, surface: &WlSurface) -> Size<i32, Logical> {
        self.output_bounds(self.output_of(surface))
    }

    /// Sends both scale representations. The matching logical size is sent
    /// separately as an xdg-toplevel configure. The fractional scale uses exact
    /// 120ths; the integer scale uses the ceiling for clients without the
    /// fractional-scale protocol.
    ///
    /// Smithay replays a preferred scale set before the client creates its
    /// `wp_fractional_scale_v1` object, so pre-setting it prevents the first
    /// frame from using the wrong scale.
    ///
    /// Smithay stores fractional-scale state in thread-affine surface data, so this
    /// method runs on the compositor thread alone.
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

    /// Assigns the surface's output before advertising its scale.
    pub(super) fn send_initial_surface_state(&mut self, surface: &WlSurface) {
        self.outputs.enter(surface, self.output_of(surface));
        self.send_surface_scale(surface);
    }
}

pub(crate) fn logical_size(size: PixelSize) -> Size<i32, Logical> {
    #[expect(
        clippy::cast_possible_wrap,
        reason = "a size beyond two billion pixels is not a mode any hardware or protocol carries"
    )]
    Size::new(size.width as i32, size.height as i32)
}

fn assigned_output(surface: &WlSurface) -> Option<OutputId> {
    surface.client()?.get_data::<ClientState>()?.output()
}
