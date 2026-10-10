//! The virtual monitors lunette advertises as `wl_output` globals.
//!
//! Each client sees only outputs assigned to it. The custom global data carries
//! the output identifier required by the per-client filter at advertisement and
//! bind time.
//!
//! The registry and its Wayland resources are accessed on the compositor thread.
//!
//! Lua supplies refresh rates in hertz; [`crate::protocol::RefreshRate`] stores
//! millihertz on the wire.
//!
//! The output commands on [`Application`] propagate an output's mode and scale
//! to the clients that see it: the surface scales and the toplevel configures.

use std::{error::Error, fmt};

use smithay::{
    reexports::wayland_server::{
        Client, DataInit, Dispatch, DisplayHandle, GlobalDispatch, New, Resource, Weak,
        backend::{ClientId, GlobalId},
        protocol::{wl_output, wl_output::WlOutput, wl_surface::WlSurface},
    },
    utils::{Logical, Size, Transform},
    wayland::{
        compositor::{send_surface_state, with_states},
        fractional_scale::with_fractional_scale,
    },
};
use tracing::{debug, info, warn};

use crate::{
    config::DEFAULT_OUTPUT,
    protocol::{OutputId, OutputMode, OutputScale, OutputSnapshot, PixelSize},
    wayvr::comp::{Application, ClientState},
};

/// Outputs in creation order; advertisement follows the same order.
#[derive(Debug, Default)]
pub(crate) struct OutputRegistry {
    outputs: Vec<OutputEntry>,
}

impl OutputRegistry {
    /// Advertises the output to existing and future clients permitted to see it.
    ///
    /// # Errors
    ///
    /// Returns [`OutputError`] when the identifier is already in use.
    pub(crate) fn create(
        &mut self,
        display: &DisplayHandle,
        id: OutputId,
        mode: OutputMode,
    ) -> Result<(), OutputError> {
        if self.get(id).is_some() {
            return Err(OutputError {
                output: id,
                kind: OutputErrorKind::DuplicateId,
            });
        }

        let global = display
            .create_global::<Application, WlOutput, _>(OUTPUT_VERSION, OutputGlobal { output: id });
        self.outputs.push(OutputEntry {
            id,
            name: format!("lunette-{}", id.get()),
            mode,
            global,
            instances: Vec::new(),
            surfaces: Vec::new(),
        });
        Ok(())
    }

    /// Changes the mode and resends the output configuration to bound clients.
    /// The compositor then sends matching surface-scale and toplevel-configure
    /// updates from the new mode.
    ///
    /// # Errors
    ///
    /// Returns [`OutputError`] when no output has that identifier.
    pub(crate) fn reconfigure(
        &mut self,
        id: OutputId,
        mode: OutputMode,
    ) -> Result<(), OutputError> {
        let entry = self.entry_mut(id)?;
        if entry.mode == mode {
            return Ok(());
        }

        entry.mode = mode;
        for instance in &entry.instances {
            send_configuration(entry, instance, OutputName::Sent);
        }
        Ok(())
    }

    /// Sends leave events to bound clients before withdrawing the global, then
    /// returns live surfaces for reassignment. Removing a global does not destroy
    /// its bound `wl_output` objects.
    ///
    /// # Errors
    ///
    /// Returns [`OutputError`] when no output has that identifier.
    pub(crate) fn destroy(
        &mut self,
        display: &DisplayHandle,
        id: OutputId,
    ) -> Result<Vec<WlSurface>, OutputError> {
        let index = self
            .outputs
            .iter()
            .position(|entry| entry.id == id)
            .ok_or(OutputError {
                output: id,
                kind: OutputErrorKind::Unknown,
            })?;

        let entry = self.outputs.remove(index);
        for instance in &entry.instances {
            for surface in entry.live_surfaces() {
                // A shared output can hold resources from several clients. Pair
                // each surface with an instance from the same client; a
                // cross-client leave aborts the compositor thread in the
                // backend, and no protocol error is reported.
                if surface.client().as_ref() == instance.client().as_ref() {
                    surface.leave(instance);
                }
            }
        }
        let orphaned: Vec<WlSurface> = entry.live_surfaces().collect();
        display.remove_global::<Application>(entry.global);
        Ok(orphaned)
    }

    /// Removes and recreates the registry global so clients with changed
    /// assignments are filtered again. Existing bindings remain on their old
    /// resources; clients observe the registry change as a monitor removal
    /// followed by a new advertisement.
    ///
    /// # Errors
    ///
    /// Returns [`OutputError`] when no output has that identifier.
    pub(crate) fn readvertise(
        &mut self,
        display: &DisplayHandle,
        id: OutputId,
    ) -> Result<(), OutputError> {
        let stale = self.entry_mut(id)?.global.clone();
        display.remove_global::<Application>(stale);

        let global = display
            .create_global::<Application, WlOutput, _>(OUTPUT_VERSION, OutputGlobal { output: id });
        self.entry_mut(id)?.global = global;
        Ok(())
    }

    pub(crate) fn get(&self, id: OutputId) -> Option<&OutputEntry> {
        self.outputs.iter().find(|entry| entry.id == id)
    }

    pub(crate) fn surfaces_on(&self, id: OutputId) -> Vec<WlSurface> {
        self.get(id)
            .map(|entry| entry.live_surfaces().collect())
            .unwrap_or_default()
    }

    pub(crate) fn snapshot(&self) -> Vec<OutputSnapshot> {
        self.outputs
            .iter()
            .map(|entry| OutputSnapshot {
                output: entry.id,
                mode: entry.mode,
            })
            .collect()
    }

    /// Sends configuration and existing surfaces' enter events for this client.
    pub(crate) fn bind(&mut self, id: OutputId, instance: &WlOutput) {
        let Ok(entry) = self.entry_mut(id) else {
            warn!(%id, "a client bound an output that no longer exists");
            return;
        };

        send_configuration(entry, instance, OutputName::Unsent);
        // A client may create a surface before binding the output, so replay its
        // enter event when the output is bound.
        for surface in entry.live_surfaces() {
            if surface.client().as_ref() == instance.client().as_ref() {
                surface.enter(instance);
            }
        }
        entry.instances.push(instance.clone());
    }

    pub(crate) fn unbind(&mut self, id: OutputId, instance: &WlOutput) {
        let Ok(entry) = self.entry_mut(id) else {
            return;
        };
        entry.instances.retain(|held| held != instance);
    }

    /// Records the surface on its assigned output and sends an enter event to
    /// instances belonging to the same client. An unknown output is logged and
    /// ignored.
    pub(crate) fn enter(&mut self, surface: &WlSurface, id: OutputId) {
        let Ok(entry) = self.entry_mut(id) else {
            warn!(%id, "a surface was placed on an output that does not exist");
            return;
        };

        entry.surfaces.retain(|held| held.is_alive());
        let weak = surface.downgrade();
        if entry.surfaces.contains(&weak) {
            return;
        }
        entry.surfaces.push(weak);

        for instance in &entry.instances {
            if instance.client().as_ref() == surface.client().as_ref() {
                surface.enter(instance);
            }
        }
    }

    pub(crate) fn leave(&mut self, surface: &WlSurface) {
        let weak = surface.downgrade();
        for entry in &mut self.outputs {
            if !entry.surfaces.iter().any(|held| held == &weak) {
                continue;
            }
            entry
                .surfaces
                .retain(|held| held != &weak && held.is_alive());

            for instance in &entry.instances {
                if instance.client().as_ref() == surface.client().as_ref() {
                    surface.leave(instance);
                }
            }
        }
    }

    fn entry_mut(&mut self, id: OutputId) -> Result<&mut OutputEntry, OutputError> {
        self.outputs
            .iter_mut()
            .find(|entry| entry.id == id)
            .ok_or(OutputError {
                output: id,
                kind: OutputErrorKind::Unknown,
            })
    }
}

#[derive(Debug)]
pub(crate) struct OutputEntry {
    id: OutputId,
    /// Stable name sent in `wl_output.name`.
    name: String,
    mode: OutputMode,
    global: GlobalId,
    instances: Vec<WlOutput>,
    /// Weak references; the registry does not keep client-owned surfaces alive.
    surfaces: Vec<Weak<WlSurface>>,
}

impl OutputEntry {
    pub(crate) const fn mode(&self) -> OutputMode {
        self.mode
    }

    /// Returns the logical bounds used for toplevel configuration.
    pub(crate) fn logical_size(&self) -> Size<i32, Logical> {
        mode_logical_size(self.mode)
    }

    fn live_surfaces(&self) -> impl Iterator<Item = WlSurface> + '_ {
        self.surfaces.iter().filter_map(|held| held.upgrade().ok())
    }
}

/// Carries the output identity used by `can_view` at advertisement and bind time.
#[derive(Debug)]
pub(crate) struct OutputGlobal {
    pub(crate) output: OutputId,
}

#[derive(Debug)]
pub(crate) struct OutputResource {
    output: OutputId,
}

impl OutputResource {
    pub(crate) const fn new(output: OutputId) -> Self {
        Self { output }
    }

    pub(crate) const fn output(&self) -> OutputId {
        self.output
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct OutputError {
    output: OutputId,
    kind: OutputErrorKind,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum OutputErrorKind {
    DuplicateId,
    Unknown,
}

impl fmt::Display for OutputError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self.kind {
            OutputErrorKind::DuplicateId => {
                write!(f, "output: {} already exists", self.output)
            }
            OutputErrorKind::Unknown => write!(f, "output: {} does not exist", self.output),
        }
    }
}

impl Error for OutputError {}

impl Application {
    /// Rejects a duplicate identifier. Replacing the existing output would
    /// silently reconfigure its bound clients.
    pub(crate) fn create_output(&mut self, output: OutputId, mode: OutputMode) {
        match self.outputs.create(&self.display_handle, output, mode) {
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
    pub(crate) fn reconfigure_output(&mut self, output: OutputId, mode: OutputMode) {
        match self.outputs.reconfigure(output, mode) {
            Ok(()) => {
                self.rescale_output(output);
                self.touch();
            }
            Err(error) => warn!(%error, "could not reconfigure an output"),
        }
    }

    /// Refuses to withdraw the default output because unassigned clients use it.
    pub(crate) fn destroy_output(&mut self, output: OutputId) {
        if output == DEFAULT_OUTPUT {
            debug!("the default output cannot be destroyed; a client assigned none needs it");
            return;
        }

        let orphaned = match self.outputs.destroy(&self.display_handle, output) {
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
        let backend = self.display_handle.backend_handle();
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

        if reassigned
            && let Err(error) = self
                .outputs
                .readvertise(&self.display_handle, DEFAULT_OUTPUT)
        {
            warn!(%error, "could not re-advertise the default output");
        }
        self.rescale_output(DEFAULT_OUTPUT);
    }

    /// Updates surface scales, size limits, and toplevel configures together.
    /// Windows keep their committed size when it fits the new bounds and are
    /// clamped when it does not.
    pub(crate) fn rescale_output(&mut self, output: OutputId) {
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
    pub(crate) fn mode_of(&self, output: OutputId) -> OutputMode {
        self.outputs
            .get(output)
            .or_else(|| self.outputs.get(DEFAULT_OUTPUT))
            .map_or(self.config.output, OutputEntry::mode)
    }

    pub(crate) fn output_of(&self, surface: &WlSurface) -> OutputId {
        assigned_output(surface).unwrap_or(DEFAULT_OUTPUT)
    }

    /// Returns logical bounds for `output`, falling back to the default output and
    /// then to the configured output size.
    pub(crate) fn output_bounds(&self, output: OutputId) -> Size<i32, Logical> {
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
    pub(crate) fn surface_bounds(&self, surface: &WlSurface) -> Size<i32, Logical> {
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
    pub(crate) fn send_surface_scale(&self, surface: &WlSurface) {
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

/// `wl_output` version 4, which includes the stable name and description events.
const OUTPUT_VERSION: u32 = 4;

const OUTPUT_MAKE: &str = "lunette";

const OUTPUT_MODEL: &str = "virtual display";

/// Tracks whether the bound resource has received its name event. The protocol
/// permits the name once per resource, while other configuration events repeat.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum OutputName {
    Unsent,
    Sent,
}

/// Sends geometry, mode, scale, name, and description in protocol order,
/// followed by `done` when supported. A bound resource receives its name only
/// once; later configurations resend the other properties.
fn send_configuration(entry: &OutputEntry, instance: &WlOutput, name: OutputName) {
    let physical = physical_size(entry.mode.size, entry.mode.scale.get());
    instance.geometry(
        0,
        0,
        physical.width,
        physical.height,
        wl_output::Subpixel::Unknown,
        OUTPUT_MAKE.to_owned(),
        OUTPUT_MODEL.to_owned(),
        wl_output::Transform::Normal,
    );

    let size = entry.mode.size;
    #[expect(
        clippy::cast_possible_wrap,
        reason = "a mode beyond two billion pixels or a refresh beyond the sign bit is not one any \
                  hardware or protocol carries"
    )]
    instance.mode(
        wl_output::Mode::Current | wl_output::Mode::Preferred,
        size.width as i32,
        size.height as i32,
        entry.mode.refresh.millihertz() as i32,
    );

    if instance.version() >= 2 {
        instance.scale(integer_scale(entry.mode.scale));
    }
    if instance.version() >= 4 {
        if name == OutputName::Unsent {
            instance.name(entry.name.clone());
        }
        instance.description(format!(
            "{OUTPUT_MAKE} {OUTPUT_MODEL} {} ({size})",
            entry.id.get()
        ));
    }
    if instance.version() >= 2 {
        instance.done();
    } else {
        debug!(
            output = entry.name,
            "a client bound wl_output at version 1, which has no done event"
        );
    }
}

/// Returns the whole-number scale for `wl_output.scale` and
/// `wl_surface.preferred_buffer_scale`. The ceiling, never below one, preserves
/// density for clients that do not use fractional scaling.
pub(crate) fn integer_scale(scale: OutputScale) -> i32 {
    #[expect(
        clippy::cast_possible_truncation,
        reason = "OutputScale is finite and positive, and a scale beyond two billion is not one any \
                  display has"
    )]
    let ceiling = scale.get().ceil() as i32;
    ceiling.max(1)
}

/// Returns logical bounds by dividing the physical mode by its fractional
/// scale, not by the whole-number protocol scale.
fn mode_logical_size(mode: OutputMode) -> Size<i32, Logical> {
    let logical = |pixels: u32| {
        #[expect(
            clippy::cast_possible_truncation,
            reason = "the quotient of a pixel count by a positive scale is far below the sign bit, \
                      and it is clamped to at least one"
        )]
        let logical = (f64::from(pixels) / mode.scale.get()).round() as i32;
        logical.max(1)
    };

    Size::new(logical(mode.size.width), logical(mode.size.height))
}

/// Returns the physical size in millimetres for `wl_output.geometry`, derived
/// from logical dimensions at 96 dpi so a client's DPI estimate reflects the
/// advertised scale across modes.
fn physical_size(size: PixelSize, scale: f64) -> PhysicalSize {
    const MILLIMETRES_PER_PIXEL: f64 = 25.4 / 96.0;

    let millimetres = |pixels: u32| {
        let logical = f64::from(pixels) / scale;
        #[expect(
            clippy::cast_possible_truncation,
            reason = "the value is far below the sign bit for any mode a client can ask for, and \
                      it is clamped to at least one millimetre"
        )]
        let millimetres = (logical * MILLIMETRES_PER_PIXEL).round() as i32;
        millimetres.max(1)
    };

    PhysicalSize {
        width: millimetres(size.width),
        height: millimetres(size.height),
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct PhysicalSize {
    width: i32,
    height: i32,
}

impl GlobalDispatch<WlOutput, OutputGlobal> for Application {
    fn bind(
        state: &mut Self,
        _display: &DisplayHandle,
        _client: &Client,
        resource: New<WlOutput>,
        global: &OutputGlobal,
        data_init: &mut DataInit<'_, Self>,
    ) {
        let instance = data_init.init(resource, OutputResource::new(global.output));
        state.outputs.bind(global.output, &instance);
    }

    /// The backend calls this predicate both when advertising globals and when
    /// binding them. The bind-time check prevents a client from binding a global
    /// it was not shown; both checks are required.
    ///
    /// `can_view` receives the client but no compositor state, so the assignment
    /// lives in [`ClientState`], not in compositor state keyed by `ClientId`.
    fn can_view(client: Client, global: &OutputGlobal) -> bool {
        client
            .get_data::<ClientState>()
            .is_some_and(|state| state.sees_output(global.output))
    }
}

impl Dispatch<WlOutput, OutputResource> for Application {
    /// `wl_output` has one request, `release`, and it is a destructor. The
    /// backend destroys the object and calls [`Dispatch::destroyed`], so there is
    /// nothing to do here.
    fn request(
        _state: &mut Self,
        _client: &Client,
        _resource: &WlOutput,
        _request: wl_output::Request,
        _data: &OutputResource,
        _display: &DisplayHandle,
        _data_init: &mut DataInit<'_, Self>,
    ) {
    }

    fn destroyed(state: &mut Self, _client: ClientId, resource: &WlOutput, data: &OutputResource) {
        state.outputs.unbind(data.output(), resource);
    }
}

#[cfg(test)]
#[expect(
    clippy::expect_used,
    reason = "a failed expectation is how a test reports a failure; the ban is on production code"
)]
mod tests {
    use super::*;
    use crate::protocol::RefreshRate;

    fn mode(width: u32, height: u32, scale: f64) -> OutputMode {
        OutputMode {
            size: PixelSize::new(width, height),
            scale: OutputScale::new(scale).expect("the test names a positive scale"),
            refresh: RefreshRate::from_millihertz(60_000),
        }
    }

    #[test]
    fn physical_size_holds_density_across_modes() {
        let small = physical_size(PixelSize::new(1920, 1080), 1.0);
        let large = physical_size(PixelSize::new(3840, 2160), 1.0);

        assert_eq!(large.width, small.width * 2);
        assert_eq!(large.height, small.height * 2);
    }

    #[test]
    fn physical_size_shrinks_with_scale() {
        let unscaled = physical_size(PixelSize::new(1920, 1080), 1.0);
        let scaled = physical_size(PixelSize::new(1920, 1080), 2.0);

        assert_eq!(scaled.width * 2, unscaled.width);
    }

    #[test]
    fn physical_size_is_never_zero() {
        let tiny = physical_size(PixelSize::new(1, 1), 4.0);

        assert_eq!(
            tiny,
            PhysicalSize {
                width: 1,
                height: 1
            }
        );
    }

    #[test]
    fn integer_scale_is_the_ceiling_and_never_below_one() {
        let scale = |value: f64| {
            integer_scale(OutputScale::new(value).expect("the test names a positive scale"))
        };

        assert_eq!(scale(1.0), 1);
        assert_eq!(scale(1.25), 2);
        assert_eq!(scale(1.5), 2);
        assert_eq!(scale(2.0), 2);
        assert_eq!(scale(0.5), 1);
    }

    #[test]
    fn logical_size_divides_by_the_fractional_scale() {
        assert_eq!(
            mode_logical_size(mode(2560, 1440, 1.0)),
            Size::new(2560, 1440)
        );
        assert_eq!(
            mode_logical_size(mode(2560, 1440, 2.0)),
            Size::new(1280, 720)
        );
        assert_eq!(
            mode_logical_size(mode(2560, 1440, 1.5)),
            Size::new(1707, 960)
        );
    }

    #[test]
    fn logical_size_is_never_zero() {
        assert_eq!(mode_logical_size(mode(1, 1, 8.0)), Size::new(1, 1));
    }
}
