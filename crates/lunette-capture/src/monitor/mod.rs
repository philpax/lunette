//! Which physical monitors exist, and which one a mirror belongs to.

pub mod geometry;
pub mod name;
pub mod roster;

pub use self::{
    geometry::LogicalPosition,
    name::{ConnectorKind, ConnectorName, Descriptor, KeyStrength, MonitorKey, MonitorName},
    roster::{Monitor, Roster},
};
