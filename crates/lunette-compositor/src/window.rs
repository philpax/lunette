//! Ported from WayVR (https://github.com/wayvr-org/wayvr), backend/wayvr/window.rs and backend/wayvr/mod.rs (the size-constraint fragment at :368-386), at commit 98f800c644719d3f23a20e50bd3237c29a8082cb.
//! Copyright (c) the WayVR authors (galister, oo8dev). Licensed GPL-3.0-only.
//!
//! The toplevels lunette knows about, and the sizes it configures them to.
//!
//! A [`Window`] is a toplevel that has committed content. A toplevel that has
//! not is tracked but not reported: a window with nothing in it has no pixels
//! to draw and no size to place, and reporting one would make every consumer
//! handle a case that resolves itself a frame later.
//!
//! The sizing rules are WayVR's (`window.rs:50-92`), with the clamping
//! extracted into [`clamp_configure_size`] so it can be tested as the pure
//! function it is. The rule that matters: a configure is only sent when the
//! clamped size differs from the one already pending, because a client that is
//! configured on every tick spends its time reallocating instead of drawing.
//!
//! Two things upstream has that are not here. The `wayvr_ipc` packet
//! conversions (`window.rs:164-174`) belong to WayVR's control protocol;
//! lunette's control surface is `lunctl`, and it does not speak that protocol.
//! `Rc<ToplevelSurface>` (`:19`) is a plain `ToplevelSurface`: it is itself
//! `Clone` and cheap, so the wrapper bought nothing and cost thread affinity.
//!
//! The hover and focus pair upstream keeps here (`window.rs:109-119`) is in
//! [`crate::seat`] instead. One per compositor is what makes the off hand steal
//! hover from the main hand, and it is a property of a seat rather than of the
//! window set.
//!
//! `time.rs` is folded in too, but not here — its one function has one caller,
//! `CompositorState::millis` in [`crate::state`], and that is where it lives.

use smithay::{
    utils::{Logical, Size},
    wayland::{
        compositor::with_states,
        shell::xdg::{SurfaceCachedState, ToplevelSurface},
    },
};
use tracing::debug;

use crate::protocol::{
    ContentType, OutputId, PixelSize, ProcessId, SinkId, SurfaceId, ToplevelStates, WindowId,
    WindowSnapshot,
};

/// The smallest size lunette will configure a window to.
///
/// Zero is a legal thing for a client to ask for and a useless thing to grant:
/// a surface of no width has no pixels, and some toolkits divide by their own
/// dimensions.
const SMALLEST: i32 = 1;

/// Every toplevel lunette is tracking, in the order they were created.
///
/// A `Vec` rather than a map: it is walked far more often than it is searched,
/// and the count is in the tens. WayVR uses a slotmap for the generational
/// handle, which lunette gets from [`WindowId`] never being reused instead.
#[derive(Debug, Default)]
pub(crate) struct WindowManager {
    windows: Vec<Window>,
    minted: u64,
}

impl WindowManager {
    /// Starts tracking a toplevel, before it has any content.
    pub(crate) fn insert(
        &mut self,
        toplevel: ToplevelSurface,
        surface: SurfaceId,
        process: Option<ProcessId>,
        output: OutputId,
        bounds: Size<i32, Logical>,
    ) -> WindowId {
        self.minted += 1;
        let raw = self.minted;
        const NEVER_ZERO: &str =
            "the counter starts at one and only increases, so it is never zero";
        let id = WindowId::new(raw).unwrap_or_else(|| unreachable!("{NEVER_ZERO}"));
        let sink = SinkId::new(raw).unwrap_or_else(|| unreachable!("{NEVER_ZERO}"));

        let (min_size, max_size) = size_constraints(&toplevel, bounds);

        self.windows.push(Window {
            id,
            sink,
            surface,
            process,
            output,
            toplevel,
            title: None,
            app_id: None,
            size: PixelSize::default(),
            bounds,
            min_size,
            max_size,
            pending_configure_size: None,
            states: ToplevelStates::new(),
            content_type: ContentType::None,
            mapped: false,
        });
        id
    }

    /// Stops tracking a toplevel, returning what was removed.
    pub(crate) fn remove(&mut self, toplevel: &ToplevelSurface) -> Option<Window> {
        let index = self.index_of(toplevel)?;
        Some(self.windows.remove(index))
    }

    pub(crate) fn get(&self, id: WindowId) -> Option<&Window> {
        self.windows.iter().find(|window| window.id == id)
    }

    pub(crate) fn get_mut(&mut self, id: WindowId) -> Option<&mut Window> {
        self.windows.iter_mut().find(|window| window.id == id)
    }

    pub(crate) fn by_sink(&self, sink: SinkId) -> Option<&Window> {
        self.windows.iter().find(|window| window.sink == sink)
    }

    pub(crate) fn by_surface(&self, surface: SurfaceId) -> Option<&Window> {
        self.windows.iter().find(|window| window.surface == surface)
    }

    pub(crate) fn by_surface_mut(&mut self, surface: SurfaceId) -> Option<&mut Window> {
        self.windows
            .iter_mut()
            .find(|window| window.surface == surface)
    }

    pub(crate) fn by_toplevel_mut(&mut self, toplevel: &ToplevelSurface) -> Option<&mut Window> {
        let index = self.index_of(toplevel)?;
        self.windows.get_mut(index)
    }

    /// The windows that have content, which are the ones worth reporting.
    pub(crate) fn mapped(&self) -> impl Iterator<Item = &Window> {
        self.windows.iter().filter(|window| window.mapped)
    }

    /// Every window shown on one output, including the ones not yet mapped.
    ///
    /// Unmapped windows are included because the thing this exists for is
    /// reconfiguring an output's windows after its mode changed, and a toplevel
    /// still waiting to attach its first buffer is the one that most wants the
    /// new size before it does.
    pub(crate) fn on_output(&mut self, output: OutputId) -> impl Iterator<Item = &mut Window> {
        self.windows
            .iter_mut()
            .filter(move |window| window.output == output)
    }

    /// Moves every window on one output to another.
    ///
    /// For an output being withdrawn. A window's output is what its bounds are
    /// clamped against and what the snapshot reports, so one left naming an
    /// output that no longer exists reports a monitor Lua cannot look up and is
    /// reconfigured by nothing when the surviving output's mode changes.
    pub(crate) fn move_to_output(&mut self, from: OutputId, to: OutputId) {
        for window in &mut self.windows {
            if window.output == from {
                window.output = to;
            }
        }
    }

    fn index_of(&self, toplevel: &ToplevelSurface) -> Option<usize> {
        self.windows
            .iter()
            .position(|window| &window.toplevel == toplevel)
    }
}

/// One toplevel and everything lunette knows about it.
#[derive(Debug)]
pub(crate) struct Window {
    id: WindowId,
    sink: SinkId,
    surface: SurfaceId,
    process: Option<ProcessId>,
    /// The output this window is shown on, which is the output its client was
    /// assigned or the default one when it was assigned none.
    output: OutputId,
    toplevel: ToplevelSurface,
    title: Option<String>,
    app_id: Option<String>,
    /// The size the client last committed. Never the size it was last asked
    /// for: a client resizes at its own pace, and reporting the request would
    /// make the snapshot describe a state that does not exist yet.
    size: PixelSize,
    bounds: Size<i32, Logical>,
    min_size: Size<i32, Logical>,
    max_size: Size<i32, Logical>,
    /// The size of the configure the client has not yet answered.
    pending_configure_size: Option<Size<i32, Logical>>,
    states: ToplevelStates,
    /// What the client last said it is drawing. A hint, double-buffered by the
    /// protocol, so it is read at commit alongside the buffer.
    content_type: ContentType,
    /// Whether content has ever been committed.
    mapped: bool,
}

impl Window {
    pub(crate) const fn id(&self) -> WindowId {
        self.id
    }

    pub(crate) const fn toplevel(&self) -> &ToplevelSurface {
        &self.toplevel
    }

    /// The output this window is configured against.
    pub(crate) const fn output(&self) -> OutputId {
        self.output
    }

    pub(crate) const fn is_mapped(&self) -> bool {
        self.mapped
    }

    /// The size the client last committed, which is the window's client area
    /// for the purposes of hit testing.
    pub(crate) const fn size(&self) -> PixelSize {
        self.size
    }

    pub(crate) fn title(&self) -> Option<&str> {
        self.title.as_deref()
    }

    /// Records a new title, reporting whether it changed.
    pub(crate) fn set_title(&mut self, title: Option<String>) -> bool {
        if self.title == title {
            return false;
        }
        self.title = title;
        true
    }

    /// Records a new app id, reporting whether it changed.
    pub(crate) fn set_app_id(&mut self, app_id: Option<String>) -> bool {
        if self.app_id == app_id {
            return false;
        }
        self.app_id = app_id;
        true
    }

    pub(crate) fn set_state(&mut self, state: crate::protocol::ToplevelState, held: bool) -> bool {
        if held {
            self.states.insert(state)
        } else {
            self.states.remove(&state)
        }
    }

    /// Re-reads the client's own size limits, which it may change at any time.
    pub(crate) fn refresh_constraints(&mut self, bounds: Size<i32, Logical>) {
        self.bounds = bounds;
        let (min_size, max_size) = size_constraints(&self.toplevel, bounds);
        self.min_size = min_size;
        self.max_size = max_size;
    }

    /// Configures the window to a size within its own limits.
    ///
    /// Nothing is sent when the clamped size is the one already pending. A
    /// client configured on every tick spends its time reallocating buffers
    /// rather than drawing into them.
    pub(crate) fn request_size(&mut self, size: Size<i32, Logical>, bounds: Size<i32, Logical>) {
        let clamped = clamp_configure_size(size, self.min_size, self.max_size, bounds);

        if self.pending_configure_size == Some(clamped) {
            return;
        }

        self.toplevel.with_pending_state(|state| {
            state.bounds = Some(bounds);
            state.size = Some(clamped);
        });
        self.toplevel.send_configure();

        self.bounds = bounds;
        self.pending_configure_size = Some(clamped);
    }

    /// Records the size the client actually committed.
    ///
    /// Returns what changed, which is what decides whether a snapshot is worth
    /// republishing and whether the window has just appeared.
    pub(crate) fn remember_committed_size(&mut self, size: PixelSize) -> SizeChange {
        let size = PixelSize::new(size.width.max(1), size.height.max(1));
        let change = SizeChange {
            mapped: !self.mapped,
            resized: self.size != size,
        };

        self.size = size;
        self.mapped = true;
        self.pending_configure_size = None;
        change
    }

    /// Marks the window unmapped, as a commit that removes the buffer does.
    pub(crate) fn unmap(&mut self) -> bool {
        let was_mapped = self.mapped;
        self.mapped = false;
        self.pending_configure_size = None;
        was_mapped
    }

    pub(crate) fn snapshot(&self) -> WindowSnapshot {
        WindowSnapshot {
            window: self.id,
            surface: self.surface,
            sink: self.sink,
            process: self.process,
            output: self.output,
            title: self.title.clone(),
            app_id: self.app_id.clone(),
            size: self.size,
            min_size: Some(pixel_size(self.min_size)),
            max_size: Some(pixel_size(self.max_size)),
            // Transient-for is tracked from `parent_changed`, which arrives in
            // the phase that has something to do with it.
            parent: None,
            states: self.states.clone(),
            content_type: self.content_type,
        }
    }

    /// Records what the client says it is drawing, reporting whether it
    /// changed.
    pub(crate) fn remember_content_type(&mut self, content_type: ContentType) -> bool {
        let changed = self.content_type != content_type;
        self.content_type = content_type;
        changed
    }
}

/// What `remember_committed_size` observed.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct SizeChange {
    /// The window had no content before this commit.
    pub(crate) mapped: bool,
    /// The committed size differs from the previous one.
    pub(crate) resized: bool,
}

impl SizeChange {
    /// Whether the snapshot needs republishing because of this commit.
    pub(crate) const fn is_visible(self) -> bool {
        self.mapped || self.resized
    }
}

/// Brings a requested size inside the client's limits and the output's.
///
/// Ported from `window.rs:50-66`. The order is deliberate and is the part worth
/// stating: the minimum is clamped into the bounds first, the maximum is then
/// clamped to be at least the minimum, and only then is the request clamped
/// between them. A client whose minimum exceeds the output — which happens, and
/// is not a protocol error — gets the output's size rather than an inverted
/// range.
#[must_use]
pub(crate) fn clamp_configure_size(
    size: Size<i32, Logical>,
    min_size: Size<i32, Logical>,
    max_size: Size<i32, Logical>,
    bounds: Size<i32, Logical>,
) -> Size<i32, Logical> {
    let bounds: Size<i32, Logical> = Size::new(bounds.w.max(SMALLEST), bounds.h.max(SMALLEST));

    let min_size = Size::new(
        min_size.w.max(SMALLEST).min(bounds.w),
        min_size.h.max(SMALLEST).min(bounds.h),
    );
    let max_size = Size::new(
        max_size.w.max(min_size.w).min(bounds.w).max(min_size.w),
        max_size.h.max(min_size.h).min(bounds.h).max(min_size.h),
    );

    Size::new(size.w.max(SMALLEST), size.h.max(SMALLEST)).clamp(min_size, max_size)
}

/// Reads the size limits a client set on its own surface.
///
/// Ported from `mod.rs:368-386`. An unset limit is empty rather than absent in
/// the protocol, so "no minimum" means one pixel and "no maximum" means the
/// whole output.
fn size_constraints(
    toplevel: &ToplevelSurface,
    bounds: Size<i32, Logical>,
) -> (Size<i32, Logical>, Size<i32, Logical>) {
    let smallest = Size::new(SMALLEST, SMALLEST);

    with_states(toplevel.wl_surface(), |states| {
        let mut guard = states.cached_state.get::<SurfaceCachedState>();
        let current = guard.current();

        let min_size = if current.min_size.is_empty() {
            smallest
        } else {
            current.min_size
        };
        let max_size = if current.max_size.is_empty() {
            bounds
        } else {
            current.max_size.clamp(smallest, bounds)
        };

        if min_size.w > max_size.w || min_size.h > max_size.h {
            debug!(
                ?min_size,
                ?max_size,
                "a client set a minimum size above its maximum; the clamp resolves it"
            );
        }

        (min_size, max_size)
    })
}

fn pixel_size(size: Size<i32, Logical>) -> PixelSize {
    #[expect(
        clippy::cast_sign_loss,
        reason = "a size constraint is clamped to at least one pixel before it reaches here"
    )]
    PixelSize::new(size.w.max(0) as u32, size.h.max(0) as u32)
}

#[cfg(test)]
mod tests {
    use pretty_assertions::assert_eq;

    use super::*;

    fn size(width: i32, height: i32) -> Size<i32, Logical> {
        Size::new(width, height)
    }

    /// The default output's size, which is what a window's bounds normally are.
    fn bounds() -> Size<i32, Logical> {
        size(2560, 1440)
    }

    #[test]
    fn a_size_within_every_limit_is_granted_unchanged() {
        assert_eq!(
            clamp_configure_size(size(800, 600), size(1, 1), bounds(), bounds()),
            size(800, 600)
        );
    }

    #[test]
    fn a_size_below_the_minimum_is_raised_to_it() {
        assert_eq!(
            clamp_configure_size(size(100, 100), size(400, 300), bounds(), bounds()),
            size(400, 300)
        );
    }

    #[test]
    fn a_size_above_the_maximum_is_lowered_to_it() {
        assert_eq!(
            clamp_configure_size(size(4000, 4000), size(1, 1), size(800, 600), bounds()),
            size(800, 600)
        );
    }

    /// Negative sizes are not tested because they are unrepresentable:
    /// `Size::new` panics on one, so the only degenerate value that reaches
    /// this function is zero.
    #[test]
    fn nothing_is_ever_configured_to_zero() {
        for requested in [size(0, 0), size(0, 600), size(800, 0)] {
            let granted = clamp_configure_size(requested, size(0, 0), bounds(), bounds());
            assert!(
                granted.w >= SMALLEST && granted.h >= SMALLEST,
                "{requested:?} produced {granted:?}"
            );
        }
    }

    #[test]
    fn a_minimum_larger_than_the_output_is_capped_by_the_output() {
        let granted = clamp_configure_size(size(800, 600), size(9000, 9000), bounds(), bounds());

        assert_eq!(
            granted,
            bounds(),
            "a client that cannot fit is given the whole output rather than an inverted range"
        );
    }

    #[test]
    fn a_maximum_below_the_minimum_loses_to_the_minimum() {
        let granted =
            clamp_configure_size(size(800, 600), size(700, 500), size(100, 100), bounds());

        assert_eq!(
            granted,
            size(700, 500),
            "the minimum wins, because a range with no room in it has to resolve somewhere"
        );
    }

    #[test]
    fn a_degenerate_bounds_still_produces_a_usable_size() {
        let granted = clamp_configure_size(size(800, 600), size(1, 1), size(800, 600), size(0, 0));

        assert_eq!(
            granted,
            size(SMALLEST, SMALLEST),
            "an output of no size still has to be configured to something"
        );
    }

    #[test]
    fn clamping_an_already_clamped_size_changes_nothing() {
        let min = size(320, 200);
        let max = size(1280, 720);

        for requested in [size(1, 1), size(640, 480), size(5000, 5000)] {
            let once = clamp_configure_size(requested, min, max, bounds());
            let twice = clamp_configure_size(once, min, max, bounds());
            assert_eq!(once, twice, "clamping is idempotent for {requested:?}");
        }
    }

    #[test]
    fn a_size_change_is_visible_when_it_maps_or_resizes() {
        assert!(
            SizeChange {
                mapped: true,
                resized: false
            }
            .is_visible()
        );
        assert!(
            SizeChange {
                mapped: false,
                resized: true
            }
            .is_visible()
        );
        assert!(
            !SizeChange {
                mapped: false,
                resized: false
            }
            .is_visible(),
            "a commit that changes neither is not worth republishing for"
        );
    }
}
