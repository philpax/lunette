//! Which physical monitors exist, and which one a mirror belongs to.

pub mod geometry;
pub mod name;
pub mod outputs;
pub mod roster;

pub use self::{
    geometry::{LogicalGeometry, LogicalPosition, LogicalSize, PixelExtent, SurfaceTransform},
    name::{ConnectorKind, ConnectorName, Descriptor, KeyStrength, MonitorKey, MonitorName},
    outputs::{HostOutputs, OutputError, OutputId, OutputWatcher},
    roster::{Monitor, MonitorReport, Roster},
};
