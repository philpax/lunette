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
//! # Declaration types vs expression types
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
///     WINDOW_OPENED = lunwindowopened(_lua, session)
///         as WindowOpenedEvent via onWindowOpened
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
            $constant:ident = $name:ident($lua:ident, $session:ident)
                as $record:ident via $register:ident
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

        /// Which function a listener for this event subscribed through, for
        /// naming the handler that raised.
        fn registrar(name: EventName) -> &'static str {
            match name.as_str() {
                $(_ if name.as_str() == stringify!($name) => stringify!($register),)+
                _ => "a listener",
            }
        }

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

            impl $crate::lua::declarations::Typed for $record {
                fn luau() -> $crate::lua::declarations::Type {
                    $crate::lua::declarations::Type::Named(stringify!($record))
                }
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

        /// The module functions a configuration subscribes through.
        ///
        /// One per event, rather than one taking a name: a function per event
        /// is what lets the handler's own parameter be typed, and a name would
        /// be a string the checker could not hold to the set.
        pub(crate) fn subscription_functions<T: $crate::lua::LuaTexture>()
        -> Vec<$crate::lua::ModuleFunction<T>> {
            vec![$(
                $crate::lua::ModuleFunction {
                    spec: $crate::lua::declarations::FunctionSpec {
                        name: stringify!($register),
                        doc: "Calls `handler` whenever this event is delivered, and answers \
                              the function that stops it. Every listener is called, in the order \
                              they subscribed, and a soft reload forgets all of them.",
                    },
                    ty: || {
                        let handler = $crate::lua::declarations::Type::Function {
                            receiver: None,
                            parameters: vec![$crate::lua::declarations::Parameter {
                                name: "event",
                                ty: $crate::lua::declarations::of::<$record>(),
                            }],
                            returns: Box::new($crate::lua::declarations::of::<()>()),
                        };
                        let cancel = $crate::lua::declarations::Type::Function {
                            receiver: None,
                            parameters: Vec::new(),
                            returns: Box::new($crate::lua::declarations::of::<()>()),
                        };
                        $crate::lua::declarations::function_type(
                            None,
                            &["handler"],
                            &[handler],
                            cancel,
                        )
                    },
                    build: |lua, session| {
                        let held = ::std::rc::Rc::clone(session);
                        lua.create_function(move |lua, handler: ::mlua::Function| {
                            let id = held.subscribe($constant, handler);
                            let cancelling = ::std::rc::Rc::clone(&held);
                            lua.create_function(move |_, ()| {
                                cancelling.unsubscribe(id);
                                Ok(())
                            })
                        })
                    },
                },
            )+]
        }
    };
}

pub(crate) use events;
