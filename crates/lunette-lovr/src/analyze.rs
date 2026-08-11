//! The Luau type checker, built from the Luau the LÖVR fork carries.
//!
//! `lunette check` and the standing check both run through here, so the command
//! a user reaches for and the check CI runs are one code path. The C surface it
//! wraps is `analyze.cpp`.

use std::{
    ffi::{CStr, CString, NulError, c_char},
    fmt,
    path::{Path, PathBuf},
    ptr, slice,
};

/// What a check was asked to do.
#[derive(Clone, Debug)]
pub struct Request {
    /// Loaded into the global scope before anything is checked.
    pub definitions: Option<PathBuf>,
    /// The files to check. Each is its own module name.
    pub roots: Vec<PathBuf>,
    pub strict: bool,
    /// The old type solver, which is not upstream's default.
    pub old_solver: bool,
}

impl Request {
    /// A strict check of `roots` against `definitions`, on the new solver.
    #[must_use]
    pub fn new(definitions: Option<PathBuf>, roots: Vec<PathBuf>) -> Self {
        Self {
            definitions,
            roots,
            strict: true,
            old_solver: false,
        }
    }
}

/// What one check found.
#[derive(Clone, Debug, Default)]
pub struct Report {
    pub diagnostics: Vec<Diagnostic>,
    /// The roots that were read. A root absent from here was skipped, which no
    /// count of diagnostics would reveal.
    pub checked: Vec<PathBuf>,
}

impl Report {
    /// Whether anything worth failing a build over was found.
    ///
    /// Lint warnings do not count; lint errors do.
    #[must_use]
    pub fn is_clean(&self) -> bool {
        !self
            .diagnostics
            .iter()
            .any(|diagnostic| diagnostic.kind != Kind::LintWarning)
    }

    /// The roots that were asked for and not read.
    #[must_use]
    pub fn skipped<'a>(&self, request: &'a Request) -> Vec<&'a Path> {
        request
            .roots
            .iter()
            .filter(|root| !self.checked.iter().any(|checked| checked == *root))
            .map(PathBuf::as_path)
            .collect()
    }
}

/// One thing the checker found.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Diagnostic {
    pub kind: Kind,
    pub module: PathBuf,
    /// One-based, as an editor counts them.
    pub line: u32,
    pub column: u32,
    pub message: String,
}

impl fmt::Display for Diagnostic {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "{}({},{}): {}: {}",
            self.module.display(),
            self.line,
            self.column,
            self.kind,
            self.message
        )
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    TypeError,
    SyntaxError,
    LintError,
    LintWarning,
}

impl fmt::Display for Kind {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let name = match self {
            Self::TypeError => "TypeError",
            Self::SyntaxError => "SyntaxError",
            Self::LintError => "LintError",
            Self::LintWarning => "LintWarning",
        };
        f.write_str(name)
    }
}

/// Checks `request`.
///
/// # Errors
///
/// If a path holds an interior NUL, or the checker could not run at all — an
/// unreadable definitions file, or one that does not load. A definitions file
/// that failed to load carries its own diagnostics on the error.
pub fn check(request: &Request) -> Result<Report, Error> {
    let definitions = request
        .definitions
        .as_ref()
        .map(|path| CString::new(path.as_os_str().as_encoded_bytes()))
        .transpose()
        .map_err(Error::Path)?;
    let roots = request
        .roots
        .iter()
        .map(|path| CString::new(path.as_os_str().as_encoded_bytes()))
        .collect::<Result<Vec<_>, _>>()
        .map_err(Error::Path)?;
    let root_pointers: Vec<*const c_char> = roots.iter().map(|root| root.as_ptr()).collect();

    let raw = ffi::lunette_luau_request {
        definitions: definitions
            .as_ref()
            .map_or(ptr::null(), |path| path.as_ptr()),
        roots: root_pointers.as_ptr(),
        root_count: root_pointers.len(),
        strict: request.strict,
        old_solver: request.old_solver,
    };

    // SAFETY: every pointer in `raw` is valid for the call, and the callee
    // copies what it keeps. The report is freed below on every path.
    let report = unsafe { ffi::lunette_luau_check(&raw) };
    if report.is_null() {
        return Err(Error::Failed {
            reason: "the checker returned nothing".to_owned(),
            diagnostics: Vec::new(),
        });
    }

    // SAFETY: a non-null report is a live allocation the callee filled in, and
    // its arrays are valid for their stated counts.
    let outcome = unsafe { collect(report) };
    // SAFETY: the report has not been freed, and nothing borrows it now that
    // `collect` has copied everything out.
    unsafe { ffi::lunette_luau_report_free(report) };
    outcome
}

/// # Safety
///
/// `report` must be a live report whose arrays match their counts.
unsafe fn collect(report: *mut ffi::lunette_luau_report) -> Result<Report, Error> {
    // SAFETY: the caller guarantees the report is live.
    let report = unsafe { &*report };

    let diagnostics = if report.diagnostics.is_null() {
        Vec::new()
    } else {
        // SAFETY: the pointer is non-null and the count is the callee's own.
        unsafe { slice::from_raw_parts(report.diagnostics, report.diagnostic_count) }
            .iter()
            // SAFETY: each string is NUL-terminated and lives until the free.
            .map(|raw| unsafe { diagnostic(raw) })
            .collect()
    };

    if !report.failure.is_null() {
        // SAFETY: as above.
        let reason = unsafe { CStr::from_ptr(report.failure) }
            .to_string_lossy()
            .into_owned();
        return Err(Error::Failed {
            reason,
            diagnostics,
        });
    }

    let checked = if report.checked.is_null() {
        Vec::new()
    } else {
        // SAFETY: as above.
        unsafe { slice::from_raw_parts(report.checked, report.checked_count) }
            .iter()
            // SAFETY: as above.
            .map(|raw| {
                PathBuf::from(
                    unsafe { CStr::from_ptr(*raw) }
                        .to_string_lossy()
                        .into_owned(),
                )
            })
            .collect()
    };

    Ok(Report {
        diagnostics,
        checked,
    })
}

/// # Safety
///
/// `raw`'s strings must be NUL-terminated and live for the call.
unsafe fn diagnostic(raw: &ffi::lunette_luau_diagnostic) -> Diagnostic {
    let kind = match raw.kind {
        ffi::LUNETTE_LUAU_SYNTAX_ERROR => Kind::SyntaxError,
        ffi::LUNETTE_LUAU_LINT_ERROR => Kind::LintError,
        ffi::LUNETTE_LUAU_LINT_WARNING => Kind::LintWarning,
        _ => Kind::TypeError,
    };
    // SAFETY: the caller guarantees the strings.
    let module = unsafe { CStr::from_ptr(raw.module) }
        .to_string_lossy()
        .into_owned();
    // SAFETY: as above.
    let message = unsafe { CStr::from_ptr(raw.message) }
        .to_string_lossy()
        .into_owned();

    Diagnostic {
        kind,
        module: PathBuf::from(module),
        line: raw.line.max(0).unsigned_abs(),
        column: raw.column.max(0).unsigned_abs(),
        message,
    }
}

/// A check that could not run.
#[derive(Debug)]
pub enum Error {
    /// A path held an interior NUL.
    Path(NulError),
    /// The checker refused the request. `diagnostics` carries what it managed
    /// to say, which for a definitions file that did not load is why.
    Failed {
        reason: String,
        diagnostics: Vec<Diagnostic>,
    },
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "luau: ")?;
        match self {
            Self::Path(_) => write!(f, "a path holds an interior NUL"),
            Self::Failed { reason, .. } => write!(f, "{reason}"),
        }
    }
}

impl std::error::Error for Error {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Path(error) => Some(error),
            Self::Failed { .. } => None,
        }
    }
}

mod ffi {
    use std::ffi::{c_char, c_int};

    pub const LUNETTE_LUAU_SYNTAX_ERROR: c_int = 1;
    pub const LUNETTE_LUAU_LINT_ERROR: c_int = 2;
    pub const LUNETTE_LUAU_LINT_WARNING: c_int = 3;

    #[repr(C)]
    pub struct lunette_luau_request {
        pub definitions: *const c_char,
        pub roots: *const *const c_char,
        pub root_count: usize,
        pub strict: bool,
        pub old_solver: bool,
    }

    #[repr(C)]
    pub struct lunette_luau_diagnostic {
        pub kind: c_int,
        pub module: *mut c_char,
        pub line: c_int,
        pub column: c_int,
        pub message: *mut c_char,
    }

    #[repr(C)]
    pub struct lunette_luau_report {
        pub diagnostics: *mut lunette_luau_diagnostic,
        pub diagnostic_count: usize,
        pub checked: *mut *mut c_char,
        pub checked_count: usize,
        pub failure: *mut c_char,
    }

    unsafe extern "C" {
        pub fn lunette_luau_check(request: *const lunette_luau_request)
        -> *mut lunette_luau_report;
        pub fn lunette_luau_report_free(report: *mut lunette_luau_report);
    }
}

#[cfg(test)]
#[expect(
    clippy::expect_used,
    reason = "a failure here is the test failing, and the message names which case"
)]
mod tests {
    use std::io::Write;

    use super::{Kind, Request, check};

    fn write(directory: &tempfile::TempDir, name: &str, source: &str) -> std::path::PathBuf {
        let path = directory.path().join(name);
        let mut file = std::fs::File::create(&path).expect("the fixture should be writable");
        file.write_all(source.as_bytes())
            .expect("the fixture should be written");
        path
    }

    #[test]
    fn a_well_typed_root_is_clean_and_reported_as_checked() {
        let directory = tempfile::TempDir::new().expect("a temporary directory");
        let root = write(&directory, "clean.luau", "local x: number = 1\nreturn x\n");
        let request = Request::new(None, vec![root.clone()]);

        let report = check(&request).expect("the check should run");

        assert!(report.is_clean(), "{:?}", report.diagnostics);
        assert_eq!(report.checked, vec![root], "the roots that were read");
        assert!(report.skipped(&request).is_empty(), "the skipped roots");
    }

    #[test]
    fn a_type_error_is_reported_against_its_root() {
        let directory = tempfile::TempDir::new().expect("a temporary directory");
        let root = write(
            &directory,
            "broken.luau",
            "local x: number = 'a'\nreturn x\n",
        );
        let request = Request::new(None, vec![root.clone()]);

        let report = check(&request).expect("the check should run");

        assert!(!report.is_clean(), "a chunk assigning a string to a number");
        let diagnostic = report
            .diagnostics
            .iter()
            .find(|diagnostic| diagnostic.kind == Kind::TypeError)
            .expect("a type error");
        assert_eq!(diagnostic.module, root, "the module it is reported against");
        assert_eq!(diagnostic.line, 1, "the line");
    }

    /// A root that cannot be read produces no diagnostics at all, which is the
    /// shape that let unresolved requires silently skip whole files.
    #[test]
    fn an_unreadable_root_is_reported_as_skipped() {
        let directory = tempfile::TempDir::new().expect("a temporary directory");
        let missing = directory.path().join("never-written.luau");
        let request = Request::new(None, vec![missing.clone()]);

        let report = check(&request).expect("the check should run");

        assert_eq!(report.checked, Vec::<std::path::PathBuf>::new(), "checked");
        assert_eq!(
            report.skipped(&request),
            vec![missing.as_path()],
            "the skipped roots"
        );
        assert!(!report.is_clean(), "an unreadable root is not a pass");
    }

    #[test]
    fn definitions_reach_the_checked_module() {
        let directory = tempfile::TempDir::new().expect("a temporary directory");
        let definitions = write(
            &directory,
            "defs.luau",
            "declare gadget: { spin: () -> number }\n",
        );
        let root = write(
            &directory,
            "uses.luau",
            "local n: string = gadget.spin()\nreturn n\n",
        );
        let request = Request::new(Some(definitions), vec![root]);

        let report = check(&request).expect("the check should run");

        assert!(!report.is_clean(), "assigning a number to a string");
        assert!(
            report
                .diagnostics
                .iter()
                .any(|diagnostic| diagnostic.message.contains("string")),
            "{:?}",
            report.diagnostics
        );
    }

    #[test]
    fn a_definitions_file_that_does_not_parse_fails_with_its_reason() {
        let directory = tempfile::TempDir::new().expect("a temporary directory");
        let definitions = write(&directory, "bad.luau", "declare class Joint end\n");
        let root = write(&directory, "any.luau", "return 1\n");
        let request = Request::new(Some(definitions), vec![root]);

        let error = check(&request).expect_err("the check should refuse to run");

        let super::Error::Failed { diagnostics, .. } = &error else {
            panic!("expected a load failure, got {error:?}");
        };
        assert!(
            diagnostics
                .iter()
                .any(|diagnostic| diagnostic.kind == Kind::SyntaxError),
            "{diagnostics:?}"
        );
    }
}
