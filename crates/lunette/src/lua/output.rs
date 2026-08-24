//! Linux-only: the output handle Lua holds.
//!
//! An output is a virtual monitor lunette shows to the clients assigned to it.
//! WayVR has one shared output for everything, which means one scale factor for
//! every application and a client querying its display getting an answer
//! unrelated to the panel it is on; `docs/compositor.md` states why lunette
//! rejects that.
//!
//! # Units
//!
//! `refresh` is hertz here and millihertz on the wire, because hertz is what a
//! user writes and millihertz is what `wl_output.mode` carries. The conversion
//! happens in this module and nowhere else.

use std::{cell::RefCell, rc::Rc};

use lunette_compositor::{
    protocol::{Command, OutputId, OutputMode, OutputScale, OutputSnapshot, RefreshRate},
    state::DEFAULT_OUTPUT,
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

/// One virtual monitor, as Lua holds it.
#[derive(Debug)]
pub struct Output<T> {
    id: OutputId,
    session: Rc<Session<T>>,
    /// The mode this output was last asked for, which is also what it reports
    /// before the compositor has created it and after it has gone.
    mode: RefCell<OutputMode>,
}

impl<T> Output<T> {
    pub(crate) fn new(session: Rc<Session<T>>, snapshot: &OutputSnapshot) -> Self {
        Self {
            id: snapshot.output,
            session,
            mode: RefCell::new(snapshot.mode),
        }
    }

    /// The compositor's identifier, for the calls that name an output.
    pub(crate) const fn id(&self) -> OutputId {
        self.id
    }

    /// Brings the cache up to date, reporting whether the output exists now.
    ///
    /// False both before the compositor has created the output and after it has
    /// been destroyed. The two are indistinguishable from here and a caller
    /// treats them the same way: nothing can be shown on an output that is not
    /// there.
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
    /// A virtual monitor for clients assigned to it.
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

    /// The refresh rate in hertz.
    field refresh(_lua, this) -> f64 {
        this.refresh();
        Ok(hertz(this.mode.borrow().refresh))
    }

    /// Changes the mode, preserving fields omitted from the options.
    method setMode(_lua, this, mode: Options<SetMode>) -> bool { set_mode(this, &mode) }

    /// Destroys this output, except for the default output.
    method destroy(_lua, this) -> bool { Ok(destroy(this)) }
}

/// Creates an output from a size, scale, and refresh rate; the handle is dead until the next snapshot.
///
/// # Errors
///
/// If a dimension is invalid, a rate is not finite and positive, or an option is unknown.
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

/// Returns every output in the current frame's snapshot.
///
/// # Errors
///
/// If the output list cannot be built.
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

/// Changes the mode, preserving fields omitted from the options.
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

/// Destroys the output, except for the default output.
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

/// Reads an output mode, using the current mode for omitted fields and defaults for creation.
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
    /// The optional fields changed by `output:setMode`.
    options SetMode as OutputMode {
        width: Option<f64>,
        height: Option<f64>,
        scale: Option<f64>,
        refresh: Option<f64>,
    }
}

record! {
    /// The options for `lunette.newOutput`; width and height are required.
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

/// A refresh rate in hertz as the millihertz the protocol carries.
fn millihertz(hertz: f64) -> mlua::Result<RefreshRate> {
    let scaled = hertz * 1_000.0;
    // The bound is what makes the cast exact: a finite value in `1 ..= u32::MAX`
    // is representable in both.
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

/// A refresh rate in millihertz as the hertz Lua reads.
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
