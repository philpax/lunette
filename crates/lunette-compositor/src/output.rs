//! The virtual monitors lunette advertises, one `wl_output` global apiece.
//!
//! New work. WayVR advertises a single output for everything (`mod.rs:209`) and
//! clamps every window to its bounds, which means one scale factor for every
//! application and a client querying its display getting an answer unrelated to
//! the panel it is on. `docs/compositor.md` rejects that arrangement: Lua
//! creates the outputs, and a client is shown the ones it was assigned.
//!
//! # Why smithay's `Output` is not used
//!
//! `Output::create_global` (`smithay-0.7.0/src/wayland/output/mod.rs:201-211`)
//! has no filter hook, and `delegate_output!` routes
//! `GlobalDispatch<WlOutput, WlOutputData>` to `OutputManagerState`, whose
//! implementation never overrides `can_view`. Overriding it by hand is the
//! documented way to filter a global — but `can_view` is handed only a
//! `&WlOutputData`, whose `output` field is private
//! (`mod.rs:107-109`), so a hand-written implementation cannot tell which output
//! it is being asked about. There is no accessor, and the type has no `impl`
//! block at all.
//!
//! So the `wl_output` global is lunette's own, with a global data type that
//! names the output. `can_view` then answers from that identifier and the
//! client's assignment, and the filter is enforced at bind as well as at
//! advertisement.
//!
//! What that gives up is smithay's `Output`, which lunette used for six things:
//! `new`, `create_global`, `change_current_state`, `set_preferred`, `enter`, and
//! `leave`. All six are reimplemented here against the protocol directly. It
//! never advertised `zxdg_output_manager_v1` — nothing constructs an
//! `OutputManagerState` — so no xdg-output surface is lost with it.
//!
//! # Units
//!
//! A refresh rate is hertz in Lua and millihertz on the wire.
//! [`crate::protocol::RefreshRate`] is millihertz and the conversion happens
//! where Lua is read, so nothing below that boundary has to ask which unit it is
//! holding.

use std::{error::Error, fmt};

use smithay::{
    reexports::wayland_server::{
        DisplayHandle, Resource, Weak,
        backend::GlobalId,
        protocol::{wl_output, wl_output::WlOutput, wl_surface::WlSurface},
    },
    utils::{Logical, Size},
};
use tracing::{debug, warn};

use crate::{
    protocol::{OutputId, OutputMode, OutputScale, OutputSnapshot, PixelSize},
    state::CompositorState,
};

/// Every output lunette advertises, in the order they were created.
///
/// A `Vec` rather than a map, for the reason [`crate::seat::SeatRegistry`] is
/// one: the count is in the low single digits, it is walked far more often than
/// it is searched, and creation order is the order a client sees the globals
/// arrive in.
#[derive(Debug, Default)]
pub(crate) struct OutputRegistry {
    outputs: Vec<OutputEntry>,
}

impl OutputRegistry {
    /// Creates an output and advertises its `wl_output` global.
    ///
    /// The global is advertised to every client already connected as well as to
    /// every client that connects afterwards, so an output created after a
    /// client has settled still reaches it — filtered by
    /// [`CompositorState::can_view`] in both cases.
    ///
    /// # Errors
    ///
    /// Returns [`OutputError`] when the identifier is already in use. Two
    /// outputs sharing one identifier would make every later lookup answer for
    /// whichever was found first.
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

        let global = display.create_global::<CompositorState, WlOutput, _>(
            OUTPUT_VERSION,
            OutputGlobal { output: id },
        );
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

    /// Changes an output's mode and tells the clients that bound it.
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

    /// Withdraws an output's global and hands back the surfaces that were on it.
    ///
    /// The clients that had bound it keep their `wl_output` objects — a global
    /// being removed does not destroy the objects made from it — so each is told
    /// the output has left its own surfaces first. What the removal stops is a
    /// client binding it again.
    ///
    /// The surfaces are returned rather than dropped because they are now on no
    /// output at all, and something has to put them on one: `destroy_output`
    /// moves them to the default.
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
                // The same client check the other three paths make. Structurally
                // redundant since `enter` records a surface only against the
                // output its own client is shown, and kept because the cost of
                // it being wrong is not a protocol error a client can survive
                // but a backend abort that takes the compositor thread with it
                // (`wayland-backend/src/rs/server_impl/client.rs:194`).
                if surface.client().as_ref() == instance.client().as_ref() {
                    surface.leave(instance);
                }
            }
        }
        let orphaned: Vec<WlSurface> = entry.live_surfaces().collect();
        display.remove_global::<CompositorState>(entry.global);
        Ok(orphaned)
    }

    /// Withdraws an output's global and advertises a fresh one for it.
    ///
    /// The only way to re-evaluate [`CompositorState::can_view`] for a client
    /// that has already read the registry: it is consulted at advertisement and
    /// at bind and nowhere else, so a client whose assignment changed learns
    /// nothing until a global it has not seen appears. Clients that had bound
    /// the old global keep their `wl_output` objects and see a monitor
    /// unplugged and plugged back in, which `docs/compositor.md` records as the
    /// cost of changing an assignment.
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
        display.remove_global::<CompositorState>(stale);

        let global = display.create_global::<CompositorState, WlOutput, _>(
            OUTPUT_VERSION,
            OutputGlobal { output: id },
        );
        self.entry_mut(id)?.global = global;
        Ok(())
    }

    pub(crate) fn get(&self, id: OutputId) -> Option<&OutputEntry> {
        self.outputs.iter().find(|entry| entry.id == id)
    }

    /// The live surfaces on one output.
    ///
    /// No deduplication, because [`OutputRegistry::enter`] records a surface
    /// against exactly the output its client is shown and refuses a repeat.
    ///
    /// Collected rather than borrowed, so the caller may hold `&mut self` while
    /// it walks the result.
    pub(crate) fn surfaces_on(&self, id: OutputId) -> Vec<WlSurface> {
        self.get(id)
            .map(|entry| entry.live_surfaces().collect())
            .unwrap_or_default()
    }

    /// Every output, as the main thread reads them.
    pub(crate) fn snapshot(&self) -> Vec<OutputSnapshot> {
        self.outputs
            .iter()
            .map(|entry| OutputSnapshot {
                output: entry.id,
                mode: entry.mode,
            })
            .collect()
    }

    /// Sends a newly bound `wl_output` everything it is owed.
    ///
    /// Called from [`CompositorState`]'s `GlobalDispatch` implementation, which
    /// is the only thing that can produce one.
    pub(crate) fn bind(&mut self, id: OutputId, instance: &WlOutput) {
        let Ok(entry) = self.entry_mut(id) else {
            warn!(%id, "a client bound an output that no longer exists");
            return;
        };

        send_configuration(entry, instance, OutputName::Unsent);
        // Replayed rather than assumed to be unnecessary: a client may create a
        // surface before it binds the output, and a surface that is never told
        // which output it is on cannot pick a scale.
        for surface in entry.live_surfaces() {
            if surface.client().as_ref() == instance.client().as_ref() {
                surface.enter(instance);
            }
        }
        entry.instances.push(instance.clone());
    }

    /// Forgets a `wl_output` a client destroyed.
    ///
    /// The output is named rather than searched for, because the resource
    /// carries it: an entry destroyed in the same dispatch has already dropped
    /// its instances, and scanning every entry would be looking for something
    /// that can only ever be in one of them.
    pub(crate) fn unbind(&mut self, id: OutputId, instance: &WlOutput) {
        let Ok(entry) = self.entry_mut(id) else {
            return;
        };
        entry.instances.retain(|held| held != instance);
    }

    /// Tells a surface which output it is on.
    ///
    /// One output — the one its client is shown — rather than every output. The
    /// events would come out the same either way, because a client can only
    /// have bound what it was allowed to see, but the record would not: an entry
    /// holding surfaces belonging to clients that cannot see it is what makes a
    /// cross-client `wl_surface.leave` reachable from
    /// [`OutputRegistry::destroy`], which the backend answers by aborting rather
    /// than by raising a protocol error. Recording against the one output makes
    /// that pairing impossible rather than guarded against.
    ///
    /// An output that does not exist records nothing. The only caller derives
    /// the identifier from the client's assignment, which `assign_output`
    /// refuses to set to an output that was never created and `destroy_output`
    /// clears when one is withdrawn — so this is a defect rather than a case,
    /// and it is logged.
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

    /// Withdraws a surface from every output it was on.
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

/// One virtual monitor and the clients that have bound it.
#[derive(Debug)]
pub(crate) struct OutputEntry {
    id: OutputId,
    /// What clients see on `wl_output.name`, and how a client tells two outputs
    /// apart.
    name: String,
    mode: OutputMode,
    global: GlobalId,
    /// Every `wl_output` a client has bound for this output.
    instances: Vec<WlOutput>,
    /// Every surface on this output, which is every surface belonging to a
    /// client this output was assigned to and no others — see
    /// [`OutputRegistry::enter`]. Weak, because a surface is destroyed by its
    /// client and the registry must not be what keeps it alive.
    surfaces: Vec<Weak<WlSurface>>,
}

impl OutputEntry {
    /// The resolution, scale, and refresh rate this output is advertising.
    pub(crate) const fn mode(&self) -> OutputMode {
        self.mode
    }

    /// The mode in smithay's logical coordinate space, which is what a toplevel
    /// is configured in.
    pub(crate) fn logical_size(&self) -> Size<i32, Logical> {
        logical_size(self.mode)
    }

    /// The surfaces still alive, as resources.
    fn live_surfaces(&self) -> impl Iterator<Item = WlSurface> + '_ {
        self.surfaces.iter().filter_map(|held| held.upgrade().ok())
    }
}

/// Which output a `wl_output` global is for.
///
/// The whole reason this crate does not use `Output::create_global`: smithay's
/// own global data does not let a `can_view` implementation read the output back
/// out, and without that there is nothing to filter on.
#[derive(Debug)]
pub(crate) struct OutputGlobal {
    pub(crate) output: OutputId,
}

/// Which output a bound `wl_output` is for.
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

/// Why an output could not be created, reconfigured, or destroyed.
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

/// The `wl_output` version lunette advertises.
///
/// Four, which is what smithay's own global offers and the version that carries
/// `name` and `description`. A client tells two outputs apart by name, and
/// without it a configuration with several outputs is unaddressable from the
/// client's side.
const OUTPUT_VERSION: u32 = 4;

/// What a client is told lunette's make is.
const OUTPUT_MAKE: &str = "lunette";

/// What a client is told the model is.
const OUTPUT_MODEL: &str = "virtual display";

/// Whether one bound `wl_output` has already been told its name.
///
/// `wayland.xml` on `wl_output.name`: "This event is only sent once per output
/// object, and the name does not change over the lifetime of the wl_output
/// global." Every other event in the set may repeat, and `description` is
/// explicitly allowed to — so a mode change re-sends everything but this.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum OutputName {
    /// The instance was just bound and is owed its name.
    Unsent,
    /// The instance already carries its name, and repeating it is a conformance
    /// violation.
    Sent,
}

/// Sends an output's state to one bound `wl_output`.
///
/// The order is the protocol's: the properties, then `done`. A client that acts
/// on a geometry it has not been told is done with will re-lay-out again a
/// moment later.
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

/// The integer scale `wl_output.scale` carries.
///
/// The ceiling of the advertised scale, never below one. A client rendering at a
/// fractional scale asks for the buffer scale it wants through
/// `wp_fractional_scale_v1` and `wp_viewporter`; this is the whole-number answer
/// the protocol has had since version 2, and rounding it down would tell a
/// client on a 1.5 scale that its monitor is unscaled.
///
/// The same number rides on `wl_surface.preferred_buffer_scale`, which is what
/// a client too old for `wp_fractional_scale_v1` renders at, so
/// [`crate::state`] reaches for this too.
pub(crate) fn integer_scale(scale: OutputScale) -> i32 {
    #[expect(
        clippy::cast_possible_truncation,
        reason = "OutputScale is finite and positive, and a scale beyond two billion is not one any \
                  display has"
    )]
    let ceiling = scale.get().ceil() as i32;
    ceiling.max(1)
}

/// A mode in smithay's logical coordinate space.
///
/// Divided by the fractional scale rather than the integer one: an output at
/// scale 1.5 is 1707 logical pixels wide at 2560 physical, and configuring its
/// toplevels to 1280 would waste a quarter of the panel.
fn logical_size(mode: OutputMode) -> Size<i32, Logical> {
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

/// A plausible physical size in millimetres for a mode at a scale.
///
/// Derived rather than fixed. A client divides the resolution by the physical
/// size to guess a DPI, and a constant physical size would make that guess wrong
/// for every mode but one — a 3840-wide panel would report twice the density of
/// a 1920-wide one on the same virtual monitor. Deriving it from the logical
/// size at 96 dpi makes the guess agree with the scale lunette advertises.
fn physical_size(size: PixelSize, scale: f64) -> PhysicalSize {
    /// Millimetres per logical pixel at the density the protocol treats as
    /// unscaled.
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

/// A physical size in millimetres, which is the unit `wl_output.geometry`
/// carries.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct PhysicalSize {
    width: i32,
    height: i32,
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
        // The property that matters: two modes at the same scale report the same
        // pixels per millimetre, so a client's DPI guess does not change with the
        // resolution lunette picked.
        let small = physical_size(PixelSize::new(1920, 1080), 1.0);
        let large = physical_size(PixelSize::new(3840, 2160), 1.0);

        assert_eq!(large.width, small.width * 2);
        assert_eq!(large.height, small.height * 2);
    }

    #[test]
    fn physical_size_shrinks_with_scale() {
        // A scaled output is the same panel showing more pixels, so its physical
        // size is smaller for the same resolution.
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
        assert_eq!(logical_size(mode(2560, 1440, 1.0)), Size::new(2560, 1440));
        assert_eq!(logical_size(mode(2560, 1440, 2.0)), Size::new(1280, 720));
        // The case the integer scale would get wrong: at 1.5 the ceiling is two,
        // and dividing by it would throw away a quarter of the panel.
        assert_eq!(logical_size(mode(2560, 1440, 1.5)), Size::new(1707, 960));
    }

    #[test]
    fn logical_size_is_never_zero() {
        assert_eq!(logical_size(mode(1, 1, 8.0)), Size::new(1, 1));
    }
}
