//! The compositor's start-up configuration and its default seat and output.

use smithay::backend::allocator::Format;

use crate::{
    protocol::{KeymapDefaults, OutputId, OutputMode, OutputScale, PixelSize, RefreshRate, SeatId},
    selection::HostSelectionSource,
    wayvr::client::{WaylandEnv, XwaylandSatellite},
};

/// The seat used when a command does not name a specific seat.
///
/// Further seats use identifiers supplied through [`crate::protocol::Command::CreateSeat`].
pub const DEFAULT_SEAT: SeatId = match SeatId::new(1) {
    Some(seat) => seat,
    None => unreachable!(),
};

/// The output used when a client has no output assignment.
///
/// Further outputs use identifiers supplied through
/// [`crate::protocol::Command::CreateOutput`].
pub const DEFAULT_OUTPUT: OutputId = match OutputId::new(1) {
    Some(output) => output,
    None => unreachable!(),
};

/// The default seat's name, which clients see on `wl_seat.name`.
pub(crate) const SEAT_NAME: &str = "lunette";

/// Configuration for the virtual monitor, buffer support, host selection, X11
/// bridge, and default keymap.
///
/// The output size is configurable, so this value provides defaults.
#[derive(Debug)]
pub struct CompositorConfig {
    pub output: OutputMode,
    pub dmabuf: DmabufSupport,
    /// How the host desktop's clipboard is reached. Absent keeps selections
    /// inside lunette.
    pub host_selection: Option<Box<dyn HostSelectionSource>>,
    /// The display lunette uses. Absent when no socket is bound.
    pub display: Option<WaylandEnv>,
    /// Where to find xwayland-satellite. When absent, X11 clients are disabled.
    pub satellite: Option<XwaylandSatellite>,
    /// The desktop's own keyboard layout, which a seat that names none inherits.
    /// The binary reads it from the environment; nothing in this crate does.
    pub keymap_defaults: KeymapDefaults,
}

impl Default for CompositorConfig {
    fn default() -> Self {
        Self {
            output: OutputMode {
                size: PixelSize::new(2560, 1440),
                scale: OutputScale::new(1.0).unwrap_or_else(|| unreachable!("one is positive")),
                refresh: RefreshRate::from_millihertz(60_000),
            },
            dmabuf: DmabufSupport::default(),
            host_selection: None,
            display: None,
            satellite: None,
            keymap_defaults: KeymapDefaults::default(),
        }
    }
}

/// What lunette can accept over `zwp_linux_dmabuf_v1`.
///
/// Both fields come from the graphics device, which this crate does not have,
/// so they arrive as a parameter. Without a device (in a test, or on a machine
/// whose driver lacks the import extensions), the global is still advertised
/// with no formats, and clients fall back to `wl_shm`.
#[derive(Clone, Debug, Default)]
pub struct DmabufSupport {
    /// The DRM render node for these formats. Version 4 feedback requires it.
    pub main_device: Option<RenderNode>,
    pub formats: Vec<Format>,
}

/// A DRM render node, as the `st_rdev` of its device file.
///
/// Wrapping `libc::dev_t` prevents confusing a device number with its major or
/// minor component.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct RenderNode(libc::dev_t);

impl RenderNode {
    /// Builds a device number from the major and minor a Vulkan
    /// `VkPhysicalDeviceDrmPropertiesEXT` reports.
    #[must_use]
    pub fn from_major_minor(major: u32, minor: u32) -> Self {
        Self(libc::makedev(major, minor))
    }

    #[must_use]
    pub const fn get(self) -> libc::dev_t {
        self.0
    }
}
