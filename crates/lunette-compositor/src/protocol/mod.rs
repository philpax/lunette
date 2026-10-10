//! The vocabulary exchanged between the compositor and main threads.
//!
//! Commands are asynchronous requests. The compositor reports results through
//! [`Event`] and publishes an immutable [`Snapshot`] once per tick.
//!
//! Identifiers are non-zero newtypes. [`SpawnRequest`] carries its
//! [`ProcessId`] because the main thread returns that identifier before the
//! compositor receives the request.
//!
//! Host-desktop capture surfaces and selection content do not cross this
//! boundary. Selection transfers pass the file descriptor between the processes
//! that own the bytes.

mod input;
mod keymap;
mod process;

use std::{fmt, num::NonZeroU64, sync::Arc};

use lunette_luau::closed_set;
use smallvec::SmallVec;
use smithay::backend::allocator::{Fourcc, Modifier};

pub use crate::protocol::{
    input::{
        InputDomain, KeyModifier, Keycode, Keysym, PointerButton, SURFACE_UNITS_PER_DETENT,
        ScrollAxis, ScrollDelta,
    },
    keymap::{
        KeyboardConfig, KeymapConfig, KeymapDefaults, KeymapText, LayoutName, RepeatDelay,
        RepeatPolicy, RepeatRate,
    },
    process::{Argv, Pid, ProcessOutcome, ProcessSignal, SignalNumber, SpawnRequest, Stream},
};
use crate::surface::{BufferImporter, PixelBuffer};

/// An asynchronous request from the main thread to the compositor thread.
///
/// Results are reported through [`Event`] and [`Snapshot`]. This type is not
/// `Clone` because [`Command::AdoptGraphics`] transfers the sole importer for a
/// graphics device.
#[derive(Debug)]
pub enum Command {
    /// Starts a process and attributes its clients to it.
    Spawn(SpawnRequest),
    /// Signals a spawned process group.
    SignalProcess {
        process: ProcessId,
        signal: ProcessSignal,
    },
    /// Requests that a toplevel close. The client may prompt, or refuse.
    CloseWindow {
        window: WindowId,
    },
    /// Configures a toplevel. The client resizes at its own pace, and the new
    /// size is visible when it commits.
    ConfigureWindow {
        window: WindowId,
        size: Option<PixelSize>,
        states: ToplevelStates,
    },
    /// Moves a seat's pointer to a position in a sink's pixel space.
    Pointer {
        seat: SeatId,
        sink: SinkId,
        position: PixelPoint,
    },
    /// Withdraws a seat's pointer from whatever it hovers over.
    PointerLeave {
        seat: SeatId,
    },
    /// Presses or releases a pointer button over a sink.
    Button {
        seat: SeatId,
        sink: SinkId,
        button: PointerButton,
        pressed: bool,
    },
    /// Scrolls over a sink.
    Scroll {
        seat: SeatId,
        sink: SinkId,
        axis: ScrollAxis,
        delta: ScrollDelta,
    },
    /// Presses or releases a key on a seat's keyboard.
    Key {
        seat: SeatId,
        key: Keycode,
        pressed: bool,
    },
    /// Gives a seat's keyboard focus to a sink, or takes it away.
    ///
    /// A host sink cannot be focused because lunette has no control over the
    /// host desktop's keyboard focus.
    Focus {
        seat: SeatId,
        sink: Option<SinkId>,
    },
    /// Replaces a seat's modifier state in full.
    Modifiers {
        seat: SeatId,
        modifiers: ModifierState,
    },
    /// Types text that the active layout may not be able to express.
    ///
    /// Interleaving this request with [`Command::Key`] for the same seat is not
    /// supported.
    TypeText {
        seat: SeatId,
        text: String,
    },
    CreateSeat {
        seat: SeatId,
        name: String,
        keyboard: Box<KeyboardConfig>,
    },
    DestroySeat {
        seat: SeatId,
    },
    /// Selects the seat that bridges the host clipboard and primary selection.
    /// At most one seat can bridge.
    SetClipboardBridge {
        seat: Option<SeatId>,
    },
    CreateOutput {
        output: OutputId,
        mode: OutputMode,
    },
    ReconfigureOutput {
        output: OutputId,
        mode: OutputMode,
    },
    DestroyOutput {
        output: OutputId,
    },
    /// Sets the rate at which a surface receives frame callbacks.
    SetFramePacing {
        surface: SurfaceId,
        pacing: FramePacing,
    },
    /// Releases every graphics object held by the compositor.
    ///
    /// The compositor replies with [`Event::GraphicsReleased`] and imports
    /// nothing until [`Command::AdoptGraphics`] arrives. The Wayland display,
    /// client connections, and retained `wl_buffer`s remain active.
    ReleaseGraphics,
    /// Supplies an importer built against a new device to the compositor.
    ///
    /// The compositor emits [`Event::BufferImported`] for each retained buffer
    /// it restores, followed by [`Event::GraphicsAdopted`]. The importer is
    /// owned, not shared, so one device has one import cache.
    AdoptGraphics {
        importer: Box<dyn BufferImporter>,
    },
    /// Stops the compositor thread. Clients are disconnected as the display
    /// drops.
    Shutdown,
}

/// A report from the compositor thread to the main thread.
///
/// The main thread drains events before reading the corresponding snapshot, so
/// each event's effects are present in the snapshot that follows it.
#[derive(Debug)]
pub enum Event {
    /// A mapped toplevel appears in the next snapshot.
    WindowOpened {
        window: WindowId,
    },
    /// An unmapped or disconnected toplevel is absent from the next snapshot,
    /// and its handle is dead.
    WindowClosed {
        window: WindowId,
    },
    TitleChanged {
        window: WindowId,
        title: String,
    },
    /// A surface has committed new content.
    SurfaceDamaged {
        surface: SurfaceId,
    },
    /// A client buffer is available to the frame thread.
    BufferImported {
        surface: SurfaceId,
        buffer: ImportedBuffer,
    },
    /// A surface has no content after destruction or a null-buffer commit.
    ///
    /// This applies to every `wl_surface`, including popups, subsurfaces, and
    /// cursor surfaces, so the frame thread can release its texture safely.
    SurfaceGone {
        surface: SurfaceId,
    },
    ProcessExited {
        process: ProcessId,
        outcome: ProcessOutcome,
    },
    /// Output bytes from a spawned process. The bytes may not be UTF-8.
    ProcessOutput {
        process: ProcessId,
        stream: Stream,
        bytes: Vec<u8>,
    },
    /// The compositor holds no graphics object, so the device may be destroyed.
    ///
    /// No subsequent event names an image until [`Event::GraphicsAdopted`].
    GraphicsReleased,
    /// The compositor has imported retained buffers against the new device.
    ///
    /// It follows the [`Event::BufferImported`] events for buffers it restored.
    GraphicsAdopted {
        /// The number of surfaces whose retained content was restored.
        restored: usize,
        /// The number of retained buffers that could not be imported. Those
        /// surfaces are blank until their clients draw again.
        failed: usize,
    },
}

/// The compositor's immutable state as of one tick.
///
/// The main thread reads one snapshot for the duration of each frame.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Snapshot {
    /// A strictly increasing tick number.
    pub generation: Generation,
    pub windows: Vec<WindowSnapshot>,
    pub processes: Vec<ProcessSnapshot>,
    pub outputs: Vec<OutputSnapshot>,
    pub seats: Vec<SeatSnapshot>,
}

/// A saturating tick counter. Zero denotes the initial snapshot.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct Generation(u64);

impl Generation {
    pub const INITIAL: Self = Self(0);

    /// Advances the counter without wrapping.
    #[must_use]
    pub const fn next(self) -> Self {
        Self(self.0.saturating_add(1))
    }

    #[must_use]
    pub const fn get(self) -> u64 {
        self.0
    }
}

impl fmt::Display for Generation {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.0)
    }
}

/// A mapped toplevel in a snapshot.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WindowSnapshot {
    pub window: WindowId,
    pub surface: SurfaceId,
    pub sink: SinkId,
    /// The process attribution, if available.
    pub process: Option<ProcessId>,
    pub output: OutputId,
    pub title: Option<String>,
    pub app_id: Option<String>,
    /// The size of the last committed content in surface coordinates: the
    /// buffer after its transform, scale, and `wp_viewport`.
    pub size: PixelSize,
    pub min_size: Option<PixelSize>,
    pub max_size: Option<PixelSize>,
    pub parent: Option<WindowId>,
    pub states: ToplevelStates,
    /// The client's content-type hint.
    pub content_type: ContentType,
    /// The part of the buffer the surface shows, after `wp_viewport` cropping.
    pub source_crop: SourceCrop,
    /// Whether the client leaves its decorations to the compositor. False
    /// when it asked through `xdg-decoration` or the KDE protocol to draw
    /// its own.
    pub server_side_decorations: bool,
    /// The window's popups and subsurfaces that have content, in the order
    /// they are drawn, bottom first. The window's own surface is not listed.
    pub children: Vec<ChildSurface>,
}

/// A popup or subsurface of a window, with what drawing it with the window
/// needs.
///
/// It is placed in the frame the pointer positions on the window's sink use,
/// and the compositor's hit test reaches it there, so a consumer that draws it
/// at `position` draws what the pointer reaches.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ChildSurface {
    pub surface: SurfaceId,
    pub kind: ChildKind,
    /// Where the child's top-left corner sits relative to the window
    /// surface's, in the window's surface coordinates. A popup can lie partly
    /// or wholly outside the window.
    pub position: SurfaceOffset,
    /// The size of the child's content in surface coordinates, as
    /// [`WindowSnapshot::size`] is a window's.
    pub size: PixelSize,
    /// The part of the buffer the child shows.
    pub source_crop: SourceCrop,
    pub stacking: Stacking,
}

closed_set! {
    /// The role that makes a surface part of a window.
    #[derive(Clone, Copy, Debug, PartialEq, Eq)]
    pub enum ChildKind {
        /// A `wl_subsurface`, of the window or of another child.
        Subsurface = "subsurface",
        /// An `xdg_popup`, of the window or of another popup.
        Popup = "popup",
    }
}

/// Which side of the window's own surface a child is drawn on.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Stacking {
    /// Beneath it, showing through where the window is transparent. Only a
    /// subsurface placed below the window's surface is.
    Below,
    Above,
}

/// The part of a surface's buffer that the surface shows, as fractions of the
/// buffer's width and height.
///
/// A client crops with `wp_viewport.set_source`. A surface without a source
/// rectangle shows its whole buffer, which is [`SourceCrop::FULL`].
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SourceCrop {
    left: f64,
    top: f64,
    right: f64,
    bottom: f64,
}

/// Every edge is finite, which [`SourceCrop::new`] guarantees, so equality is
/// total.
impl Eq for SourceCrop {}

impl SourceCrop {
    pub const FULL: Self = Self {
        left: 0.0,
        top: 0.0,
        right: 1.0,
        bottom: 1.0,
    };

    /// Builds a crop from its edges. `None` unless
    /// `0 <= left <= right <= 1` and `0 <= top <= bottom <= 1`, which also
    /// excludes NaN.
    #[must_use]
    pub fn new(left: f64, top: f64, right: f64, bottom: f64) -> Option<Self> {
        let ordered = |low: f64, high: f64| 0.0 <= low && low <= high && high <= 1.0;
        (ordered(left, right) && ordered(top, bottom)).then_some(Self {
            left,
            top,
            right,
            bottom,
        })
    }

    #[must_use]
    pub const fn left(self) -> f64 {
        self.left
    }

    #[must_use]
    pub const fn top(self) -> f64 {
        self.top
    }

    #[must_use]
    pub const fn right(self) -> f64 {
        self.right
    }

    #[must_use]
    pub const fn bottom(self) -> f64 {
        self.bottom
    }
}

impl Default for SourceCrop {
    fn default() -> Self {
        Self::FULL
    }
}

/// A process started or adopted by lunette.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ProcessSnapshot {
    pub process: ProcessId,
    /// The process ID, if it is available.
    pub pid: Option<Pid>,
    /// Whether the process was adopted or spawned.
    pub external: bool,
    pub alive: bool,
}

/// A seat in a snapshot.
///
/// The keymap text crosses the thread boundary because libxkbcommon is not
/// thread-safe; each thread compiles its own copy.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SeatSnapshot {
    pub seat: SeatId,
    /// The name reported on `wl_seat.name`; clients use it to distinguish
    /// two seats.
    pub name: String,
    pub keymap: Arc<KeymapText>,
    /// The modifiers held by this seat, as last reported to clients.
    pub modifiers: ModifierState,
    /// Whether this is the seat whose selections are the host desktop's. At most
    /// one seat is, because the host has one clipboard.
    pub clipboard_bridge: bool,
    /// The drag this seat's pointer carries, if a client started one.
    pub drag: Option<DragSnapshot>,
}

/// A drag a client started from a press of a seat's pointer.
///
/// It lasts until the seat's buttons are released, the window it started
/// from goes away, its data source is destroyed, or its seat is destroyed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DragSnapshot {
    /// Distinguishes this drag from the seat's earlier and later ones.
    pub drag: DragId,
    /// The image that follows the pointer. Absent when the client gave the
    /// drag no icon or has not yet committed a buffer to it.
    pub icon: Option<DragIcon>,
}

/// A drag icon's surface, with what drawing it at the pointer needs.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DragIcon {
    pub surface: SurfaceId,
    /// The size of the icon's content in surface coordinates, as
    /// [`WindowSnapshot::size`] is a window's.
    pub size: PixelSize,
    /// The part of the buffer the icon shows.
    pub source_crop: SourceCrop,
    /// Where the icon's top-left corner sits relative to the pointer.
    pub offset: SurfaceOffset,
}

/// A displacement in surface coordinates.
///
/// A drag icon starts with its top-left corner at the pointer, and each
/// `wl_surface.offset` the client commits moves it by that much.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SurfaceOffset {
    pub x: i32,
    pub y: i32,
}

/// A virtual monitor in a snapshot.
#[derive(Clone, Debug, PartialEq)]
pub struct OutputSnapshot {
    pub output: OutputId,
    pub mode: OutputMode,
}

/// The mode advertised to a client.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct OutputMode {
    pub size: PixelSize,
    pub scale: OutputScale,
    pub refresh: RefreshRate,
}

/// A client buffer after compositor-thread processing.
///
/// Dmabuf buffers arrive as device images. Shared-memory buffers arrive as
/// pixels because texture uploads occur on the frame thread.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ImportedBuffer {
    /// An image already on the graphics device.
    Image(ImportedImage),
    /// Tightly packed pixels awaiting an upload.
    Pixels(PixelBuffer),
}

impl ImportedBuffer {
    #[must_use]
    pub fn size(&self) -> PixelSize {
        match self {
            Self::Image(image) => image.size,
            Self::Pixels(pixels) => pixels.size(),
        }
    }
}

/// An image created on the graphics device from a client buffer.
///
/// The handle remains an opaque integer so this crate has no graphics dependency.
/// The main thread owns the image's lifetime and must keep it alive while the
/// graphics library holds a view onto it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ImportedImage {
    pub image: ImageHandle,
    pub size: PixelSize,
    pub format: Fourcc,
    pub modifier: Modifier,
}

/// An opaque non-zero image handle. The owning device interprets its value.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct ImageHandle(NonZeroU64);

impl ImageHandle {
    #[must_use]
    pub const fn new(raw: u64) -> Option<Self> {
        match NonZeroU64::new(raw) {
            Some(raw) => Some(Self(raw)),
            None => None,
        }
    }

    #[must_use]
    pub const fn get(self) -> u64 {
        self.0.get()
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct PixelSize {
    pub width: u32,
    pub height: u32,
}

impl PixelSize {
    #[must_use]
    pub const fn new(width: u32, height: u32) -> Self {
        Self { width, height }
    }
}

impl fmt::Display for PixelSize {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}x{}", self.width, self.height)
    }
}

/// A point in a sink's pixel space. Coordinates may be fractional.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PixelPoint {
    pub x: f64,
    pub y: f64,
}

impl PixelPoint {
    #[must_use]
    pub const fn new(x: f64, y: f64) -> Self {
        Self { x, y }
    }
}

/// A finite, strictly positive output scale factor.
#[derive(Clone, Copy, Debug, PartialEq, PartialOrd)]
pub struct OutputScale(f64);

impl OutputScale {
    pub const ONE: Self = Self(1.0);

    /// Rejects non-finite and non-positive scales.
    #[must_use]
    pub fn new(scale: f64) -> Option<Self> {
        (scale.is_finite() && scale > 0.0).then_some(Self(scale))
    }

    #[must_use]
    pub const fn get(self) -> f64 {
        self.0
    }
}

/// An output refresh rate in millihertz, the unit used by `wl_output.mode`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct RefreshRate(u32);

impl RefreshRate {
    #[must_use]
    pub const fn from_millihertz(millihertz: u32) -> Self {
        Self(millihertz)
    }

    #[must_use]
    pub const fn millihertz(self) -> u32 {
        self.0
    }
}

/// How often a surface receives a frame callback.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub enum FramePacing {
    /// A callback on every compositor tick.
    #[default]
    Unthrottled,
    /// A callback at most at the specified rate.
    ///
    /// The rate must be positive so clients continue to process their event
    /// loops.
    Limited(FrameRate),
}

closed_set! {
    /// A client's content-type hint from `wp_content_type_v1`.
    ///
    /// The value is advisory. Lua combines it with other signals when it
    /// applies rendering policy.
    #[derive(Clone, Copy, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Hash)]
    pub enum ContentType {
        #[default]
        None = "none",
        Photo = "photo",
        Video = "video",
        Game = "game",
    }
}

/// A frame rate in hertz.
#[derive(Clone, Copy, Debug, PartialEq, PartialOrd)]
pub struct FrameRate(f64);

impl FrameRate {
    /// Rejects non-finite and non-positive rates.
    #[must_use]
    pub fn new(hertz: f64) -> Option<Self> {
        (hertz.is_finite() && hertz > 0.0).then_some(Self(hertz))
    }

    #[must_use]
    pub const fn get(self) -> f64 {
        self.0
    }
}

/// A state from `xdg_toplevel.state`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum ToplevelState {
    Maximized,
    Fullscreen,
    Resizing,
    Activated,
    TiledLeft,
    TiledRight,
    TiledTop,
    TiledBottom,
    Suspended,
}

pub type ToplevelStates = EnumSet<ToplevelState>;

pub type ModifierState = EnumSet<KeyModifier>;

/// A deduplicated set kept in sorted order.
///
/// Sorted storage makes equality independent of insertion order.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct EnumSet<T: Ord> {
    items: SmallVec<[T; 4]>,
}

impl<T: Ord> EnumSet<T> {
    #[must_use]
    pub fn new() -> Self {
        Self {
            items: SmallVec::new(),
        }
    }

    pub fn insert(&mut self, item: T) -> bool {
        match self.items.binary_search(&item) {
            Ok(_) => false,
            Err(index) => {
                self.items.insert(index, item);
                true
            }
        }
    }

    pub fn remove(&mut self, item: &T) -> bool {
        match self.items.binary_search(item) {
            Ok(index) => {
                self.items.remove(index);
                true
            }
            Err(_) => false,
        }
    }

    #[must_use]
    pub fn contains(&self, item: &T) -> bool {
        self.items.binary_search(item).is_ok()
    }

    #[must_use]
    pub fn len(&self) -> usize {
        self.items.len()
    }

    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.items.is_empty()
    }

    /// Iterates in sorted order.
    pub fn iter(&self) -> impl Iterator<Item = &T> {
        self.items.iter()
    }
}

impl<T: Ord> Default for EnumSet<T> {
    fn default() -> Self {
        Self::new()
    }
}

impl<T: Ord> FromIterator<T> for EnumSet<T> {
    fn from_iter<I: IntoIterator<Item = T>>(iter: I) -> Self {
        let mut set = Self::new();
        for item in iter {
            set.insert(item);
        }
        set
    }
}

impl<T: Ord> Extend<T> for EnumSet<T> {
    fn extend<I: IntoIterator<Item = T>>(&mut self, iter: I) {
        for item in iter {
            self.insert(item);
        }
    }
}

impl<'a, T: Ord> IntoIterator for &'a EnumSet<T> {
    type Item = &'a T;
    type IntoIter = std::slice::Iter<'a, T>;

    fn into_iter(self) -> Self::IntoIter {
        self.items.iter()
    }
}

macro_rules! identifier {
    ($($(#[$documentation:meta])* $name:ident;)*) => {
        $(
            $(#[$documentation])*
            #[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
            pub struct $name(NonZeroU64);

            impl $name {
                #[must_use]
                pub const fn new(raw: u64) -> Option<Self> {
                    match NonZeroU64::new(raw) {
                        Some(raw) => Some(Self(raw)),
                        None => None,
                    }
                }

                /// Returns the raw identifier for an untyped boundary.
                #[must_use]
                pub const fn get(self) -> u64 {
                    self.0.get()
                }
            }

            impl fmt::Display for $name {
                fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
                    write!(f, concat!(stringify!($name), "({})"), self.0)
                }
            }
        )*
    };
}

identifier! {
    WindowId;
    /// A `wl_surface`, distinct from its toplevel window.
    SurfaceId;
    SeatId;
    SinkId;
    OutputId;
    ProcessId;
    /// One drag-and-drop operation, from its start to its drop or cancellation.
    DragId;
}

#[cfg(test)]
#[expect(
    clippy::expect_used,
    reason = "a failed expectation is how a test reports a failure; the ban is on production code"
)]
mod tests {
    use pretty_assertions::assert_eq;

    use super::*;

    #[test]
    fn an_identifier_rejects_zero_and_round_trips_anything_else() {
        assert_eq!(WindowId::new(0), None);

        for raw in [1, 2, 42, u64::MAX] {
            let id = WindowId::new(raw).expect("a non-zero identifier is accepted");
            assert_eq!(id.get(), raw);
        }
    }

    #[test]
    fn identifiers_of_different_kinds_do_not_interchange() {
        let window = WindowId::new(1).expect("non-zero");
        let surface = SurfaceId::new(1).expect("non-zero");
        assert_eq!(window.get(), surface.get());
    }

    #[test]
    fn a_generation_increases_and_never_wraps() {
        assert_eq!(Generation::INITIAL.get(), 0);
        assert_eq!(Generation::INITIAL.next().get(), 1);

        let last = Generation(u64::MAX);
        assert_eq!(last.next(), last, "saturates rather than becoming zero");
    }

    #[test]
    fn an_empty_set_is_empty() {
        let states = ToplevelStates::new();
        assert!(states.is_empty());
        assert_eq!(states.len(), 0);
        assert!(!states.contains(&ToplevelState::Activated));
        assert_eq!(states.iter().count(), 0);
    }

    #[test]
    fn a_single_item_set_reports_only_that_item() {
        let states = ToplevelStates::from_iter([ToplevelState::Activated]);
        assert_eq!(states.len(), 1);
        assert!(states.contains(&ToplevelState::Activated));
        assert!(!states.contains(&ToplevelState::Maximized));
    }

    #[test]
    fn inserting_an_item_twice_changes_nothing_the_second_time() {
        let mut states = ToplevelStates::new();
        assert!(states.insert(ToplevelState::Fullscreen));
        let once = states.clone();

        assert!(!states.insert(ToplevelState::Fullscreen));
        assert_eq!(states, once);
    }

    #[test]
    fn set_equality_ignores_insertion_order() {
        let forwards = ToplevelStates::from_iter([
            ToplevelState::Activated,
            ToplevelState::Maximized,
            ToplevelState::Suspended,
        ]);
        let backwards = ToplevelStates::from_iter([
            ToplevelState::Suspended,
            ToplevelState::Maximized,
            ToplevelState::Activated,
        ]);

        assert_eq!(forwards, backwards);
        assert_eq!(forwards.len(), 3);
    }

    #[test]
    fn removing_reports_whether_the_set_changed() {
        let mut modifiers = ModifierState::from_iter([KeyModifier::Shift, KeyModifier::Control]);

        assert!(modifiers.remove(&KeyModifier::Shift));
        assert!(!modifiers.remove(&KeyModifier::Shift));
        assert_eq!(modifiers, ModifierState::from_iter([KeyModifier::Control]));
    }

    #[test]
    fn a_scale_rejects_values_a_client_would_divide_by() {
        assert_eq!(OutputScale::new(0.0), None);
        assert_eq!(OutputScale::new(-1.0), None);
        assert_eq!(OutputScale::new(f64::NAN), None);
        assert_eq!(OutputScale::new(f64::INFINITY), None);
        assert_eq!(OutputScale::new(1.5).map(OutputScale::get), Some(1.5));
    }

    #[test]
    fn a_frame_rate_rejects_values_that_are_not_a_rate() {
        assert_eq!(FrameRate::new(0.0), None);
        assert_eq!(FrameRate::new(-90.0), None);
        assert_eq!(FrameRate::new(f64::NAN), None);
        assert_eq!(FrameRate::new(90.0).map(FrameRate::get), Some(90.0));
    }
}
