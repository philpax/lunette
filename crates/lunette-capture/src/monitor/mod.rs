//! Which physical monitors exist, and which one a mirror belongs to.

pub mod geometry;
pub mod name;
#[cfg(target_os = "linux")]
pub mod outputs;
pub mod roster;

#[cfg(target_os = "linux")]
pub use outputs::{HostOutputs, OutputError, OutputId, OutputWatcher};

pub use self::{
    geometry::{LogicalGeometry, LogicalPosition, LogicalSize, PixelExtent, SurfaceTransform},
    name::{ConnectorKind, ConnectorName, Descriptor, KeyStrength, MonitorKey, MonitorName},
    roster::{Monitor, MonitorReport, Roster},
};
