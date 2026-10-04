//! Installs the relative-require resolution on a Lua state.

use mlua::{Function, Lua, Value};

use crate::require::path::{Requirer, resolve};

/// Resolves relative paths against the requiring chunk for `require`.
///
/// The Lua wrapper preserves module errors. Native code resolves paths because
/// `debug.info` returns a shortened chunk name.
pub fn install(lua: &Lua) -> mlua::Result<()> {
    let globals = lua.globals();
    let original: Function = globals.get("require")?;
    let resolver = lua.create_function(|lua, path: mlua::LuaString| {
        let path = path.to_str()?.to_owned();
        let chunk = requiring_chunk(lua);
        let requirer = chunk
            .as_deref()
            .map_or(Requirer::Unnamed, Requirer::from_chunk_name);
        match resolve(requirer, &path) {
            Ok(Some(resolved)) => Ok((Value::String(lua.create_string(&resolved)?), Value::Nil)),
            Ok(None) => Ok((Value::Nil, Value::Nil)),
            Err(error) => Ok((
                Value::Nil,
                Value::String(lua.create_string(error.to_string())?),
            )),
        }
    })?;
    let wrapper: Function = lua
        .load(WRAPPER)
        .set_name("=require")
        .call((original, resolver))?;
    globals.set("require", wrapper)
}

/// The wrapper raises resolution errors at the caller's line and forwards other names unchanged.
const WRAPPER: &str = r"
local original, resolve = ...
return function(name, ...)
  if type(name) == 'string' then
    local resolved, failure = resolve(name)
    if failure then
      error(failure, 2)
    end
    if resolved then
      return original(resolved)
    end
  end
  return original(name, ...)
end
";

/// Returns the calling chunk name, skipping C frames and the resolver wrapper.
fn requiring_chunk(lua: &Lua) -> Option<String> {
    let mut level = 2;
    loop {
        let frame = lua.inspect_stack(level, |debug| {
            let source = debug.source();
            (source.what, source.source.map(|name| name.into_owned()))
        })?;
        match frame {
            ("C", _) => level += 1,
            (_, name) => return name,
        }
    }
}

#[cfg(test)]
#[expect(
    clippy::expect_used,
    reason = "a failed expectation is how a test reports a failure; the ban is on production code"
)]
mod tests {
    use mlua::Table;
    use pretty_assertions::assert_eq;

    use super::*;
    use crate::test_lua::session_lua;

    /// A state whose original `require` records the names it is given and
    /// loads each from `modules`, a table of chunk sources by module name. Each
    /// is loaded under the chunk name LÖVR's loader gives a file: `@` and its
    /// path.
    fn state(modules: &[(&str, &str, &str)]) -> Lua {
        let lua = session_lua();
        let sources = lua.create_table().expect("a table");
        for (name, file, source) in modules {
            let entry = lua.create_table().expect("a table");
            entry.set("file", *file).expect("a file");
            entry.set("source", *source).expect("a source");
            sources.set(*name, entry).expect("a module");
        }
        lua.globals().set("SOURCES", sources).expect("the sources");
        lua.load(
            r"
            REQUIRED = {}
            local loaded = {}
            require = function(name)
              table.insert(REQUIRED, name)
              if loaded[name] ~= nil then
                return loaded[name]
              end
              local entry = SOURCES[name]
              if not entry then
                error('module ' .. name .. ' not found', 2)
              end
              local chunk = assert(loadstring(entry.source, '@' .. entry.file))
              loaded[name] = chunk(name)
              return loaded[name]
            end
            ",
        )
        .exec()
        .expect("the recording require");
        install(&lua).expect("the wrapper");
        lua
    }

    fn required(lua: &Lua) -> Vec<String> {
        let names: Table = lua.globals().get("REQUIRED").expect("the record");
        names
            .sequence_values::<String>()
            .collect::<mlua::Result<_>>()
            .expect("the names")
    }

    #[test]
    fn a_nested_module_requires_its_sibling() {
        let lua = state(&[
            ("nested/a", "nested/a.luau", "return require './b'"),
            ("nested/b", "nested/b.luau", "return 'b'"),
        ]);
        let answer: String = lua
            .load("return require './nested/a'")
            .set_name("@main.luau")
            .eval()
            .expect("the require");
        assert_eq!(answer, "b");
        assert_eq!(required(&lua), ["nested/a", "nested/b"]);
    }

    #[test]
    fn a_protected_require_resolves_against_the_chunk_that_called_pcall() {
        let lua = state(&[
            (
                "nested/a",
                "nested/a.luau",
                "local ok, b = pcall(require, './b') assert(ok, b) return b",
            ),
            ("nested/b", "nested/b.luau", "return 'b'"),
        ]);
        let answer: String = lua
            .load("return require './nested/a'")
            .set_name("@main.luau")
            .eval()
            .expect("the require");
        assert_eq!(answer, "b");
    }

    #[test]
    fn an_alias_reaches_the_loader_as_it_stands() {
        let lua = state(&[(
            "@lunette-contracts/scale",
            "@lunette-contracts/scale.luau",
            "return 'scale'",
        )]);
        let answer: String = lua
            .load("return require '@lunette-contracts/scale'")
            .set_name("@nested/a.luau")
            .eval()
            .expect("the require");
        assert_eq!(answer, "scale");
        assert_eq!(required(&lua), ["@lunette-contracts/scale"]);
    }

    #[test]
    fn an_unresolvable_path_raises_at_the_callers_line() {
        let lua = state(&[]);
        let error = lua
            .load("\nrequire '../outside'")
            .set_name("@main.luau")
            .exec()
            .expect_err("an escape");
        let message = error.to_string();
        assert!(
            message.contains(
                "main.luau:2: require: '../outside' from main.luau leaves the root it starts in"
            ),
            "{message}"
        );
        assert!(required(&lua).is_empty());
    }
}
