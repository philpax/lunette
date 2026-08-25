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
    /// One virtual monitor, which the clients assigned to it lay out against.
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

    /// Hertz, not the millihertz the protocol carries.
    field refresh(_lua, this) -> f64 {
        this.refresh();
        Ok(hertz(this.mode.borrow().refresh))
    }

    /// Changes the mode, keeping the fields the table does not name. Clients reallocate and re-lay-out in response, so a caller that changes this continuously will see them struggle.
    method setMode(_lua, this, mode: Options<SetMode>) -> bool { set_mode(this, &mode) }

    /// Withdraws the output's `wl_output` global. The output every session starts with is refused, because a client assigned no output is shown it.
    method destroy(_lua, this) -> bool { Ok(destroy(this)) }
}

/// `lunette.newOutput{ width = 1920, height = 1080, scale = 1.5, refresh = 90 }`.
///
/// The handle comes back before the compositor has made the output, so
/// `output.dead` is true in the frame that created it — the same rule
/// `lunette.newSeat` and `lunette.spawn` follow.
///
/// # Errors
///
/// If a dimension is not a whole pixel count, the scale or refresh rate is not
/// finite and positive, or an option is not one this call takes.
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
/// If the table could not be built.
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

/// `output:setMode{ … }`: changes the mode, keeping the fields not named.
///
/// Clients reallocate and re-lay-out in response, so a caller that changes this
/// continuously will see them struggle. `mullion` moves between discrete steps
/// with hysteresis for that reason.
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

/// `output:destroy()`: withdraws the output's `wl_output` global.
///
/// The output every session starts with is refused, as the default seat is. A
/// client that was assigned no output is shown it, and every client adopted from
/// outside lunette is one of those, so a session without it has clients that can
/// see no monitor at all. The compositor refuses it too; the check is here as
/// well so a configuration is told rather than left reading the log.
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

/// The mode an option table describes.
///
/// `current` supplies the fields the table does not name, so `setMode{ scale =
/// 2 }` changes the scale and nothing else. Absent for a creation, where width
/// and height are required and the other two take a default: a monitor with no
/// size means nothing, and a monitor with no stated refresh rate is a 60Hz one.
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
    /// What `output:setMode` changes. Every field is optional: what is left out keeps the value the output already has.
    options SetMode as OutputMode {
        width: Option<f64>,
        height: Option<f64>,
        scale: Option<f64>,
        refresh: Option<f64>,
    }
}

record! {
    /// What `lunette.newOutput` takes. The size is required, because there is no previous mode to take it from and a client cannot lay out against an output with no size.
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
