//! Linux-only: the input sink handle Lua holds.
//!
//! A sink takes pixel coordinates. Everything above it — the ray, the plane
//! intersection, the conversion from a surface hit to a pixel — is Lua's, and
//! is why `docs/input.md` puts the native boundary exactly here: Rust knows
//! nothing about the scene, so an input method it has never heard of works
//! without a change on this side.

use std::rc::Rc;

use lunette_compositor::{
    protocol::{Command, PixelPoint, SinkId},
    state::DEFAULT_SEAT,
};
use mlua::{UserData, UserDataFields, UserDataMethods};

use crate::lua::{POINTER_BUTTONS, Session, pointer_button};

/// Somewhere pixel-space input can be delivered.
#[derive(Debug)]
pub struct Sink<T> {
    id: SinkId,
    session: Rc<Session<T>>,
}

impl<T> Sink<T> {
    pub(crate) fn new(session: Rc<Session<T>>, id: SinkId) -> Self {
        Self { id, session }
    }

    /// Whether anything is still listening.
    ///
    /// A sink belongs to the window that owns it, so it is alive exactly while
    /// that window is in the snapshot. Delivering to a sink whose window has
    /// gone is not an error a script should have to guard against — a client
    /// can exit between the raycast and the click.
    fn alive(&self) -> bool {
        self.session
            .snapshot()
            .windows
            .iter()
            .any(|window| window.sink == self.id)
    }
}

impl<T: 'static> UserData for Sink<T> {
    fn add_fields<F: UserDataFields<Self>>(fields: &mut F) {
        fields.add_field_method_get("id", |_, sink| Ok(sink.id.get()));
        fields.add_field_method_get("dead", |_, sink| Ok(!sink.alive()));
    }

    fn add_methods<M: UserDataMethods<Self>>(methods: &mut M) {
        methods.add_method("pointer", |_, sink, (x, y): (f64, f64)| {
            let position = pixel_point(x, y)?;
            if !sink.alive() {
                return Ok(false);
            }

            sink.session.queue(Command::Pointer {
                seat: DEFAULT_SEAT,
                sink: sink.id,
                position,
            });
            Ok(true)
        });

        methods.add_method(
            "button",
            |_, sink, (name, pressed): (mlua::LuaString, bool)| {
                let name = name.to_string_lossy();
                let button = pointer_button(&name).ok_or_else(|| {
                    mlua::Error::runtime(format!(
                        "lunette: '{name}' is not a pointer button; the buttons are \
                         {POINTER_BUTTONS}"
                    ))
                })?;
                if !sink.alive() {
                    return Ok(false);
                }

                sink.session.queue(Command::Button {
                    seat: DEFAULT_SEAT,
                    sink: sink.id,
                    button,
                    pressed,
                });
                Ok(true)
            },
        );
    }
}

/// Checks a coordinate before it is sent to a client.
///
/// A `NaN` reaching a client's pointer handler is a defect in the caller's
/// maths — an intersection against a degenerate plane, usually — and it is
/// worth reporting where it was produced rather than letting a toolkit decide
/// what to do with it. Validated before the liveness check, so a typo is
/// reported whether or not the window happens to still be there.
fn pixel_point(x: f64, y: f64) -> mlua::Result<PixelPoint> {
    if !x.is_finite() || !y.is_finite() {
        return Err(mlua::Error::runtime(format!(
            "lunette: ({x}, {y}) is not a pixel coordinate"
        )));
    }

    Ok(PixelPoint::new(x, y))
}
