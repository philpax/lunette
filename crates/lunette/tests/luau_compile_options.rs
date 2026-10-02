//! mlua-sys's mirror of `lua_CompileOptions` matches the Luau that `liblovr.so` exports.
//!
//! mlua passes the struct to `luau_compile` by pointer, so a field missing from the mirror shifts
//! every later field and the compiler reads the tail of the struct from whatever follows it on the
//! stack. Nothing fails to link or typecheck when that happens. Each case sets one option the
//! compiler visibly honours and checks that the bytecode changes: an option read from the wrong
//! offset is not honoured.
extern crate lunette_lovr;

use mlua::chunk::Compiler;

#[test]
fn a_mutable_global_disables_the_import_of_its_fields() -> mlua::Result<()> {
    let source = "return g.x";
    let imported = Compiler::new().compile(source)?;
    let looked_up = Compiler::new().add_mutable_global("g").compile(source)?;
    assert_ne!(imported, looked_up);
    Ok(())
}

#[test]
fn a_disabled_builtin_is_not_compiled_into_a_fastcall() -> mlua::Result<()> {
    let source = "local n = ... return math.abs(n)";
    let fastcall = Compiler::new().compile(source)?;
    let call = Compiler::new()
        .add_disabled_builtin("math.abs")
        .compile(source)?;
    assert_ne!(fastcall, call);
    Ok(())
}
