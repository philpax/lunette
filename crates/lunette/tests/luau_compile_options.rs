//! mlua-sys's mirror of `lua_CompileOptions` matches the Luau that `liblovr.so` exports.
//!
//! A missing field shifts every later one without a link or type error, so each case checks that
//! one option changes the bytecode.
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
