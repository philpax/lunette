//! What the host has said about its outputs, and the resulting monitors.
//!
//! The pure half of [`crate::monitor::outputs`]. Every method here takes what a
//! Wayland event carried and records it; no Wayland type appears in a signature,
//! which is what lets the decisions be exercised with no display at all: the
//! logical-geometry fallback, the axis swap, and which outputs are complete
//! enough to be monitors.

use std::fmt;

use tracing::{debug, warn};

use crate::monitor::{
    geometry::{LogicalGeometry, LogicalPosition, LogicalSize, PixelExtent, SurfaceTransform},
    name::{ConnectorName, MonitorName},
    roster::{MonitorReport, Roster},
};

/// Which output an event belongs to.
///
/// The registry's own global name, which is what `wl_registry.global_remove`
/// carries and so the only identifier that survives an output being unplugged.
/// It is a newtype because it shares a numeric space with every other kind of
/// Wayland name and means nothing outside this module.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct OutputId(u32);

impl OutputId {
    #[must_use]
    pub const fn new(name: u32) -> Self {
        Self(name)
    }

    #[must_use]
    pub const fn get(self) -> u32 {
        self.0
    }
}

impl fmt::Display for OutputId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "output {}", self.0)
    }
}

/// What the host has said about its outputs so far.
#[derive(Clone, Debug, Default)]
pub struct HostOutputs {
    /// In registry order, which is the order the compositor announced them. The
    /// roster sorts by identity afterwards, so this order is not load-bearing;
    /// keeping it stable only makes the logs readable.
    outputs: Vec<(OutputId, PendingOutput)>,
    changed: bool,
}

impl HostOutputs {
    #[must_use]
    pub const fn new() -> Self {
        Self {
            outputs: Vec::new(),
            changed: false,
        }
    }

    /// Begins tracking an output the registry announced.
    ///
    /// Announcing one twice keeps the existing record. The registry never
    /// announces the same output twice, and starting over would discard what
    /// has already arrived.
    pub fn add(&mut self, output: OutputId) {
        if self.find(output).is_some() {
            return;
        }
        self.outputs.push((output, PendingOutput::default()));
        self.changed = true;
    }

    /// Stops tracking an output the registry withdrew, reporting whether it
    /// was being tracked.
    pub fn remove(&mut self, output: OutputId) -> bool {
        let Some(index) = self
            .outputs
            .iter()
            .position(|(candidate, _)| *candidate == output)
        else {
            return false;
        };

        self.outputs.remove(index);
        self.changed = true;
        true
    }

    /// `wl_output.geometry`: where the output sits, which way up, and what the
    /// EDID says it is.
    ///
    /// An empty make or model arrives here as-is and is discarded by
    /// [`MonitorName::new`], which is the one place that defines what counts as
    /// a reported field.
    pub fn record_geometry(
        &mut self,
        output: OutputId,
        position: LogicalPosition,
        transform: Option<SurfaceTransform>,
        make: String,
        model: String,
    ) {
        let Some(pending) = self.find_mut(output) else {
            return;
        };

        pending.position = position;
        pending.make = Some(make);
        pending.model = Some(model);
        match transform {
            Some(transform) => pending.transform = transform,
            // An unrecognised transform leaves the previous value in place. A
            // transform outside the protocol's eight would put the cursor in
            // the wrong corner, and the previous value is at least one the
            // compositor once sent.
            None => warn!(%output, "the host reported an output transform lunette does not know"),
        }
        self.changed = true;
    }

    /// `wl_output.name`: the connector, on a compositor at `wl_output` version 4.
    pub fn record_name(&mut self, output: OutputId, name: &str) {
        let Some(pending) = self.find_mut(output) else {
            return;
        };

        pending.connector = ConnectorName::parse(name);
        if pending.connector.is_none() {
            debug!(
                %output,
                name,
                "the host's name for this output is not a DRM connector name, so it is not stored \
                 as one",
            );
        }
        self.changed = true;
    }

    /// `wl_output.mode`: the resolution, when the mode is the current one.
    ///
    /// A mode that is not current describes a resolution the output could be
    /// switched to, and is ignored; it does not replace the current one.
    pub fn record_mode(&mut self, output: OutputId, current: bool, pixels: PixelExtent) {
        let Some(pending) = self.find_mut(output) else {
            return;
        };
        if !current {
            return;
        }

        pending.mode = Some(pixels);
        self.changed = true;
    }

    /// `wl_output.scale`: the integer scale, for the fallback used when no
    /// `zxdg_output_v1` is available.
    pub fn record_scale(&mut self, output: OutputId, scale: i32) {
        let Some(pending) = self.find_mut(output) else {
            return;
        };

        pending.scale = scale;
        self.changed = true;
    }

    /// `zxdg_output_v1.logical_position`.
    pub fn record_logical_position(&mut self, output: OutputId, position: LogicalPosition) {
        let Some(pending) = self.find_mut(output) else {
            return;
        };

        pending.logical_position = Some(position);
        self.changed = true;
    }

    /// `zxdg_output_v1.logical_size`.
    pub fn record_logical_size(&mut self, output: OutputId, size: LogicalSize) {
        let Some(pending) = self.find_mut(output) else {
            return;
        };

        pending.logical_size = Some(size);
        self.changed = true;
    }

    /// Whether anything has been recorded since the last [`Self::take_changed`].
    #[must_use]
    pub const fn changed(&self) -> bool {
        self.changed
    }

    /// Clears the change flag, reporting whether it was set.
    pub fn take_changed(&mut self) -> bool {
        std::mem::replace(&mut self.changed, false)
    }

    /// How many outputs are being tracked, complete or not.
    #[must_use]
    pub fn len(&self) -> usize {
        self.outputs.len()
    }

    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.outputs.is_empty()
    }

    /// The monitors, with their identities resolved against one another.
    ///
    /// An output that has not yet reported enough to be placed on the desktop
    /// is left out; it is not given a guessed geometry. That is the ordinary
    /// state between an output's announcement and its first `done`, so it is
    /// not logged as a fault. A monitor that stays incomplete appears in no
    /// roster, which is visible as its absence from `lunette.monitors()`.
    #[must_use]
    pub fn roster(&self) -> Roster {
        let mut roster = Roster::new();
        for (output, pending) in &self.outputs {
            match pending.report() {
                Some(report) => roster.add(report),
                None => debug!(%output, "the host has not yet said where this output is"),
            }
        }
        roster
    }

    fn find(&self, output: OutputId) -> Option<&PendingOutput> {
        self.outputs
            .iter()
            .find_map(|(candidate, pending)| (*candidate == output).then_some(pending))
    }

    fn find_mut(&mut self, output: OutputId) -> Option<&mut PendingOutput> {
        self.outputs
            .iter_mut()
            .find_map(|(candidate, pending)| (*candidate == output).then_some(pending))
    }
}

/// What has been heard about one output so far.
#[derive(Clone, Debug)]
struct PendingOutput {
    connector: Option<ConnectorName>,
    make: Option<String>,
    model: Option<String>,
    transform: SurfaceTransform,
    /// `wl_output.geometry`'s x and y, which is the logical position on every
    /// compositor observed but is superseded by `zxdg_output_v1` where it exists.
    position: LogicalPosition,
    /// The current mode, in the panel's own pixels.
    mode: Option<PixelExtent>,
    /// `wl_output.scale`, which the protocol defines as at least one.
    scale: i32,
    logical_position: Option<LogicalPosition>,
    logical_size: Option<LogicalSize>,
}

impl Default for PendingOutput {
    fn default() -> Self {
        Self {
            connector: None,
            make: None,
            model: None,
            transform: SurfaceTransform::Normal,
            position: LogicalPosition::new(0, 0),
            mode: None,
            scale: 1,
            logical_position: None,
            logical_size: None,
        }
    }
}

impl PendingOutput {
    /// This output as a monitor, or `None` while it has no logical size.
    fn report(&self) -> Option<MonitorReport> {
        let size = self.logical_size.or_else(|| self.derived_size())?;
        let position = self.logical_position.unwrap_or(self.position);

        Some(MonitorReport {
            name: MonitorName::new(self.connector, self.make.clone(), self.model.clone()),
            geometry: LogicalGeometry::new(position, size),
            // The mode as the panel reports it, unrotated. A capture stream
            // reports its own frame size and that is what the texture ends up
            // being; this is what the host says the display is.
            pixels: self.mode.unwrap_or_default(),
            transform: self.transform,
        })
    }

    /// The logical size a compositor without `zxdg_output_manager_v1` implies.
    ///
    /// The division is integer, because `wl_output.scale` is an integer. A
    /// compositor applying a fractional scale reports the nearest integer here
    /// and the true logical size through `zxdg_output_v1`, so the derived size
    /// is wrong exactly where the better source is available and is not used.
    fn derived_size(&self) -> Option<LogicalSize> {
        let mode = self.mode?;
        // The protocol requires at least one. A compositor sending zero or a
        // negative value is describing nothing, and dividing by it would be
        // worse than treating the output as unscaled.
        let scale = u32::try_from(self.scale).ok().filter(|scale| *scale > 0)?;

        let (width, height) = if self.transform.swaps_axes() {
            (mode.height, mode.width)
        } else {
            (mode.width, mode.height)
        };
        Some(LogicalSize::new(width / scale, height / scale))
    }
}
