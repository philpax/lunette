//! The forms a surface is declared in.
//!
//! [`handle!`] declares a handle, [`module!`] the module table, and [`record!`]
//! a table of plain fields. Every Luau type derives from the Rust type through
//! [`Typed`](crate::lua::declarations::Typed). Every parameter name is the
//! binding its body uses.

/// Declares a handle, registering it with mlua and describing it to the
/// checker.
///
/// ```text
/// handle! {
///     /// A mapped toplevel.
///     Window<T: LuaTexture> = HandleKind::Window;
///
///     /// Stable for the window's whole life.
///     field id(_lua, this) -> u32 { Ok(this.id.get()) }
///
///     /// Configures the toplevel to a size in pixels.
///     method resize(_lua, this, width: f64, height: f64) -> bool {
///         resize(this, width, height)
///     }
/// }
/// ```
///
/// `method name(lua, this: Textured, …)` names a receiver wider than the handle,
/// for a method reached through a union.
macro_rules! handle {
    (
        $(#[doc = $doc:literal])*
        $name:ident<$generic:ident: $bound:path> = $kind:expr;
        $($items:tt)*
    ) => {
        impl<$generic: $bound> ::mlua::UserData for $name<$generic> {
            fn add_fields<Fields: ::mlua::UserDataFields<Self>>(fields: &mut Fields) {
                $crate::lua::declarations::add_fields(fields);
            }

            fn add_methods<Methods: ::mlua::UserDataMethods<Self>>(methods: &mut Methods) {
                $crate::lua::declarations::add_methods(methods);
            }
        }

        impl<$generic: $bound> $crate::lua::declarations::Typed for $name<$generic> {
            fn luau() -> $crate::lua::declarations::Type {
                $crate::lua::declarations::Type::Named(stringify!($name))
            }
        }

        impl<$generic: $bound> $crate::lua::declarations::Described for $name<$generic> {
            const HANDLE: $crate::lua::declarations::HandleSpec =
                $crate::lua::declarations::HandleSpec {
                    name: stringify!($name),
                    doc: concat!($($doc),*),
                };

            const KIND: $crate::control::wire::HandleKind = $kind;

            fn describe(surface: &mut impl $crate::lua::declarations::Surface<Self>) {
                handle!(@items surface, $($items)*);
            }
        }
    };

    (@items $surface:ident,) => {};

    (@items $surface:ident,
        $(#[doc = $doc:literal])*
        field $field:ident($lua:ident, $this:ident) -> $ty:ty $body:block
        $($rest:tt)*
    ) => {
        $surface.field(
            $crate::lua::declarations::FieldSpec {
                name: stringify!($field),
                doc: concat!($($doc),*),
            },
            |$lua: &::mlua::Lua, $this: &Self| -> ::mlua::Result<$ty> { $body },
        );
        handle!(@items $surface, $($rest)*);
    };

    (@items $surface:ident,
        $(#[doc = $doc:literal])*
        method $method:ident($lua:ident, $this:ident $(: $receiver:ty)?
            $(, $argument:ident : $argument_ty:ty)* $(,)?) -> $returns:ty $body:block
        $($rest:tt)*
    ) => {
        $surface.method(
            $crate::lua::declarations::MethodSpec {
                name: stringify!($method),
                doc: concat!($($doc),*),
                receiver: handle!(@receiver $($receiver)?),
                parameters: &[$(stringify!($argument)),*],
            },
            |$lua: &::mlua::Lua, $this: &Self, ($($argument,)*): ($($argument_ty,)*)|
                -> ::mlua::Result<$returns> { $body },
        );
        handle!(@items $surface, $($rest)*);
    };

    (@receiver) => {
        $crate::lua::declarations::Receiver::Own
    };

    (@receiver $receiver:ty) => {
        $crate::lua::declarations::Receiver::Named($crate::lua::declarations::of::<$receiver>)
    };
}

/// Declares the module table, building each function where it is described.
///
/// ```text
/// module! {
///     /// Every mapped toplevel, as of this frame's snapshot.
///     fn windows(lua, session) -> Vec<Window<T>> { windows(lua, session) }
/// }
/// ```
///
/// Each function takes the session as an `&Rc<Session<T>>`. The closure it
/// builds holds a clone of the `Rc` and captures nothing else.
macro_rules! module {
    ($(
        $(#[doc = $doc:literal])*
        fn $name:ident($lua:ident, $session:ident
            $(, $argument:ident : $argument_ty:ty)* $(,)?) -> $returns:ty $body:block
    )*) => {
        pub(crate) fn module_functions<T: $crate::lua::LuaTexture>() -> Vec<ModuleFunction<T>> {
            vec![$(
                ModuleFunction {
                    spec: $crate::lua::declarations::FunctionSpec {
                        name: stringify!($name),
                        doc: concat!($($doc),*),
                    },
                    ty: || $crate::lua::declarations::function_type(
                        None,
                        &[$(stringify!($argument)),*],
                        &<($($argument_ty,)*) as $crate::lua::declarations::Arguments>::luau(),
                        <$returns as $crate::lua::declarations::Typed>::luau(),
                    ),
                    build: |lua, session| {
                        let held = ::std::rc::Rc::clone(session);
                        lua.create_function(
                            move |$lua: &::mlua::Lua, ($($argument,)*): ($($argument_ty,)*)|
                                -> ::mlua::Result<$returns> {
                                let $session = &held;
                                $body
                            },
                        )
                    },
                },
            )*]
        }
    };
}

/// Declares a table of plain fields: an option table a call accepts, or a value
/// the runtime hands over.
///
/// ```text
/// record! {
///     /// What `lunette.spawn` takes.
///     options Spawn as SpawnOptions {
///         /// The program and its arguments.
///         argv: Vec<String>,
///     }
/// }
/// ```
///
/// The `options` form declares the shape alone, for a table read field by
/// field. The `struct` form declares a Rust struct with it, for a value handed
/// to Lua whole.
macro_rules! record {
    (
        $(#[doc = $doc:literal])*
        options $shape:ident as $name:ident {
            $($(#[doc = $field_doc:literal])* $field:ident : $field_ty:ty),* $(,)?
        }
    ) => {
        #[derive(Debug)]
        pub(crate) struct $shape;

        record!(@recorded $shape, $name, concat!($($doc),*),
            $($(#[doc = $field_doc])* $field: $field_ty,)*);
    };

    (
        $(#[doc = $doc:literal])*
        struct $name:ident {
            $($(#[doc = $field_doc:literal])* $field:ident : $field_ty:ty),* $(,)?
        }
    ) => {
        $(#[doc = $doc])*
        #[derive(Debug)]
        pub(crate) struct $name {
            $(pub $field: $field_ty,)*
        }

        impl ::mlua::IntoLua for $name {
            fn into_lua(self, lua: &::mlua::Lua) -> ::mlua::Result<::mlua::Value> {
                let table = lua.create_table()?;
                $(table.set(stringify!($field), self.$field)?;)*
                Ok(::mlua::Value::Table(table))
            }
        }

        record!(@recorded $name, $name, concat!($($doc),*),
            $($(#[doc = $field_doc])* $field: $field_ty,)*);
    };

    (@recorded $shape:ident, $name:ident, $doc:expr,
        $($(#[doc = $field_doc:literal])* $field:ident : $field_ty:ty,)*
    ) => {
        impl $crate::lua::declarations::Recorded for $shape {
            const RECORD: $crate::lua::declarations::Record =
                $crate::lua::declarations::Record {
                    name: stringify!($name),
                    doc: $doc,
                    fields: &[$(
                        $crate::lua::declarations::RecordField {
                            name: stringify!($field),
                            doc: concat!($($field_doc),*),
                            ty: $crate::lua::declarations::of::<$field_ty>,
                        },
                    )*],
                };
        }

        impl $crate::lua::declarations::Typed for $shape {
            fn luau() -> $crate::lua::declarations::Type {
                $crate::lua::declarations::Type::Named(stringify!($name))
            }
        }
    };
}

pub(crate) use handle;
pub(crate) use module;
pub(crate) use record;
