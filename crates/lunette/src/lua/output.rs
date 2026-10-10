//! Linux-only: implements virtual output handles for Lua.
//!
//! Each output has its own size, scale, and refresh rate. Lua expresses refresh rates in hertz; the
//! Wayland protocol uses millihertz.

use std::{cell::RefCell, rc::Rc};

use lunette_compositor::{
    config::DEFAULT_OUTPUT,
    protocol::{Command, OutputId, OutputMode, OutputScale, OutputSnapshot, RefreshRate},
};
use mlua::{Lua, Table};

use crate::{
    control::wire::HandleKind,
    lua::{
        LuaTexture, Session,
        declarations::{Options, handle, record},
        pixel_size,
    },
};

/// An output is one virtual monitor, as Lua holds it.
#[derive(Debug)]
pub struct Output<T> {
    id: OutputId,
    session: Rc<Session<T>>,
    /// The last mode requested or seen, reported while the snapshot does not list the output.
    mode: RefCell<OutputMode>,
}

/// Two handles are equal when they name the same output.
impl<T> PartialEq for Output<T> {
    fn eq(&self, other: &Self) -> bool {
        self.id == other.id
    }
}

impl<T> Output<T> {
    pub(crate) fn new(session: Rc<Session<T>>, snapshot: &OutputSnapshot) -> Self {
        Self {
            id: snapshot.output,
            session,
            mode: RefCell::new(snapshot.mode),
        }
    }

    pub(crate) const fn id(&self) -> OutputId {
        self.id
    }

    /// Refreshes the cached mode and returns whether the output exists in the current snapshot.
    fn refresh(&self) -> bool {
        let snapshot = self.session.snapshot();
        let Some(current) = snapshot
            .outputs
            .iter()
            .find(|output| output.output == self.id)
        else {
            return false;
        };
        *self.mode.borrow_mut() = current.mode;
        true
    }
}

handle! {
    /// A virtual monitor that the clients assigned to it lay out against.
    Output<T: LuaTexture> = HandleKind::Output;

    field id(_lua, this) -> u64 { Ok(this.id.get()) }

    field dead(_lua, this) -> bool { Ok(!this.refresh()) }

    field width(_lua, this) -> u32 {
        this.refresh();
        Ok(this.mode.borrow().size.width)
    }

    field height(_lua, this) -> u32 {
        this.refresh();
        Ok(this.mode.borrow().size.height)
    }

    field scale(_lua, this) -> f64 {
        this.refresh();
        Ok(this.mode.borrow().scale.get())
    }

    /// The refresh rate in hertz. The protocol carries millihertz.
    field refresh(_lua, this) -> f64 {
        this.refresh();
        Ok(hertz(this.mode.borrow().refresh))
    }

    /// Changes the mode, keeping the fields the table does not name. Clients
    /// reallocate and re-lay-out in response.
    method setMode(_lua, this, mode: Options<SetMode>) -> bool { set_mode(this, &mode) }

    /// Withdraws the output's `wl_output` global. The default output is
    /// refused, because a client assigned no output is shown it.
    method destroy(_lua, this) -> bool { Ok(destroy(this)) }
}

/// `lunette.newOutput{ width = 1920, height = 1080, scale = 1.5, refresh = 90 }`.
///
/// The handle is dead until a later frame's snapshot lists the output.
///
/// # Errors
///
/// The call fails when a dimension is not a whole pixel count, when the scale
/// or refresh rate is not finite and positive, or when an option is not one
/// this call takes.
pub(crate) fn new_output<T: LuaTexture>(
    session: &Rc<Session<T>>,
    options: &Options<NewOutput>,
) -> mlua::Result<Output<T>> {
    let mode = read_mode(options.table(), None)?;
    let id = session
        .mint_output()
        .ok_or_else(|| mlua::Error::runtime("lunette: the output identifier space is exhausted"))?;

    session.queue(Command::CreateOutput { output: id, mode });

    Ok(Output {
        id,
        session: Rc::clone(session),
        mode: RefCell::new(mode),
    })
}

/// `lunette.outputs()`: every output, as of this frame's snapshot.
///
/// # Errors
///
/// The call fails if the table could not be built.
pub(crate) fn outputs<T: LuaTexture>(
    _lua: &Lua,
    session: &Rc<Session<T>>,
) -> mlua::Result<Vec<Output<T>>> {
    let snapshot = session.snapshot();
    Ok(snapshot
        .outputs
        .iter()
        .map(|output| Output::new(Rc::clone(session), output))
        .collect())
}

/// Changes the output mode while preserving fields omitted from the options.
fn set_mode<T: LuaTexture>(output: &Output<T>, options: &Options<SetMode>) -> mlua::Result<bool> {
    let current = *output.mode.borrow();
    let mode = read_mode(options.table(), Some(current))?;

    if !output.refresh() {
        return Ok(false);
    }
    *output.mode.borrow_mut() = mode;
    output.session.queue(Command::ReconfigureOutput {
        output: output.id,
        mode,
    });
    Ok(true)
}

/// Withdraws a virtual output, except for the default output required by clients without an
/// assignment.
fn destroy<T: LuaTexture>(output: &Output<T>) -> bool {
    if output.id == DEFAULT_OUTPUT {
        return false;
    }
    if !output.refresh() {
        return false;
    }

    output
        .session
        .queue(Command::DestroyOutput { output: output.id });
    true
}

/// Builds an output mode from options, preserving omitted fields when `current` is present.
///
/// Creation requires a size and defaults scale to 1 and refresh to 60 Hz.
fn read_mode(options: &Table, current: Option<OutputMode>) -> mlua::Result<OutputMode> {
    let held = current.map(|current| current.size);
    let width = options
        .get::<Option<f64>>("width")?
        .or_else(|| held.map(|size| f64::from(size.width)));
    let height = options
        .get::<Option<f64>>("height")?
        .or_else(|| held.map(|size| f64::from(size.height)));

    let size = match (width, height) {
        (Some(width), Some(height)) => pixel_size(width, height, "size in pixels")?,
        _ => {
            return Err(mlua::Error::runtime(
                "lunette: an output needs a width and a height; a monitor with no size is not one \
                 a client can lay out against",
            ));
        }
    };

    let scale = match options.get::<Option<f64>>("scale")? {
        Some(scale) => OutputScale::new(scale).ok_or_else(|| {
            mlua::Error::runtime(format!(
                "lunette: {scale} is not an output scale; a scale is finite and greater than zero, \
                 and a client told its monitor has a scale of zero divides by it"
            ))
        })?,
        None => current.map_or(DEFAULT_SCALE, |current| current.scale),
    };

    let refresh = match options.get::<Option<f64>>("refresh")? {
        Some(hertz) => millihertz(hertz)?,
        None => current.map_or(DEFAULT_REFRESH, |current| current.refresh),
    };

    Ok(OutputMode {
        size,
        scale,
        refresh,
    })
}

record! {
    /// Optional output fields. Omitted fields retain their current values.
    options SetMode as OutputMode {
        width: Option<f64>,
        height: Option<f64>,
        scale: Option<f64>,
        refresh: Option<f64>,
    }
}

record! {
    /// Output creation options. Width and height are required.
    options NewOutput as OutputOptions {
        width: f64,
        height: f64,
        scale: Option<f64>,
        refresh: Option<f64>,
    }
}

/// The scale an output that names none takes.
const DEFAULT_SCALE: OutputScale = OutputScale::ONE;

/// The refresh rate an output that names none takes.
const DEFAULT_REFRESH: RefreshRate = RefreshRate::from_millihertz(60_000);

/// Converts the refresh rate in hertz to the millihertz the protocol carries.
fn millihertz(hertz: f64) -> mlua::Result<RefreshRate> {
    let scaled = hertz * 1_000.0;
    // The bound makes the cast exact. A finite value in `1 ..= u32::MAX` is representable in both.
    if !(scaled.is_finite() && scaled >= 1.0 && scaled <= f64::from(u32::MAX)) {
        return Err(mlua::Error::runtime(format!(
            "lunette: {hertz} is not a refresh rate; a rate is finite and at least one millihertz"
        )));
    }

    #[expect(
        clippy::cast_possible_truncation,
        clippy::cast_sign_loss,
        reason = "the bound above is what makes the cast exact"
    )]
    Ok(RefreshRate::from_millihertz(scaled.round() as u32))
}

/// Converts the refresh rate in millihertz to the hertz Lua reads.
fn hertz(refresh: RefreshRate) -> f64 {
    f64::from(refresh.millihertz()) / 1_000.0
}

#[cfg(test)]
#[expect(
    clippy::expect_used,
    reason = "a failed expectation is how a test reports a failure; the ban is on production code"
)]
mod tests {
    use super::*;

    #[test]
    fn hertz_and_millihertz_round_trip_through_the_boundary() {
        for rate in [1.0, 30.0, 59.94, 60.0, 90.0, 120.0, 144.0] {
            let converted = millihertz(rate).expect("the rate is a positive finite number");
            assert!(
                (hertz(converted) - rate).abs() < 0.001,
                "{rate} hertz did not survive the conversion"
            );
        }
    }

    #[test]
    fn a_refresh_rate_that_is_not_a_rate_is_refused() {
        for rate in [0.0, -60.0, f64::NAN, f64::INFINITY, 0.0009] {
            assert!(
                millihertz(rate).is_err(),
                "{rate} was accepted as a refresh rate"
            );
        }
    }
}
