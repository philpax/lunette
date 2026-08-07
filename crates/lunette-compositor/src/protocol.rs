//! The vocabulary the compositor thread and the main thread exchange.
//!
//! Three conduits carry everything between the two threads, and this module
//! defines what travels on each. [`Command`] goes down to the compositor,
//! [`Event`] comes back up, and [`Snapshot`] is republished whole once per
//! tick for the main thread to read at frame start. The transports themselves
//! live in [`crate::thread`]; this module is plain data, so it can be reasoned
//! about and tested without a socket, a client, or a device.
//!
//! # Identifiers
//!
//! Every identifier is a newtype over a non-zero integer. The two threads
//! allocate from disjoint kinds: the compositor mints [`WindowId`],
//! [`SurfaceId`], and [`SinkId`] as clients create objects, while the main
//! thread mints [`ProcessId`], [`SeatId`], and [`OutputId`] before it asks for
//! the corresponding thing to exist. That is why [`SpawnRequest`] carries the
//! `ProcessId` rather than reporting one back: `lunette.spawn` returns a handle
//! in the same call, so the identifier has to exist before the compositor has
//! seen the request.
//!
//! # What is not handled yet
//!
//! The shape below is settled, but the phases that give each variant a handler
//! are not all written. A declared variant with no handler is a promise this
//! crate does not keep, so the state of each is recorded here.
//!
//! Handled, along with every [`Event`] variant: [`Command::Spawn`],
//! [`Command::SignalProcess`], [`Command::CloseWindow`],
//! [`Command::ConfigureWindow`], [`Command::Pointer`],
//! [`Command::PointerLeave`], [`Command::Button`], [`Command::Key`],
//! [`Command::Modifiers`], [`Command::Focus`], [`Command::TypeText`],
//! [`Command::Scroll`], [`Command::CreateSeat`], [`Command::DestroySeat`],
//! [`Command::SetClipboardBridge`], and [`Command::Shutdown`].
//!
//! Handled as well: [`Command::CreateOutput`], [`Command::ReconfigureOutput`],
//! and [`Command::DestroyOutput`].
//!
//! Accepted and logged, but otherwise inert until the phase named:
//!
//! - [`Command::SetFramePacing`] — the pacing half of the outputs and pacing
//!   phase.
//!
//! Not declared at all: the host-desktop capture surfaces. Selection *content*
//! is also absent from this vocabulary, and deliberately: a transfer is a file
//! descriptor passed between the two processes that own the bytes, so nothing
//! about it crosses this boundary. `docs/decisions.md` records why.

use std::{
    ffi::{OsStr, OsString},
    fmt,
    num::{NonZeroI32, NonZeroU64},
    path::PathBuf,
    sync::Arc,
};

use smallvec::SmallVec;
use smithay::backend::allocator::{Fourcc, Modifier};

use crate::surface::{BufferImporter, PixelBuffer};

/// A request from the main thread to the compositor thread.
///
/// Every variant is a request rather than a call. Nothing here reports a
/// result: what the compositor did is observed through [`Event`] and
/// [`Snapshot`], because the protocol underneath is asynchronous and an API
/// that pretended otherwise would have to break later.
/// Deliberately not `Clone`. [`Command::AdoptGraphics`] hands over the sole
/// importer, which is an owned window onto a graphics device and cannot be
/// duplicated; nothing in lunette clones a command, and a derive that forced
/// the handover into a shared cell would make the transfer of ownership
/// invisible at the call site.
#[derive(Debug)]
pub enum Command {
    /// Starts a process and attributes its clients to it.
    Spawn(SpawnRequest),
    /// Signals a spawned process group.
    SignalProcess {
        process: ProcessId,
        signal: ProcessSignal,
    },
    /// Asks a toplevel to close. The client may prompt, or refuse.
    CloseWindow { window: WindowId },
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
    /// Withdraws a seat's pointer from whatever it was over.
    PointerLeave { seat: SeatId },
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
    /// Separate from [`Command::Pointer`] on purpose. WayVR drives focus from
    /// pointer motion (`mod.rs:1128-1148`), which with two hands means the off
    /// hand steals focus by hovering; here hovering and focusing are two
    /// requests, and which one a gesture makes is Lua's decision.
    ///
    /// A host sink cannot be focused. The host desktop has one keyboard focus
    /// and lunette does not choose it, which is why the sink is named by
    /// identifier rather than by handle: only a window has one.
    Focus { seat: SeatId, sink: Option<SinkId> },
    /// Replaces a seat's modifier state wholesale.
    Modifiers {
        seat: SeatId,
        modifiers: ModifierState,
    },
    /// Types text that the active layout may not be able to express.
    ///
    /// Stateful: it generates and uploads a temporary keymap, so it must not be
    /// interleaved with [`Command::Key`] on the same seat.
    TypeText { seat: SeatId, text: String },
    /// Creates a `wl_seat` with its own pointer, keyboard, and focus.
    CreateSeat {
        seat: SeatId,
        name: String,
        /// Boxed because it is the largest thing any command carries and a seat
        /// is created a handful of times a session, while every other command
        /// travels the same bounded channel on every frame.
        keyboard: Box<KeyboardConfig>,
    },
    /// Destroys a seat and drops any grab it held.
    DestroySeat { seat: SeatId },
    /// Names the one seat whose clipboard and primary selection are the host
    /// desktop's, or takes the bridge away entirely.
    ///
    /// The host has one of each and a seat owns one of each, so exactly one seat
    /// can be the host's. Which one is policy, so it comes from Lua; see
    /// `docs/input.md`.
    SetClipboardBridge { seat: Option<SeatId> },
    /// Creates a virtual monitor for clients assigned to it.
    CreateOutput { output: OutputId, mode: OutputMode },
    /// Changes an existing output's mode. Clients reallocate and re-lay-out in
    /// response, so a caller that changes scale continuously will see them
    /// struggle.
    ReconfigureOutput { output: OutputId, mode: OutputMode },
    /// Destroys an output. Clients assigned to it lose their only monitor.
    DestroyOutput { output: OutputId },
    /// Sets how often a surface is given a frame callback, which is what paces
    /// the client's drawing.
    SetFramePacing {
        surface: SurfaceId,
        pacing: FramePacing,
    },
    /// Releases every graphics object the compositor holds, so that the device
    /// they were created against can be destroyed.
    ///
    /// The first half of the restart quiesce. `lunette.restart()` closes the Lua
    /// state, and closing it destroys LÖVR's graphics module and the `VkDevice`
    /// the importer borrowed — so the importer has to be given up while that
    /// device is still alive. The compositor answers with
    /// [`Event::GraphicsReleased`] and imports nothing until
    /// [`Command::AdoptGraphics`] arrives.
    ///
    /// Nothing else about the compositor stops. The Wayland display, the
    /// listening socket, every client connection, and every retained
    /// `wl_buffer` are untouched, which is what lets clients stay connected
    /// across a restart: the compositor never speaks Vulkan to a client, it
    /// imports descriptors.
    ReleaseGraphics,
    /// Hands the compositor an importer built against a new device, and
    /// re-imports the buffers the clients still hold.
    ///
    /// The second half. The compositor answers with [`Event::GraphicsAdopted`],
    /// preceded by one [`Event::BufferImported`] per surface whose retained
    /// buffer imported again — so the frame thread rebuilds its textures
    /// through the path a commit already takes.
    AdoptGraphics {
        /// The sole window onto the new device. Owned rather than shared: two
        /// importers against one device would each keep their own cache, and an
        /// image would be created twice for one buffer.
        importer: Box<dyn BufferImporter>,
    },
    /// Stops the compositor thread. Clients are disconnected as the display
    /// drops.
    Shutdown,
}

/// A report from the compositor thread to the main thread.
///
/// Events are drained at frame start, immediately before the snapshot they
/// belong with is read, so a handler observing an event sees a snapshot that
/// already accounts for it.
#[derive(Debug)]
pub enum Event {
    /// A toplevel mapped and is present in the next snapshot.
    WindowOpened { window: WindowId },
    /// A toplevel unmapped or its client disconnected. It is absent from the
    /// next snapshot, and its handle is dead.
    WindowClosed { window: WindowId },
    /// A toplevel set a new title.
    TitleChanged { window: WindowId, title: String },
    /// A surface committed new content. Consumers that copy rather than sample
    /// use this to skip unchanged surfaces.
    SurfaceDamaged { surface: SurfaceId },
    /// A client buffer became available to the frame thread.
    BufferImported {
        surface: SurfaceId,
        buffer: ImportedBuffer,
    },
    /// A surface's content is gone: the surface was destroyed, or it unmapped
    /// by attaching a null buffer.
    ///
    /// Reported for every `wl_surface`, not only for a toplevel — a popup, a
    /// subsurface, and a cursor surface all commit buffers and so all become
    /// textures on the frame thread. The frame thread drops what it holds for
    /// the surface when it sees this. Without it a texture whose image the
    /// compositor is about to retire would stay in the ledger, and the frame
    /// after next would record a barrier over freed memory.
    SurfaceGone { surface: SurfaceId },
    /// A spawned process ended, or never started.
    ProcessExited {
        process: ProcessId,
        outcome: ProcessOutcome,
    },
    /// A spawned process wrote to one of its captured streams.
    ///
    /// Bytes rather than a string: a child's output is not guaranteed to be
    /// UTF-8, and decoding is the consumer's decision.
    ProcessOutput {
        process: ProcessId,
        stream: Stream,
        bytes: Vec<u8>,
    },
    /// The compositor holds no graphics object, so the device may be destroyed.
    ///
    /// The acknowledgement [`Command::ReleaseGraphics`] asks for, and the one
    /// event the main thread ever waits on. Nothing the compositor reports after
    /// it names an image, until [`Event::GraphicsAdopted`].
    GraphicsReleased,
    /// The compositor imports against a new device again.
    ///
    /// Reported after the [`Event::BufferImported`] for every retained buffer
    /// that could be re-imported, so a consumer that sees this has already seen
    /// everything the restart restored.
    GraphicsAdopted {
        /// How many surfaces got their content back without the client having
        /// drawn anything.
        restored: usize,
        /// How many retained buffers could not be imported against the new
        /// device. Each of those clients was told its buffer is free, so the
        /// surface is blank until the client draws again. A failure here is not
        /// fatal to the restart: one surface losing its content is a better
        /// outcome than the session ending.
        failed: usize,
    },
}

/// The compositor's state as of one tick, republished whole.
///
/// The main thread reads the latest at frame start and holds it for the
/// duration of the frame, so every read within one frame is consistent with
/// every other. It is never mutated in place.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Snapshot {
    /// Which tick this is. Strictly increasing, so a consumer can tell a
    /// republished snapshot from an unchanged one.
    pub generation: Generation,
    pub windows: Vec<WindowSnapshot>,
    pub processes: Vec<ProcessSnapshot>,
    pub outputs: Vec<OutputSnapshot>,
    pub seats: Vec<SeatSnapshot>,
}

/// A tick counter. Zero is the snapshot published before the compositor has
/// run at all.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct Generation(u64);

impl Generation {
    /// The generation of the empty snapshot a reader sees before the first
    /// publication.
    pub const INITIAL: Self = Self(0);

    /// The next generation, saturating rather than wrapping.
    ///
    /// A wrap would make the counter non-monotonic, which is the one property
    /// consumers rely on. At one tick per frame, saturation is unreachable.
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

/// A mapped toplevel, as of one tick.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WindowSnapshot {
    pub window: WindowId,
    /// The surface whose buffers carry this window's pixels.
    pub surface: SurfaceId,
    /// Where input for this window is delivered.
    pub sink: SinkId,
    /// The process this window was attributed to, absent when attribution
    /// failed.
    pub process: Option<ProcessId>,
    /// The output this window is shown on. Every window is on exactly one: a
    /// client that was assigned none is shown the output every session starts
    /// with, so there is no window with no output to report.
    pub output: OutputId,
    pub title: Option<String>,
    pub app_id: Option<String>,
    /// The size the client last committed, in pixels. Not the size last
    /// requested.
    pub size: PixelSize,
    pub min_size: Option<PixelSize>,
    pub max_size: Option<PixelSize>,
    /// The toplevel this one is transient for.
    pub parent: Option<WindowId>,
    pub states: ToplevelStates,
}

/// A process lunette started, or adopted from outside.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ProcessSnapshot {
    pub process: ProcessId,
    /// Absent until the child has been forked, and for an adopted process
    /// whose pid could not be read.
    pub pid: Option<Pid>,
    /// Whether the process connected from outside rather than being spawned.
    pub external: bool,
    pub alive: bool,
}

/// A seat, as of one tick.
///
/// The keymap rides along because the main thread cannot ask for it: a caller
/// drawing a virtual keyboard needs the layout list and the keysym a keycode
/// produces, and libxkbcommon is not thread-safe, so the text is what crosses
/// and each thread compiles its own copy of it.
///
/// [`Arc`] rather than a `String` because a compiled layout serialises to tens
/// of kilobytes and a snapshot is republished every tick. The keymap changes
/// when a seat is created or `typeText` swaps one in, which is rare, so the
/// clone is a refcount bump on every other tick.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SeatSnapshot {
    pub seat: SeatId,
    /// What clients see on `wl_seat.name`, and how a client tells two seats
    /// apart.
    pub name: String,
    pub keymap: Arc<KeymapText>,
    /// The modifiers this seat is holding, as clients were last told.
    pub modifiers: ModifierState,
    /// Whether this is the seat whose selections are the host desktop's. At most
    /// one seat is, because the host has one clipboard.
    pub clipboard_bridge: bool,
}

/// A virtual monitor clients are told about.
#[derive(Clone, Debug, PartialEq)]
pub struct OutputSnapshot {
    pub output: OutputId,
    pub mode: OutputMode,
}

/// What a client is told about the monitor it is on.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct OutputMode {
    pub size: PixelSize,
    pub scale: OutputScale,
    pub refresh: RefreshRate,
}

/// What to start, and how to attribute what connects afterwards.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SpawnRequest {
    /// Allocated by the main thread before the request is sent, so
    /// `lunette.spawn` can return a handle without waiting for a reply.
    pub process: ProcessId,
    pub argv: Argv,
    /// Added to the environment the child inherits, not a replacement for it.
    pub env: Vec<(OsString, OsString)>,
    pub cwd: Option<PathBuf>,
    /// The only output this client is shown. Absent means the output every
    /// session starts with, which is what a client lunette did not spawn is
    /// shown too.
    ///
    /// An output that does not exist when the spawn arrives is refused and the
    /// client falls back to the default one: a client shown no monitor at all
    /// cannot pick a scale or a refresh rate.
    pub output: Option<OutputId>,
    /// Whether the child is launched against an X server rather than the
    /// Wayland socket directly.
    pub xwayland: bool,
}

/// A command line, which is a program and its arguments rather than a list that
/// might be empty.
///
/// `execvp` has no meaning for an empty list, so the emptiness is rejected once
/// here rather than being re-checked at every layer that handles a spawn.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Argv {
    program: OsString,
    arguments: Vec<OsString>,
}

impl Argv {
    pub fn new(program: impl Into<OsString>, arguments: Vec<OsString>) -> Self {
        Self {
            program: program.into(),
            arguments,
        }
    }

    /// Splits a caller-supplied list into a program and its arguments,
    /// rejecting an empty list.
    pub fn from_list(list: Vec<OsString>) -> Option<Self> {
        let mut items = list.into_iter();
        let program = items.next()?;
        Some(Self {
            program,
            arguments: items.collect(),
        })
    }

    #[must_use]
    pub fn program(&self) -> &OsStr {
        &self.program
    }

    #[must_use]
    pub fn arguments(&self) -> &[OsString] {
        &self.arguments
    }
}

/// How a process ended.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ProcessOutcome {
    Exited {
        code: i32,
    },
    Signalled {
        signal: SignalNumber,
    },
    /// The child never ran. The message names what failed, and is the only
    /// report a caller gets for a mistyped program name.
    SpawnFailed {
        message: String,
    },
}

/// A signal lunette is willing to send to a process group.
///
/// A closed set rather than a number, because sending an arbitrary signal is
/// not a capability the Lua API offers.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum ProcessSignal {
    Hangup,
    Interrupt,
    Terminate,
    Kill,
}

/// The number of a signal that killed a process. Any signal may be observed,
/// so this is not the same domain as [`ProcessSignal`].
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct SignalNumber(i32);

impl SignalNumber {
    #[must_use]
    pub const fn new(raw: i32) -> Self {
        Self(raw)
    }

    #[must_use]
    pub const fn get(self) -> i32 {
        self.0
    }
}

impl fmt::Display for SignalNumber {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.0)
    }
}

/// One of a child's captured output streams.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum Stream {
    Stdout,
    Stderr,
}

/// A process identifier. Non-zero, and never negative: a process group is
/// addressed by negating this at the point of the signal, not by carrying a
/// negative number around.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct Pid(NonZeroI32);

impl Pid {
    #[must_use]
    pub const fn new(raw: i32) -> Option<Self> {
        match NonZeroI32::new(raw) {
            Some(raw) if raw.get() > 0 => Some(Self(raw)),
            _ => None,
        }
    }

    #[must_use]
    pub const fn get(self) -> i32 {
        self.0.get()
    }
}

impl fmt::Display for Pid {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.0)
    }
}

/// How far a client's buffer got before it crossed to the frame thread.
///
/// The two client buffer types do not converge, and pretending they did would
/// mean one of the two paths lying. A dmabuf becomes an image on the compositor
/// thread, because creating one touches no queue. A shared-memory buffer cannot:
/// filling a texture is a submission, and only the frame thread submits. So a
/// dmabuf arrives as a handle and a shared-memory buffer arrives as pixels,
/// and the frame thread finishes whichever it is given.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ImportedBuffer {
    /// An image already on the graphics device.
    Image(ImportedImage),
    /// Tightly packed pixels awaiting an upload.
    Pixels(PixelBuffer),
}

impl ImportedBuffer {
    /// The buffer's size in pixels, whichever form it took.
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
/// The handle crosses as an opaque integer, and this crate never dereferences
/// it. Naming the Vulkan type here would make `lunette-compositor` depend on a
/// graphics crate, and the compositor's tests would then need a device to link
/// against, which is the property this separation exists to protect.
///
/// The main thread owns the image's lifetime: it destroys the image and frees
/// its memory, and it must not do so while the graphics library still holds a
/// view onto it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ImportedImage {
    pub image: ImageHandle,
    pub size: PixelSize,
    pub format: Fourcc,
    pub modifier: Modifier,
}

/// A `VkImage` as a plain integer. Meaningful only to the thread that owns the
/// device it came from.
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

/// A size in pixels.
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

/// A point in a sink's pixel space.
///
/// Fractional because Wayland pointer coordinates are, and because the ray
/// intersection upstream of this produces a fractional hit that would be
/// needlessly quantised on the way through.
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

/// An output's scale factor.
#[derive(Clone, Copy, Debug, PartialEq, PartialOrd)]
pub struct OutputScale(f64);

impl OutputScale {
    /// An unscaled output, which is what an output that names no scale is.
    pub const ONE: Self = Self(1.0);

    /// Rejects a scale that is not finite and strictly positive. A client told
    /// its monitor has a scale of zero divides by it.
    #[must_use]
    pub fn new(scale: f64) -> Option<Self> {
        (scale.is_finite() && scale > 0.0).then_some(Self(scale))
    }

    #[must_use]
    pub const fn get(self) -> f64 {
        self.0
    }
}

/// An output's refresh rate, in millihertz, which is the unit `wl_output.mode`
/// carries.
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

/// How often a surface is given a frame callback.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum FramePacing {
    /// A callback every time the compositor ticks.
    Unthrottled,
    /// A callback at most this often.
    ///
    /// The floor is not zero. A client starved of frame callbacks frequently
    /// stops pumping its event loop, so it stops answering input as well, and a
    /// window that is frozen but alive is worse than one costing a frame a
    /// second.
    Limited(FrameRate),
}

/// A frame rate in hertz.
#[derive(Clone, Copy, Debug, PartialEq, PartialOrd)]
pub struct FrameRate(f64);

impl FrameRate {
    /// Rejects a rate that is not finite and strictly positive. Zero is
    /// spelled by starving the surface deliberately, which is a policy decision
    /// and not this type's business.
    #[must_use]
    pub fn new(hertz: f64) -> Option<Self> {
        (hertz.is_finite() && hertz > 0.0).then_some(Self(hertz))
    }

    #[must_use]
    pub const fn get(self) -> f64 {
        self.0
    }
}

/// A pointer button.
///
/// The five a mouse actually has, rather than the whole evdev range. Mapping to
/// a `BTN_*` code belongs with the seat, which is the only place that speaks
/// the protocol's numbering.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum PointerButton {
    Left,
    Right,
    Middle,
    Back,
    Forward,
}

/// Which pipeline a sink's input travels down.
///
/// A sink is somewhere pixel-space input can be delivered, and there are two
/// kinds of somewhere. A window sink reaches a client this compositor hosts,
/// through its seat. A host sink reaches the user's own desktop, through the
/// `HidProvider` in `lunette-capture`, and nothing in this crate ever sees one:
/// the domain is defined here because it is the closed set both halves name, and
/// because a caller routing input has to be able to ask which it is holding.
///
/// A type rather than a flag, so routing is an exhaustive match and a domain
/// added later cannot be silently unhandled.
///
/// This is new work. WayVR has one global binary `InputFocus { PhysicalScreen,
/// WayVR }` (`subsystem/input.rs:10`), toggled for the whole session, which
/// cannot express two hands pointing at two kinds of surface at once.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum InputDomain {
    /// A surface this compositor hosts.
    ///
    /// Each window is independently addressable: two seats pointing at two
    /// windows produce two cursors and two focuses.
    Window,
    /// The host desktop, behind a mirrored monitor.
    ///
    /// Every host sink shares one cursor and one keyboard focus, because the
    /// host has one of each. Two seats pointing at two mirrored monitors cannot
    /// produce two cursors, and `docs/host-desktop.md` records why that
    /// difference is exposed rather than hidden.
    Host,
}

impl InputDomain {
    /// The name Lua reads on `sink.domain`.
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Window => "window",
            Self::Host => "host",
        }
    }
}

impl fmt::Display for InputDomain {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum ScrollAxis {
    Vertical,
    Horizontal,
}

/// How far a scroll went.
///
/// Both forms exist in the protocol and clients treat them differently: a
/// notched wheel sends discrete steps, a touchpad sends a continuous distance.
/// Collapsing them loses the distinction that decides whether a client
/// kinetically scrolls.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum ScrollDelta {
    /// A distance in surface-local pixels.
    Continuous(f64),
    /// A count of wheel notches.
    Discrete(i32),
}

/// How many surface-local units `wl_pointer.axis` carries per wheel detent.
///
/// The convention every toolkit reads a continuous scroll under, and the one
/// number both directions of the conversion depend on: the compositor
/// multiplies a discrete count by it on the way to a client, and the host
/// pointer divides a continuous distance by it on the way to a wheel provider.
/// Two copies that drifted apart would make one direction stop inverting the
/// other, so there is one.
pub const SURFACE_UNITS_PER_DETENT: f64 = 10.0;

/// A key, in the Linux evdev numbering that `wl_keyboard` uses.
///
/// xkb numbers the same keys eight higher. Nothing here performs that
/// adjustment; it belongs where the keymap is consulted.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct Keycode(u32);

impl Keycode {
    #[must_use]
    pub const fn from_evdev(code: u32) -> Self {
        Self(code)
    }

    #[must_use]
    pub const fn evdev(self) -> u32 {
        self.0
    }
}

/// A keyboard modifier that a seat can hold down.
///
/// The order is the XKB modifier index order — shift, lock, control, then
/// `Mod1` through `Mod5` — because that is the order the masks on the wire are
/// numbered in, and a reader comparing this against a keymap's modifier list
/// should not have to reorder it in their head.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum KeyModifier {
    Shift,
    CapsLock,
    Control,
    Alt,
    NumLock,
    Mod3,
    Logo,
    Mod5,
}

impl KeyModifier {
    /// Every modifier a keymap can name.
    pub const ALL: &'static [Self] = &[
        Self::Shift,
        Self::CapsLock,
        Self::Control,
        Self::Alt,
        Self::NumLock,
        Self::Mod3,
        Self::Logo,
        Self::Mod5,
    ];

    /// The name Lua spells this modifier with, and the name it reads back.
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Shift => "shift",
            Self::CapsLock => "capsLock",
            Self::Control => "control",
            Self::Alt => "alt",
            Self::NumLock => "numLock",
            Self::Mod3 => "mod3",
            Self::Logo => "logo",
            Self::Mod5 => "mod5",
        }
    }

    /// The modifier a Lua name refers to, rejecting anything else.
    ///
    /// `None` rather than a default: `'shft'` is a typo, and a modifier that
    /// silently does nothing is harder to find than an error.
    #[must_use]
    pub fn from_name(name: &str) -> Option<Self> {
        Self::ALL
            .iter()
            .copied()
            .find(|modifier| modifier.as_str() == name)
    }

    /// A modifier that only latches rather than tracking the key.
    ///
    /// A lock is reported to a client in the locked mask and never in the
    /// depressed one, and the distinction is what stops a lock toggling itself
    /// off on the next update.
    #[must_use]
    pub const fn is_lock(self) -> bool {
        matches!(self, Self::CapsLock | Self::NumLock)
    }
}

impl fmt::Display for KeyModifier {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// An X11 keysym: what a keycode means once a layout and modifiers are applied.
///
/// A newtype over the raw number rather than `xkbcommon`'s own `Keysym`,
/// because a keysym travels between threads and through Lua, and neither end
/// should have to name a type from a library that is not thread-safe. The
/// numbering is X11's, which is also Wayland's and xkb's.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct Keysym(u32);

impl Keysym {
    /// The keysym Unicode codepoints map onto, which is the range
    /// `0x0100_0000 | codepoint`.
    const UNICODE_BASE: u32 = 0x0100_0000;

    #[must_use]
    pub const fn from_raw(raw: u32) -> Self {
        Self(raw)
    }

    #[must_use]
    pub const fn raw(self) -> u32 {
        self.0
    }

    /// The keysym for a character, in the Unicode range every character has.
    ///
    /// Deliberately not the legacy Latin-1 or keypad keysyms a layout would
    /// name the same character by. Those are what a *reverse lookup* answers
    /// with; this is the canonical name a synthesised keymap binds, and one
    /// canonical form is what makes two requests for the same character
    /// deduplicate.
    #[must_use]
    pub const fn from_char(character: char) -> Self {
        Self(Self::UNICODE_BASE | character as u32)
    }
}

impl fmt::Display for Keysym {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "keysym {:#010x}", self.0)
    }
}

/// A keyboard layout's name, as the keymap gives it.
///
/// Human-readable rather than an identifier: `"English (US)"`, not `"us"`. It
/// is what a virtual keyboard puts on a layout switcher.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct LayoutName(String);

impl LayoutName {
    #[must_use]
    pub fn new(name: impl Into<String>) -> Self {
        Self(name.into())
    }

    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Display for LayoutName {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

/// A compiled keyboard layout, in XKB's version 1 text format.
///
/// Text rather than a compiled keymap because that is the only form that
/// crosses a thread: libxkbcommon is not thread-safe, and smithay refuses a
/// compiled keymap at its own API boundary for exactly that reason
/// (`smithay-0.7.0/src/input/keyboard/mod.rs:810-815`, which recompiles the
/// string inside its own context and says so in a comment).
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct KeymapText(String);

impl KeymapText {
    /// Wraps a keymap, rejecting an empty one.
    ///
    /// An empty keymap compiles to nothing and, uploaded over
    /// `zwp_virtual_keyboard_v1`, is a protocol error that disconnects the
    /// whole client rather than failing the one request.
    #[must_use]
    pub fn new(text: impl Into<String>) -> Option<Self> {
        let text = text.into();
        (!text.trim().is_empty()).then_some(Self(text))
    }

    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }

    /// The text, for an API that takes ownership of a `String`.
    #[must_use]
    pub fn into_string(self) -> String {
        self.0
    }
}

/// Which layout a seat's keyboard is compiled from.
///
/// The five RMLVO names `xkb_keymap_new_from_names` takes. Every one is
/// optional, and absent means the name is taken from [`KeymapDefaults`] — the
/// desktop's own configuration, which is what a user who has configured a
/// layout for their session expects lunette to inherit.
#[derive(Clone, Debug, Default, PartialEq, Eq, Hash)]
pub struct KeymapConfig {
    /// How the remaining four names are interpreted; `"evdev"` on Linux.
    pub rules: Option<String>,
    pub model: Option<String>,
    /// A comma-separated list, one entry per layout the keymap carries.
    pub layout: Option<String>,
    /// A comma-separated list, one entry per layout.
    pub variant: Option<String>,
    /// A comma-separated list of options, such as which key switches layout.
    pub options: Option<String>,
}

/// The names a [`KeymapConfig`] falls back to for a field it leaves absent.
///
/// libxkbcommon resolves an empty RMLVO name from the `XKB_DEFAULT_*`
/// environment variables. A library does not read the environment, so the
/// desktop's own names arrive here as a parameter instead, and the binary is
/// where they are read. That is not only house style: the defaults have to be
/// *nameable* for a multi-layout default to be narrowed to its first entry,
/// and libxkbcommon offers no way to ask a compiled keymap which RMLVO layout
/// it came from.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct KeymapDefaults(KeymapConfig);

impl KeymapDefaults {
    #[must_use]
    pub const fn new(names: KeymapConfig) -> Self {
        Self(names)
    }

    #[must_use]
    pub const fn names(&self) -> &KeymapConfig {
        &self.0
    }
}

impl Default for KeymapDefaults {
    /// libxkbcommon's own compiled-in layout, spelled out.
    ///
    /// Spelled rather than left absent so that a caller which has not read the
    /// environment — every test, and any embedder that does not want the
    /// desktop's configuration — gets the same single-group keymap on every
    /// machine. The binary replaces this with what it read from `XKB_DEFAULT_*`.
    fn default() -> Self {
        Self(KeymapConfig {
            layout: Some("us".to_owned()),
            ..KeymapConfig::default()
        })
    }
}

/// How long a held key waits, and how fast it then repeats.
///
/// Policy rather than mechanism: WayVR fixes it at seat construction
/// (`mod.rs:262`), and `docs/input.md:56` puts it in Lua because it is timing
/// that should differ per input device. This carries what Lua chose.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct RepeatPolicy {
    pub delay: RepeatDelay,
    pub rate: RepeatRate,
}

impl Default for RepeatPolicy {
    /// WayVR's values (`mod.rs:262`), which are also what most desktops ship.
    fn default() -> Self {
        Self {
            delay: RepeatDelay::from_millis(200),
            rate: RepeatRate::per_second(50),
        }
    }
}

/// How long a key is held before it starts repeating, in milliseconds.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct RepeatDelay(u16);

impl RepeatDelay {
    /// Saturating at `u16::MAX`, which is a little over a minute — long enough
    /// that a caller asking for more meant "never", and short enough that the
    /// value fits the `i32` the protocol carries without a cast that can wrap.
    #[must_use]
    pub const fn from_millis(millis: u32) -> Self {
        Self(if millis > u16::MAX as u32 {
            u16::MAX
        } else {
            millis as u16
        })
    }

    #[must_use]
    pub const fn millis(self) -> i32 {
        self.0 as i32
    }
}

/// How many times a second a held key repeats. Zero disables repeat, which is
/// what `wl_keyboard.repeat_info` defines zero to mean.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct RepeatRate(u16);

impl RepeatRate {
    #[must_use]
    pub const fn per_second(rate: u32) -> Self {
        Self(if rate > u16::MAX as u32 {
            u16::MAX
        } else {
            rate as u16
        })
    }

    #[must_use]
    pub const fn get(self) -> i32 {
        self.0 as i32
    }
}

/// Everything a seat's keyboard is created with.
///
/// A parameter struct rather than two more arguments on the seat command: the
/// keymap and the repeat policy are one cohesive decision Lua makes, and they
/// travel together to the one place that applies them.
#[derive(Clone, Debug, Default, PartialEq, Eq, Hash)]
pub struct KeyboardConfig {
    pub keymap: KeymapConfig,
    pub repeat: RepeatPolicy,
}

/// A state an xdg-toplevel can be in.
///
/// Spelled as the protocol spells it, `Maximized` rather than the British form,
/// so a reader comparing this against `xdg_toplevel.state` is not made to
/// translate.
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

/// The set of states a toplevel is in.
pub type ToplevelStates = EnumSet<ToplevelState>;

/// The set of modifiers a seat is holding.
pub type ModifierState = EnumSet<KeyModifier>;

/// A deduplicated set of a small closed enum, kept in sorted order.
///
/// Sorting is what makes equality set equality: two sets built in different
/// orders compare equal, so a snapshot does not report a change because the
/// same states arrived in a different sequence. The inline capacity covers the
/// common case — a toplevel is rarely in more than four states at once, and a
/// seat rarely holds more than four modifiers — without an allocation.
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

    /// Adds an item, reporting whether the set changed.
    pub fn insert(&mut self, item: T) -> bool {
        match self.items.binary_search(&item) {
            Ok(_) => false,
            Err(index) => {
                self.items.insert(index, item);
                true
            }
        }
    }

    /// Removes an item, reporting whether the set changed.
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

/// Declares an identifier newtype over a non-zero integer.
///
/// Six identifiers with the same shape earn one definition. The `new`
/// constructor is what makes a round trip through a boundary that can only
/// carry an integer — Lua, a log line, a control-socket reply — checked rather
/// than assumed.
macro_rules! identifier {
    ($($(#[$documentation:meta])* $name:ident;)*) => {
        $(
            $(#[$documentation])*
            #[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
            pub struct $name(NonZeroU64);

            impl $name {
                /// Wraps a raw identifier, rejecting zero.
                #[must_use]
                pub const fn new(raw: u64) -> Option<Self> {
                    match NonZeroU64::new(raw) {
                        Some(raw) => Some(Self(raw)),
                        None => None,
                    }
                }

                /// The raw identifier, for a boundary with no room for the type.
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
    /// A mapped toplevel.
    WindowId;
    /// A `wl_surface`. A window has one, and so does every subsurface and popup
    /// beneath it, which is why this is not the same identifier as a window.
    SurfaceId;
    /// A `wl_seat`: one pointer, one keyboard, one focus.
    SeatId;
    /// Somewhere pixel-space input can be delivered. A window has one, and so
    /// does a mirrored monitor, so a caller routing input does not have to know
    /// which it is holding.
    SinkId;
    /// A virtual monitor.
    OutputId;
    /// A process lunette started or adopted.
    ProcessId;
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
        // The compiler is what enforces this; the test states the intent so
        // that collapsing the newtypes into an alias fails visibly.
        let window = WindowId::new(1).expect("non-zero");
        let surface = SurfaceId::new(1).expect("non-zero");
        assert_eq!(window.get(), surface.get());
    }

    #[test]
    fn a_pid_rejects_zero_and_negatives() {
        assert_eq!(Pid::new(0), None);
        assert_eq!(Pid::new(-1), None);
        assert_eq!(Pid::new(i32::MIN), None);
        assert_eq!(Pid::new(7).map(Pid::get), Some(7));
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
    fn an_argv_rejects_an_empty_list() {
        assert_eq!(Argv::from_list(Vec::new()), None);
    }

    #[test]
    fn an_argv_splits_a_list_into_a_program_and_its_arguments() {
        let argv = Argv::from_list(vec![
            OsString::from("foot"),
            OsString::from("-e"),
            OsString::from("htop"),
        ])
        .expect("a non-empty list is accepted");

        assert_eq!(argv.program(), OsStr::new("foot"));
        assert_eq!(
            argv.arguments(),
            [OsString::from("-e"), OsString::from("htop")]
        );
    }

    #[test]
    fn an_argv_of_one_has_no_arguments() {
        let argv = Argv::from_list(vec![OsString::from("foot")]).expect("non-empty");

        assert_eq!(argv.program(), OsStr::new("foot"));
        assert!(argv.arguments().is_empty());
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
