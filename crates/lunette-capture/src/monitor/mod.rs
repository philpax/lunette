//! Which physical monitors exist, and which one a mirror belongs to.

pub mod geometry;
pub mod name;
pub mod roster;

pub use self::{
    geometry::{LogicalGeometry, LogicalPosition, LogicalSize},
    name::{ConnectorKind, ConnectorName, Descriptor, KeyStrength, MonitorKey, MonitorName},
    roster::{Monitor, Roster},
};
