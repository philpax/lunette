//! Adapted from selected fragments of WayVR's `backend/wayvr/window.rs` and
//! `backend/wayvr/mod.rs` (size constraints), at commit
//! 98f800c644719d3f23a20e50bd3237c29a8082cb.
//! Copyright (c) the WayVR authors (galister, oo8dev). Licensed GPL-3.0-only.
//!
//! Tracks Wayland toplevels, their assigned outputs, and their configure sizes.
//!
//! `WindowManager` owns each `ToplevelSurface` from creation until destruction.
//! It runs on the compositor thread; Smithay stores surface state in
//! thread-affine data. A window remains tracked while unmapped, and its
//! `WindowId` and `SinkId` remain stable if it maps again.
//!
//! Snapshots include only windows with current imported content. Buffer retention
//! and image handling are outside this bookkeeping type. Output scale state is
//! sent by the output path; this module uses the resulting logical bounds for
//! toplevel configures. The client controls when a configure takes effect:
//! snapshots and hit testing use committed geometry until a content commit
//! updates it. This bookkeeping type has no graphics-device dependency; buffer
//! retention and image import use the compositor's separate surface boundary.
//!
//! Size clamping is kept pure so its protocol and degenerate-input rules can be
//! tested without Wayland state.

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

/// The minimum dimension sent in a configure. The protocol permits zero, but
/// this compositor configures at least one pixel.
const SMALLEST: i32 = 1;

/// Stores windows in creation order. Identifiers are minted monotonically and
/// are never reused, including after a window is unmapped.
#[derive(Debug, Default)]
pub(crate) struct WindowManager {
    windows: Vec<Window>,
    minted: u64,
}

impl WindowManager {
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

    pub(crate) fn mapped(&self) -> impl Iterator<Item = &Window> {
        self.windows.iter().filter(|window| window.mapped)
    }

    /// Includes unmapped windows so an output change configures them before their
    /// first buffer commit.
    pub(crate) fn on_output(&mut self, output: OutputId) -> impl Iterator<Item = &mut Window> {
        self.windows
            .iter_mut()
            .filter(move |window| window.output == output)
    }

    /// Reassigns windows before a withdrawn output is rescaled. Snapshot
    /// identity and configure bounds use the window's output.
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

#[derive(Debug)]
pub(crate) struct Window {
    id: WindowId,
    sink: SinkId,
    surface: SurfaceId,
    process: Option<ProcessId>,
    /// The assigned output used for this window's bounds and snapshot.
    output: OutputId,
    toplevel: ToplevelSurface,
    title: Option<String>,
    app_id: Option<String>,
    /// The last size the client committed. Configure requests do not change it
    /// until the client commits content.
    size: PixelSize,
    bounds: Size<i32, Logical>,
    min_size: Size<i32, Logical>,
    max_size: Size<i32, Logical>,
    /// The last clamped configure size sent without a matching client commit.
    pending_configure_size: Option<Size<i32, Logical>>,
    states: ToplevelStates,
    /// The content-type hint promoted by the client's buffer commit.
    content_type: ContentType,
    /// Whether current imported content makes the window reportable.
    mapped: bool,
}

impl Window {
    pub(crate) const fn id(&self) -> WindowId {
        self.id
    }

    pub(crate) const fn toplevel(&self) -> &ToplevelSurface {
        &self.toplevel
    }

    pub(crate) const fn output(&self) -> OutputId {
        self.output
    }

    pub(crate) const fn is_mapped(&self) -> bool {
        self.mapped
    }

    pub(crate) const fn size(&self) -> PixelSize {
        self.size
    }

    pub(crate) fn title(&self) -> Option<&str> {
        self.title.as_deref()
    }

    pub(crate) fn set_title(&mut self, title: Option<String>) -> bool {
        if self.title == title {
            return false;
        }
        self.title = title;
        true
    }

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

    /// Refreshes the client's size limits before sizing. The client may change
    /// these limits between commits.
    pub(crate) fn refresh_constraints(&mut self, bounds: Size<i32, Logical>) {
        self.bounds = bounds;
        let (min_size, max_size) = size_constraints(&self.toplevel, bounds);
        self.min_size = min_size;
        self.max_size = max_size;
    }

    /// Sends a configure with the requested size clamped to client limits and
    /// output bounds. It updates the pending xdg state before sending the
    /// configure, and while the clamped size is pending it is not resent
    /// unchanged.
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

    /// Records the size the client committed, clears the pending configure, and
    /// returns whether the window mapped or resized.
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

    /// Marks the window unmapped after a null-buffer commit. A later buffer
    /// commit can map the same window and retain its identifiers.
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
            parent: None,
            states: self.states.clone(),
            content_type: self.content_type,
        }
    }

    pub(crate) fn remember_content_type(&mut self, content_type: ContentType) -> bool {
        let changed = self.content_type != content_type;
        self.content_type = content_type;
        changed
    }
}

/// The visibility changes caused by a committed buffer. The compositor publishes
/// a new snapshot when either field is true.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct SizeChange {
    /// The commit provides the window's first current content.
    pub(crate) mapped: bool,
    /// The committed logical size differs from the previous one.
    pub(crate) resized: bool,
}

impl SizeChange {
    pub(crate) const fn is_visible(self) -> bool {
        self.mapped || self.resized
    }
}

/// Clamps a requested logical size to a non-zero output bound and the client's
/// limits. The minimum is clamped to the output before the maximum is raised to
/// it; an inverted client range is resolved at the minimum and not rejected.
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

/// Reads the current size limits from the surface's cached xdg state. An empty
/// minimum means one pixel, and an empty maximum means the supplied output bound.
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

    /// Negative dimensions cannot reach this helper through `Size::new`; zero is
    /// the degenerate input covered by this test.
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
