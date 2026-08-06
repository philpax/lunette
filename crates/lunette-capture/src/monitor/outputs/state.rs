//! What the host has said about its outputs, and the monitors that come out.
//!
//! The pure half of [`crate::monitor::outputs`]. Every method here takes what a
//! Wayland event carried and records it; no Wayland type appears in a signature,
//! which is what lets the decisions — the logical-geometry fallback, the axis
//! swap, which outputs are complete enough to be monitors — be exercised with no
//! display at all.

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
/// A newtype because it shares a numeric space with every other kind of Wayland
/// name and means nothing outside this module.
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
///
/// Pure over plain data: every method takes what an event carried and records
/// it, and [`Self::roster`] turns the accumulation into monitors. No Wayland
/// type appears in the signatures, which is what lets the whole of the decision
/// making — the logical-geometry fallback, the axis swap, which outputs are
/// complete enough to be monitors — be exercised with no display at all.
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
    /// Announcing one twice is not an error: the compositor does not do it, and
    /// answering by keeping what is already recorded is better than discarding
    /// events that have already arrived.
    pub fn add(&mut self, output: OutputId) {
        if self.find(output).is_some() {
            return;
        }
        self.outputs.push((output, PendingOutput::default()));
        self.changed = true;
    }

    /// Stops tracking an output the registry withdrew. Reports whether it was
    /// one.
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
    /// [`MonitorName::new`], which is the one place that decides what counts as
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
            // Refused rather than defaulted: a transform outside the protocol's
            // eight would put the cursor in the wrong corner, and the previous
            // value is at least one the compositor once sent.
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
    /// A mode that is not current describes what the output could be switched
    /// to, and is ignored rather than overwriting what it is.
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

    /// `wl_output.scale`: the integer scale, for the fallback that has no
    /// `zxdg_output_v1` to ask.
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
    /// An output that has not yet said enough to be placed on the desktop is
    /// left out rather than given a guessed geometry. That is the ordinary state
    /// of an output between its announcement and its first `done`, so it is not
    /// reported as a fault; a monitor that stays incomplete appears in no
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
    /// Integer division, because `wl_output.scale` is an integer. A compositor
    /// applying a fractional scale reports the nearest integer here and the true
    /// logical size through `zxdg_output_v1`, so this is wrong exactly where the
    /// better source is available and is not used.
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
