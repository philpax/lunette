//! Defines each handle surface once for both mlua registration and generated Luau declarations.
//!
//! The generated `lua/lunette/init.luau` supplies source for `require '@lunette'`, which Luau
//! resolves to a file. [`Described::describe`] feeds the same declaration to mlua and the renderer;
//! [`Typed`] derives its Luau types from Rust signatures.

mod macros;
mod render;
mod types;

use std::marker::PhantomData;

pub use lunette_luau::{Arguments, Parameter, Type, Typed, of};
use mlua::{
    FromLua, FromLuaMulti, IntoLua, IntoLuaMulti, Lua, MaybeSend, MetaMethod, Table,
    UserDataFields, UserDataMethods, Value,
};

pub(crate) use crate::lua::declarations::{
    macros::{handle, module, record},
    render::render_doc,
};
pub use crate::lua::declarations::{render::render, types::Textured};
use crate::{
    control::{serialise::HANDLE_METAFIELD, wire::HandleKind},
    lua::{LuaTexture, reject_unknown_options},
    texture::CopyableTexture,
};

/// Declares a handle surface for mlua and the Luau renderer.
pub trait Described: Sized + Typed {
    const HANDLE: HandleSpec;

    const KIND: HandleKind;

    fn describe(surface: &mut impl Surface<Self>);
}

/// Where a method declaration goes: into mlua, or into the generated Luau.
pub trait MethodSurface<T: Typed> {
    fn method<M, A, R>(&mut self, spec: MethodSpec, body: M)
    where
        M: Fn(&Lua, &T, A) -> mlua::Result<R> + MaybeSend + 'static,
        A: FromLuaMulti + Arguments,
        R: IntoLuaMulti + Typed;
}

/// Declares methods for mlua and the Luau renderer.
pub trait MethodsDescribed: Typed + Sized {
    fn describe_methods(surface: &mut impl MethodSurface<Self>);
}

/// Declares handle fields for mlua or the Luau renderer.
pub trait Surface<T: Described>: MethodSurface<T> {
    fn field<G, R>(&mut self, spec: FieldSpec, get: G)
    where
        G: Fn(&Lua, &T) -> mlua::Result<R> + MaybeSend + 'static,
        R: IntoLua + Typed;
}

pub fn add_fields<T, F>(fields: &mut F)
where
    T: Described + 'static,
    F: UserDataFields<T>,
{
    fields.add_meta_field(HANDLE_METAFIELD, T::KIND.as_str());
    T::describe(&mut FieldRegistrar {
        fields,
        handle: PhantomData,
    });
}

/// Registers a handle's described methods, and `==` comparing what two handles name.
///
/// Every read returns fresh userdata, so raw equality would tell two reads of one window apart.
/// Luau calls `__eq` only for operands sharing the metamethod, which mlua keeps per Rust type.
pub fn add_methods<T, M>(methods: &mut M)
where
    T: Described + PartialEq + 'static,
    M: UserDataMethods<T>,
{
    methods.add_meta_method(MetaMethod::Eq, |_, this, other: Value| {
        Ok(other
            .as_userdata()
            .and_then(|other| other.borrow::<T>().ok())
            .is_some_and(|other| *this == *other))
    });
    T::describe(&mut MethodRegistrar {
        methods,
        handle: PhantomData,
    });
}

/// Registers a type's described methods with mlua.
pub fn add_described_methods<T, M>(methods: &mut M)
where
    T: MethodsDescribed + 'static,
    M: UserDataMethods<T>,
{
    T::describe_methods(&mut MethodRegistrar {
        methods,
        handle: PhantomData,
    });
}

/// The generated declaration metadata for a handle.
#[derive(Clone, Copy, Debug)]
pub struct HandleSpec {
    pub name: &'static str,
    pub doc: &'static str,
}

#[derive(Clone, Copy, Debug)]
pub struct FieldSpec {
    pub name: &'static str,
    pub doc: &'static str,
}

/// A method's declaration metadata, including named non-receiver parameters.
#[derive(Clone, Copy, Debug)]
pub struct MethodSpec {
    pub name: &'static str,
    pub doc: &'static str,
    pub receiver: Receiver,
    pub parameters: &'static [&'static str],
}

/// Selects the method receiver type.
#[derive(Clone, Copy, Debug)]
pub enum Receiver {
    Own,
    /// Uses a wider receiver type for a method exposed through a union.
    Named(fn() -> Type),
}

#[derive(Clone, Copy, Debug)]
pub struct FunctionSpec {
    pub name: &'static str,
    pub doc: &'static str,
}

/// A generated Luau record for an option table or runtime value.
#[derive(Clone, Copy, Debug)]
pub struct Record {
    pub name: &'static str,
    pub doc: &'static str,
    pub fields: &'static [RecordField],
}

impl Record {
    pub fn names(&self) -> impl Iterator<Item = &'static str> {
        self.fields.iter().map(|field| field.name)
    }
}

#[derive(Clone, Copy, Debug)]
pub struct RecordField {
    pub name: &'static str,
    pub doc: &'static str,
    pub ty: fn() -> Type,
}

/// Associates a Rust type with a generated Luau record.
pub trait Recorded {
    const RECORD: Record;
}

/// An option table validated against its declared fields before a method receives it.
#[derive(Debug)]
pub struct Options<S: Recorded> {
    table: Table,
    shape: PhantomData<S>,
}

impl<S: Recorded> Options<S> {
    #[must_use]
    pub fn table(&self) -> &Table {
        &self.table
    }
}

impl<S: Recorded> FromLua for Options<S> {
    fn from_lua(value: Value, lua: &Lua) -> mlua::Result<Self> {
        let table = Table::from_lua(value, lua)?;
        reject_unknown_options(&table, &S::RECORD)?;
        Ok(Self {
            table,
            shape: PhantomData,
        })
    }
}

impl<S: Recorded> Typed for Options<S> {
    fn luau() -> Type {
        Type::Named(S::RECORD.name)
    }
}

/// A placeholder texture used while collecting declarations without calling handle closures.
#[derive(Clone, Copy, Debug)]
pub struct NullTexture;

impl LuaTexture for NullTexture {
    fn push(&self, _: &Lua) -> mlua::Result<Value> {
        Ok(Value::Nil)
    }
}

impl CopyableTexture for NullTexture {
    fn allocate_copy(&self) -> Option<Self> {
        None
    }

    fn copy_to(&self, _: &Self) -> bool {
        false
    }
}

/// A handle's resolved Luau declaration.
#[derive(Debug)]
pub struct Handle {
    pub spec: HandleSpec,
    pub fields: Vec<Property>,
    pub methods: Vec<Signature>,
}

/// A generated `export type` declared beside its corresponding Rust type.
///
/// The renderer selects aliases to emit. The Luau checker reports aliases omitted from the
/// generated file when another declaration refers to them.
#[derive(Clone, Copy, Debug)]
pub struct AliasSpec {
    pub doc: &'static str,
    /// Returns the alias name from the Rust type's [`Typed`] implementation.
    pub name: fn() -> Type,
    /// Resolves the alias definition against collected handles.
    pub definition: fn(&[&Handle]) -> Type,
}

/// Associates a Rust type with a generated Luau alias.
pub trait Aliased {
    const ALIAS: AliasSpec;
}

/// A resolved property declaration.
#[derive(Debug)]
pub struct Property {
    pub name: &'static str,
    pub doc: &'static str,
    pub ty: Type,
}

/// A resolved method declaration.
#[derive(Debug)]
pub struct Signature {
    pub name: &'static str,
    pub doc: &'static str,
    pub ty: Type,
}

/// Collects a handle's declarations without a Lua state.
#[must_use]
pub fn collect<T: Described>() -> Handle {
    let mut collector = Collector::default();
    T::describe(&mut collector);
    Handle {
        spec: T::HANDLE,
        fields: collector.fields,
        methods: collector.methods,
    }
}

/// Collects method declarations without a Lua state.
#[must_use]
pub fn collect_methods<T: MethodsDescribed>() -> Vec<Signature> {
    let mut collector = Collector::default();
    T::describe_methods(&mut collector);
    collector.methods
}

/// Builds the Luau type of a function from what it takes and answers.
///
/// `receiver` is the first parameter where there is one. Every method has a
/// receiver; no module function does.
pub(crate) fn function_type(
    receiver: Option<Type>,
    parameters: &[&'static str],
    arguments: &[Type],
    returns: Type,
) -> Type {
    Type::Function {
        receiver: receiver.map(Box::new),
        parameters: parameters
            .iter()
            .zip(arguments)
            .map(|(name, ty)| Parameter {
                name,
                ty: ty.clone(),
            })
            .collect(),
        returns: Box::new(returns),
    }
}

/// Registers handle fields through mlua's field callback.
struct FieldRegistrar<'a, T, F> {
    fields: &'a mut F,
    handle: PhantomData<T>,
}

impl<T: Described, F: UserDataFields<T>> Surface<T> for FieldRegistrar<'_, T, F> {
    fn field<G, R>(&mut self, spec: FieldSpec, get: G)
    where
        G: Fn(&Lua, &T) -> mlua::Result<R> + MaybeSend + 'static,
        R: IntoLua + Typed,
    {
        self.fields.add_field_method_get(spec.name, get);
    }
}

impl<T: Typed, F: UserDataFields<T>> MethodSurface<T> for FieldRegistrar<'_, T, F> {
    fn method<M, A, R>(&mut self, _: MethodSpec, _: M)
    where
        M: Fn(&Lua, &T, A) -> mlua::Result<R> + MaybeSend + 'static,
        A: FromLuaMulti + Arguments,
        R: IntoLuaMulti + Typed,
    {
    }
}

/// Registers handle methods through mlua's method callback.
struct MethodRegistrar<'a, T, M> {
    methods: &'a mut M,
    handle: PhantomData<T>,
}

impl<T: Described, Registry: UserDataMethods<T>> Surface<T> for MethodRegistrar<'_, T, Registry> {
    fn field<G, R>(&mut self, _: FieldSpec, _: G)
    where
        G: Fn(&Lua, &T) -> mlua::Result<R> + MaybeSend + 'static,
        R: IntoLua + Typed,
    {
    }
}

impl<T: Typed, Registry: UserDataMethods<T>> MethodSurface<T> for MethodRegistrar<'_, T, Registry> {
    fn method<M, A, R>(&mut self, spec: MethodSpec, body: M)
    where
        M: Fn(&Lua, &T, A) -> mlua::Result<R> + MaybeSend + 'static,
        A: FromLuaMulti + Arguments,
        R: IntoLuaMulti + Typed,
    {
        self.methods.add_method(spec.name, body);
    }
}

/// Collects resolved field and method declarations.
#[derive(Debug, Default)]
struct Collector {
    fields: Vec<Property>,
    methods: Vec<Signature>,
}

impl<T: Described> Surface<T> for Collector {
    fn field<G, R>(&mut self, spec: FieldSpec, _: G)
    where
        G: Fn(&Lua, &T) -> mlua::Result<R> + MaybeSend + 'static,
        R: IntoLua + Typed,
    {
        self.fields.push(Property {
            name: spec.name,
            doc: spec.doc,
            ty: R::luau(),
        });
    }
}

impl<T: Typed> MethodSurface<T> for Collector {
    fn method<M, A, R>(&mut self, spec: MethodSpec, _: M)
    where
        M: Fn(&Lua, &T, A) -> mlua::Result<R> + MaybeSend + 'static,
        A: FromLuaMulti + Arguments,
        R: IntoLuaMulti + Typed,
    {
        let receiver = match spec.receiver {
            Receiver::Own => T::luau(),
            Receiver::Named(named) => named(),
        };
        self.methods.push(Signature {
            name: spec.name,
            doc: spec.doc,
            ty: function_type(Some(receiver), spec.parameters, &A::luau(), R::luau()),
        });
    }
}
