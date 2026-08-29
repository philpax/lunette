//! The form an event is declared in.
//!
//! [`events!`] takes one declaration per event and generates the name the
//! dispatcher installs, the arm that builds the payload, and the declaration of
//! what the payload holds. The field a handler reads and the expression that
//! fills it are one line. The checker reads the type that line carries.
//!
//! # What a payload field's type annotates
//!
//! The annotation is the type the declaration renders, and the expression
//! beside it produces the value. The compiler does not require the two to
//! match: a payload is a Lua table, so the expression must be convertible to
//! Lua, and the handles are generic over the texture while a rendered
//! declaration names one. [`Window<NullTexture>`](crate::Window) is the
//! annotation for a field carrying a window, whatever texture the session
//! holds.

/// Declares every `lun*` event: its name, the variant it is built from, and the
/// fields its payload carries.
///
/// Generates `EVENT_NAMES`, the payload builder, and a [`Record`] per event for
/// the declarations.
///
/// The contract at the invocation site must hold:
///
/// - the `as` name is the declaration the payload is rendered as;
/// - the `via` name is the function a listener subscribes through, and the name
///   a raised handler is reported under;
/// - a field never uses a value the declaration's type cannot hold, because the
///   checker reads that type.
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

        /// The function a listener for this event subscribed through, for
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

        /// The one table a `lun*` handler is called with.
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
        /// One per event. A function per event lets the handler's own parameter
        /// be typed; a single function taking a name would pass a string the
        /// checker could not hold to the set.
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
