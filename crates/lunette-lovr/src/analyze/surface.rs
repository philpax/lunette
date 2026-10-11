//! Enumerates the named runtime paths in a Luau definition file through its AST.

use std::{
    ffi::{CStr, c_char},
    fmt, slice,
};

/// A global or a named property reachable through a global's table type.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Member {
    /// The individual keys, starting with the global name.
    pub path: Vec<String>,
    /// Whether this member permits nil when its parent exists.
    pub optional: bool,
    /// Whether a string indexer declares additional function-valued keys at this path.
    pub string_indexed: bool,
}

/// Parses global declarations and follows table aliases, groups, and intersections.
///
/// Function signatures and extern instance types do not contribute table members.
/// Unsupported or recursive runtime types fail rather than producing a partial inventory.
///
/// # Errors
///
/// Returns an error if parsing or enumeration fails.
pub fn surface(source: &str) -> Result<Vec<Member>, Error> {
    // SAFETY: the source pointer remains live for the call, and the callee copies all returned strings.
    let raw = unsafe { lunette_luau_definition_surface(source.as_ptr().cast(), source.len()) };
    if raw.is_null() {
        return Err(Error(
            "the parser returned no definition surface".to_owned(),
        ));
    }
    let owned = OwnedSurface(raw);
    // SAFETY: the returned report owns valid arrays and NUL-terminated strings until `owned` drops.
    unsafe {
        let report = &*owned.0;
        if !report.failure.is_null() {
            return Err(Error(
                CStr::from_ptr(report.failure)
                    .to_string_lossy()
                    .into_owned(),
            ));
        }
        let members = slice::from_raw_parts(report.members, report.member_count);
        members
            .iter()
            .map(|member| {
                let path = slice::from_raw_parts(member.path, member.path_count)
                    .iter()
                    .map(|key| CStr::from_ptr(*key).to_str().map(str::to_owned))
                    .collect::<Result<Vec<_>, _>>()
                    .map_err(|error| Error(format!("a declaration key is not UTF-8: {error}")))?;
                Ok(Member {
                    path,
                    optional: member.optional,
                    string_indexed: member.string_indexed,
                })
            })
            .collect()
    }
}

/// A definition surface that cannot be enumerated.
#[derive(Debug)]
pub struct Error(String);

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "luau definition surface: {}", self.0)
    }
}

impl std::error::Error for Error {}

struct OwnedSurface(*mut RawSurface);

impl Drop for OwnedSurface {
    fn drop(&mut self) {
        // SAFETY: this owner holds the live report and keeps no borrows after conversion.
        unsafe { lunette_luau_surface_free(self.0) };
    }
}

#[repr(C)]
struct RawMember {
    path: *mut *mut c_char,
    path_count: usize,
    optional: bool,
    string_indexed: bool,
}

#[repr(C)]
struct RawSurface {
    members: *mut RawMember,
    member_count: usize,
    failure: *mut c_char,
}

unsafe extern "C" {
    fn lunette_luau_definition_surface(source: *const c_char, length: usize) -> *mut RawSurface;
    fn lunette_luau_surface_free(surface: *mut RawSurface);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn aliases_intersections_and_nested_tables_are_enumerated() -> Result<(), Error> {
        let members = surface(
            r#"
            type Module = { read nested: { member: () -> { notAModule: number } } }
            declare runtime: Module
              & ((number) -> Module)
            declare function standalone(value: { notAModule: number }): Module
            "#,
        )?;
        assert_eq!(
            members
                .iter()
                .map(|member| member.path.join("."))
                .collect::<Vec<_>>(),
            [
                "runtime",
                "runtime.nested",
                "runtime.nested.member",
                "standalone"
            ]
        );
        assert!(members.iter().all(|member| !member.optional));
        Ok(())
    }

    #[test]
    fn optional_aliases_preserve_required_children() -> Result<(), Error> {
        let members = surface("type Maybe = { child: number }? declare root: Maybe")?;
        assert_eq!(members.len(), 2);
        assert!(members[0].optional);
        assert!(!members[1].optional);
        Ok(())
    }

    #[test]
    fn explicit_nil_and_optional_syntax_produce_the_same_members() -> Result<(), Error> {
        assert_eq!(
            surface("declare root: { child: number }?")?,
            surface("type Nothing = nil declare root: { child: number } | Nothing")?
        );
        Ok(())
    }

    #[test]
    fn an_empty_definition_file_has_no_runtime_members() -> Result<(), Error> {
        assert!(surface("type Unused = { member: number }")?.is_empty());
        Ok(())
    }

    #[test]
    fn malformed_or_unenumerable_definitions_fail() {
        for source in [
            "declare broken: {",
            "declare root: Missing",
            "type Loop = { again: Loop } declare root: Loop",
            "declare root: { [string]: number }",
            "declare root: { a: number } | { b: number }",
            "declare root: any",
            "type T = { wrong: number } type Module<T = { right: number }> = { child: T } declare root: Module",
            "type Module<T... = ...number> = { child: () -> T... } declare root: Module",
            "declare root: { [string]: (() -> ()) | number }",
            "declare root: { [number]: () -> () }",
            "local root = {}",
        ] {
            assert!(surface(source).is_err(), "{source}");
        }
    }
}
