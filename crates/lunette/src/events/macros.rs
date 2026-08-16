//! The form an event is declared in.
//!
//! An event was three statements: a name in the list the dispatcher installs
//! from, an arm building its payload, and a declaration of what that payload
//! holds. The first two agreed because they were edited together; the third was
//! `any`, so nothing was declared and nothing could disagree.
//!
//! [`events!`] takes one declaration per event and generates all three. The
//! field a handler reads and the expression that fills it are one line, and the
//! type that line carries is what the checker is told.
//!
//! # What a payload field's type annotates
//!
//! The annotation is the type the *declaration* renders, and the expression
//! beside it produces the value. They are written together and read together,
//! but the compiler does not tie them: a payload is a Lua table, so the
//! expression only has to be convertible, and the handles are generic over the
//! texture while a rendered declaration names one. `Window<NullTexture>` is
//! therefore what a field carrying a window is annotated with, whatever texture
//! the session actually holds.

/// Declares every `lun*` event: its name, the variant it is built from, and the
/// fields its payload carries.
///
/// Generates `EVENT_NAMES`, the payload builder, and a [`Record`] per event for
/// the declarations.
///
/// ```text
/// events! {
///     /// A toplevel was mapped.
///     WINDOW_OPENED = lunwindowopened(_lua, session) as WindowOpenedEvent
///         from LuaEvent::WindowOpened { window } =>
///     {
///         /// The window that opened.
///         window: Window<NullTexture> = Window::for_id(Rc::clone(session), *window),
///     }
/// }
/// ```
///
/// [`Record`]: crate::lua::declarations::Record
macro_rules! events {
    (
        $(
            $(#[doc = $doc:literal])*
            $constant:ident = $name:ident($lua:ident, $session:ident) as $record:ident
                from $variant:pat =>
            {
                $(
                    $(#[doc = $field_doc:literal])*
                    $field:ident: $field_ty:ty = $value:expr
                ),* $(,)?
            }
        )+
    ) => {
        $(
            $(#[doc = $doc])*
            pub(crate) const $constant: EventName = event_name(stringify!($name));
        )+

        /// The `lun*` events this build delivers, and the order they are
        /// installed in.
        pub const EVENT_NAMES: &[EventName] = &[$($constant),+];

        /// The single table a `lun*` handler is called with.
        fn payload<T: LuaTexture>(
            lua: &::mlua::Lua,
            session: &::std::rc::Rc<Session<T>>,
            event: &LuaEvent,
        ) -> ::mlua::Result<::mlua::Table> {
            let payload = lua.create_table()?;
            match event {
                $(
                    $variant => {
                        let $lua = lua;
                        let $session = session;
                        $(
                            payload.set(stringify!($field), $value)?;
                        )*
                    }
                )+
            }
            Ok(payload)
        }

        $(
            impl $crate::lua::declarations::Recorded for $record {
                const RECORD: $crate::lua::declarations::Record =
                    $crate::lua::declarations::Record {
                        name: stringify!($record),
                        doc: concat!($($doc),*),
                        fields: &[$(
                            $crate::lua::declarations::RecordField {
                                name: stringify!($field),
                                doc: concat!($($field_doc),*),
                                ty: $crate::lua::declarations::of::<$field_ty>,
                            },
                        )*],
                    };
            }

            $(#[doc = $doc])*
            ///
            /// The table `lovr.
            #[doc = stringify!($name)]
            /// ` is called with.
            #[derive(Debug)]
            pub struct $record;
        )+

        /// Every event's payload, for the declarations to render.
        #[must_use]
        pub fn payload_records() -> Vec<$crate::lua::declarations::Record> {
            vec![$(<$record as $crate::lua::declarations::Recorded>::RECORD),+]
        }
    };
}

pub(crate) use events;
