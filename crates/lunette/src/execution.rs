//! Configures per-VM Luau compilation for LÖVR and Rust-loaded chunks.

use lunette_lovr::raw;
use mlua::{Function, Lua, chunk::Compiler, ffi};

/// Compilation applied to chunks loaded after configuration.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub enum ExecutionMode {
    /// Baseline bytecode optimization without native compilation.
    #[default]
    Interpreter,
    /// Bytecode optimization including inlining, without native compilation.
    Optimized,
    /// Optimized bytecode and native compilation where CodeGen supports the function.
    Native,
}

/// Sets compilation options for the VM and its coroutines.
///
/// Unsupported native execution leaves both compilers unchanged. Existing functions retain their bytecode and any native code.
pub fn configure(lua: &Lua, mode: ExecutionMode) -> mlua::Result<()> {
    let optimization = match mode {
        ExecutionMode::Interpreter => 1,
        ExecutionMode::Optimized | ExecutionMode::Native => 2,
    };
    let native = mode == ExecutionMode::Native;
    // SAFETY: `exec_raw` locks the live VM, protects registry allocations, and restores the stack.
    let configured: bool = unsafe {
        lua.exec_raw((), |state| {
            let configured = raw::luax_setluauoptions(state.cast(), optimization, native);
            ffi::lua_pushboolean(state, i32::from(configured));
        })?
    };
    if !configured {
        return Err(mlua::Error::runtime(
            "lua execution: native compilation is not supported by this build or CPU",
        ));
    }
    lua.set_compiler(
        Compiler::new()
            .set_optimization_level(optimization as u8)
            .set_debug_level(1)
            .set_type_info_level(u8::from(native)),
    );
    Ok(())
}

/// Compiles a Lua function and its nested functions when the VM enables native compilation.
///
/// Interpreter modes leave the function unchanged. CodeGen can retain interpreter execution for unsupported functions. A successful request does not prove that CodeGen emits native code.
///
/// # Panics
///
/// Panics if the function belongs to a different Lua VM.
pub fn compile(lua: &Lua, function: &Function) -> mlua::Result<()> {
    // SAFETY: `exec_raw` checks the function's VM, roots it at index 1, protects the call, and restores the stack.
    unsafe {
        lua.exec_raw(function, |state| {
            raw::luax_compilefunction(state.cast(), 1);
        })
    }
}

/// Whether the linked LÖVR build and CPU support Luau native compilation.
pub fn supported() -> bool {
    // SAFETY: the support query takes no state and does not mutate compiler flags.
    unsafe { raw::luax_luaucodegensupported() }
}

#[cfg(test)]
#[expect(
    clippy::expect_used,
    reason = "tests fail at the operation that violates the contract"
)]
mod tests {
    use std::ffi::CStr;

    use mlua::{Function, Lua, ffi};

    use super::*;

    // The local probe avoids a global lookup that can leave native execution before the callback.
    const PROBE_SOURCE: &str = r#"
local functions = {
    function(probe: () -> boolean, limit: number): (boolean, number)
        local total = 0
        for index = 1, limit do
            total += index
        end
        return probe(), total
    end,
}
return functions[1](...)
"#;

    #[test]
    fn configuring_one_vm_does_not_change_another_vm() {
        let first = Lua::new();
        let second = Lua::new();
        configure(&first, ExecutionMode::Interpreter).expect("interpreter execution is supported");
        configure(&second, ExecutionMode::Optimized).expect("optimized execution is supported");

        configure_native(&first);
        assert_eq!(
            c_settings(&first),
            if supported() { (2, true) } else { (1, false) }
        );
        assert_eq!(c_settings(&second), (2, false));
        for loader in [Loader::C, Loader::Mlua] {
            let first_function = loader
                .load(&first, PROBE_SOURCE, c"@first.luau")
                .expect("the first VM loads");
            let second_function = loader
                .load(&second, PROBE_SOURCE, c"@second.luau")
                .expect("the second VM loads");
            compile(&first, &first_function).expect("the first VM compiles");
            compile(&second, &second_function).expect("the second VM compiles");
            assert_eq!(
                probe_execution(&first, &first_function),
                (supported(), 5050)
            );
            assert_eq!(probe_execution(&second, &second_function), (false, 5050));
        }

        configure(&second, ExecutionMode::Interpreter).expect("the second VM changes mode");
        assert_eq!(
            c_settings(&first),
            if supported() { (2, true) } else { (1, false) }
        );
        assert_eq!(c_settings(&second), (1, false));
        let third = Lua::new();
        for loader in [Loader::C, Loader::Mlua] {
            let function = loader
                .load(&third, PROBE_SOURCE, c"@fresh.luau")
                .expect("a fresh VM loads");
            compile(&third, &function).expect("compilation in a fresh VM is harmless");
            assert_eq!(probe_execution(&third, &function), (false, 5050));
        }
    }

    #[test]
    fn coroutines_share_settings_and_repeated_native_configuration_preserves_functions() {
        let lua = Lua::new();
        configure(&lua, ExecutionMode::Optimized).expect("optimized execution is supported");
        let configure_on_coroutine = lua
            .create_function(|lua, ()| {
                configure_native(lua);
                let function = Loader::C.load(lua, PROBE_SOURCE, c"@coroutine.luau")?;
                let before = probe_execution(lua, &function);
                configure_native(lua);
                assert_eq!(probe_execution(lua, &function), before);
                Ok(before)
            })
            .expect("the coroutine callback is created");
        let thread = lua
            .create_thread(configure_on_coroutine)
            .expect("the coroutine is created");
        let result: (bool, i64) = thread.resume(()).expect("the coroutine configures its VM");
        assert_eq!(result, (supported(), 5050));
        assert_eq!(c_settings(&lua), (2, supported()));
        for loader in [Loader::C, Loader::Mlua] {
            let function = loader
                .load(&lua, PROBE_SOURCE, c"@main.luau")
                .expect("the main thread loads");
            compile(&lua, &function).expect("the main thread sees the coroutine's setting");
            assert_eq!(probe_execution(&lua, &function), (supported(), 5050));
        }

        configure(&lua, ExecutionMode::Interpreter).expect("the main thread changes mode");
        let inspect_on_coroutine = lua
            .create_function(|lua, ()| {
                assert_eq!(c_settings(lua), (1, false));
                let function = Loader::C.load(lua, PROBE_SOURCE, c"@after-coroutine.luau")?;
                Ok(probe_execution(lua, &function))
            })
            .expect("the coroutine callback is created");
        let thread = lua
            .create_thread(inspect_on_coroutine)
            .expect("the coroutine is created");
        let result: (bool, i64) = thread
            .resume(())
            .expect("the coroutine sees the main thread's setting");
        assert_eq!(result, (false, 5050));
    }

    #[test]
    fn interpreter_transition_changes_new_chunks_but_preserves_existing_native_functions() {
        let lua = Lua::new();
        configure(&lua, ExecutionMode::Interpreter).expect("interpreter execution is supported");
        configure_native(&lua);
        let mut existing = Vec::new();
        for loader in [Loader::C, Loader::Mlua] {
            let function = loader
                .load(&lua, PROBE_SOURCE, c"@before.luau")
                .expect("the native chunk loads");
            compile(&lua, &function).expect("the native chunk compiles");
            assert_eq!(probe_execution(&lua, &function), (supported(), 5050));
            existing.push(function);
        }

        configure(&lua, ExecutionMode::Interpreter)
            .expect("the VM returns to interpreter execution");
        for loader in [Loader::C, Loader::Mlua] {
            let function = loader
                .load(&lua, PROBE_SOURCE, c"@after.luau")
                .expect("the interpreter chunk loads");
            compile(&lua, &function).expect("interpreter compilation is a no-op");
            assert_eq!(probe_execution(&lua, &function), (false, 5050));
        }
        for function in existing {
            compile(&lua, &function).expect("recompiling in interpreter mode is harmless");
            assert_eq!(probe_execution(&lua, &function), (supported(), 5050));
        }
    }

    #[test]
    fn c_and_mlua_loaders_agree_and_mlua_requires_explicit_native_compilation() {
        for mode in [
            ExecutionMode::Interpreter,
            ExecutionMode::Optimized,
            ExecutionMode::Native,
        ] {
            let lua = Lua::new();
            configure(&lua, ExecutionMode::Interpreter)
                .expect("interpreter execution is supported");
            configure_mode(&lua, mode);
            let native = mode == ExecutionMode::Native && supported();
            let upvalues = if mode == ExecutionMode::Optimized || native {
                0
            } else {
                1
            };
            for loader in [Loader::C, Loader::Mlua] {
                assert_eq!(inlining_upvalues(&lua, loader), upvalues);
            }
            let c_function = Loader::C
                .load(&lua, PROBE_SOURCE, c"@parity.luau")
                .expect("the C loader accepts typed source");
            let mlua_function = Loader::Mlua
                .load(&lua, PROBE_SOURCE, c"@parity.luau")
                .expect("mlua accepts typed source");
            assert_eq!(probe_execution(&lua, &c_function), (native, 5050));
            assert_eq!(probe_execution(&lua, &mlua_function), (false, 5050));
            compile(&lua, &mlua_function).expect("explicit compilation succeeds");
            assert_eq!(
                probe_execution(&lua, &mlua_function),
                probe_execution(&lua, &c_function)
            );
            let c_probe = probe(&lua);
            compile(&lua, &c_probe).expect("compiling a C function is harmless");
        }
    }

    #[test]
    fn native_configuration_succeeds_or_preserves_both_compilers_when_unsupported() {
        let lua = Lua::new();
        for mode in [ExecutionMode::Interpreter, ExecutionMode::Optimized] {
            configure(&lua, mode).expect("bytecode compilation is supported");
            let before_c = c_settings(&lua);
            let before_mlua = inlining_upvalues(&lua, Loader::Mlua);
            assert_eq!(
                before_mlua,
                if mode == ExecutionMode::Interpreter {
                    1
                } else {
                    0
                }
            );
            let configured = configure(&lua, ExecutionMode::Native);
            if supported() {
                configured.expect("native execution is supported");
                assert_eq!(c_settings(&lua), (2, true));
                assert_eq!(inlining_upvalues(&lua, Loader::Mlua), 0);
            } else {
                let error = configured.expect_err("unsupported native execution is rejected");
                assert!(
                    error
                        .to_string()
                        .contains("native compilation is not supported"),
                    "{error}"
                );
                assert_eq!(c_settings(&lua), before_c);
                assert_eq!(inlining_upvalues(&lua, Loader::Mlua), before_mlua);
            }
        }
    }

    #[test]
    fn both_loaders_preserve_source_errors_and_debug_information_in_each_mode() {
        for mode in [
            ExecutionMode::Interpreter,
            ExecutionMode::Optimized,
            ExecutionMode::Native,
        ] {
            let lua = Lua::new();
            configure(&lua, ExecutionMode::Interpreter)
                .expect("interpreter execution is supported");
            configure_mode(&lua, mode);
            for loader in [Loader::C, Loader::Mlua] {
                let syntax = loader
                    .load(&lua, "local valid = 1\nlocal =", c"@syntax-error.luau")
                    .expect_err("invalid source is rejected");
                assert!(
                    syntax.to_string().contains("syntax-error.luau:2:"),
                    "{mode:?} {syntax}"
                );
                let chunk = loader
                    .load(
                        &lua,
                        "local function fail()\n    error('execution sentinel')\nend\nreturn fail",
                        c"@runtime-error.luau",
                    )
                    .expect("the error fixture loads");
                compile(&lua, &chunk).expect("the error fixture compiles");
                let function: Function = chunk.call(()).expect("the nested function is returned");
                let info = function.info();
                assert_eq!(info.name.as_deref(), Some("fail"));
                assert_eq!(info.source.as_deref(), Some("@runtime-error.luau"));
                assert_eq!(info.line_defined, Some(1));
                let error = function
                    .call::<()>(())
                    .expect_err("the nested function raises");
                let message = error.to_string();
                assert!(
                    message.contains("runtime-error.luau:2:"),
                    "{mode:?} {message}"
                );
                assert!(message.contains("execution sentinel"), "{mode:?} {message}");
                assert!(message.contains("fail"), "{mode:?} {message}");
                let recovered = loader
                    .load(&lua, "return 42", c"@recovered.luau")
                    .expect("loading still works after errors");
                assert_eq!(recovered.call::<i64>(()).expect("execution recovers"), 42);
            }
        }
    }

    #[derive(Clone, Copy)]
    enum Loader {
        C,
        Mlua,
    }

    impl Loader {
        fn load(self, lua: &Lua, source: &str, name: &CStr) -> mlua::Result<Function> {
            match self {
                Self::C => {
                    // SAFETY: source and name outlive the protected call. It catches lua_error before Rust unwinds and restores the stack.
                    unsafe {
                        lua.exec_raw((), |state| {
                            let status = raw::luax_loadbufferx(
                                state.cast(),
                                source.as_ptr().cast(),
                                source.len(),
                                name.as_ptr(),
                                std::ptr::null(),
                            );
                            if status != ffi::LUA_OK {
                                ffi::lua_error(state);
                            }
                        })
                    }
                }
                Self::Mlua => lua
                    .load(source)
                    .set_name(name.to_str().expect("fixture names are UTF-8"))
                    .into_function(),
            }
        }
    }

    fn configure_mode(lua: &Lua, mode: ExecutionMode) {
        if mode == ExecutionMode::Native {
            configure_native(lua);
        } else {
            configure(lua, mode).expect("bytecode compilation is supported");
        }
    }

    fn configure_native(lua: &Lua) {
        let before = c_settings(lua);
        let configured = configure(lua, ExecutionMode::Native);
        if supported() {
            configured.expect("native execution is supported");
        } else {
            let error = configured.expect_err("unsupported native execution is rejected");
            assert!(
                error
                    .to_string()
                    .contains("native compilation is not supported"),
                "{error}"
            );
            assert_eq!(c_settings(lua), before);
        }
    }

    fn c_settings(lua: &Lua) -> (i32, bool) {
        (
            lua.named_registry_value("lovr.luau.optimization")
                .expect("the optimization setting exists"),
            lua.named_registry_value("lovr.luau.native")
                .expect("the native setting exists"),
        )
    }

    fn inlining_upvalues(lua: &Lua, loader: Loader) -> u8 {
        let chunk = loader
            .load(
                lua,
                "local function square(value: number): number return value * value end; return function(value: number): number return square(value) end",
                c"@inlining.luau",
            )
            .expect("the inlining fixture loads");
        let function: Function = chunk
            .call(())
            .expect("the inlining fixture returns a function");
        function.info().num_upvalues
    }

    fn probe_execution(lua: &Lua, function: &Function) -> (bool, i64) {
        function
            .call((probe(lua), 100))
            .expect("the execution probe returns")
    }

    fn probe(lua: &Lua) -> Function {
        // SAFETY: the callback follows the Lua C ABI and only inspects its live Lua caller.
        unsafe { lua.create_c_function(native_probe) }.expect("the native probe is created")
    }

    unsafe extern "C-unwind" fn native_probe(state: *mut ffi::lua_State) -> i32 {
        // SAFETY: Lua invokes the callback with a live state and its caller at level 1.
        unsafe {
            ffi::lua_pushboolean(state, ffi::lua_incustomexecution(state, 1));
        }
        1
    }
}
