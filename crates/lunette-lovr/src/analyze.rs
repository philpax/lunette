//! Luau type checker built from the interpreter vendored by the LÖVR fork.

use std::{
    ffi::{CStr, CString, NulError, c_char},
    fmt,
    path::{Path, PathBuf},
    ptr, slice,
};

#[derive(Clone, Debug)]
pub struct Request {
    /// Definitions loaded into the global scope before checking roots.
    pub definitions: Option<PathBuf>,
    /// Root files checked as separate modules.
    pub roots: Vec<PathBuf>,
}

impl Request {
    /// Creates a request, which the checker runs in strict mode with the current type solver.
    #[must_use]
    pub fn new(definitions: Option<PathBuf>, roots: Vec<PathBuf>) -> Self {
        Self { definitions, roots }
    }
}

#[derive(Clone, Debug, Default)]
pub struct Report {
    pub diagnostics: Vec<Diagnostic>,
    /// Roots the checker read. Missing roots are reported separately from diagnostics.
    pub checked: Vec<PathBuf>,
}

impl Report {
    /// Whether the report contains a diagnostic other than a lint warning, which does not fail a build.
    #[must_use]
    pub fn is_clean(&self) -> bool {
        !self
            .diagnostics
            .iter()
            .any(|diagnostic| diagnostic.kind != Kind::LintWarning)
    }

    /// The roots the request names that the check does not read.
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

/// One diagnostic the checker reports.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Diagnostic {
    pub kind: Kind,
    pub module: PathBuf,
    /// One-based lines and zero-based columns, matching Luau's numbering.
    pub line: u32,
    pub column: u32,
    pub end_line: u32,
    pub end_column: u32,
    pub message: String,
}

impl fmt::Display for Diagnostic {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "{}({},{}): {}: {}",
            self.module.display(),
            self.line,
            self.column + 1,
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
/// Checks may run on several threads at once. The checker sets Luau's process-global language flags once, on the first check.
///
/// # Errors
///
/// If a path holds an interior NUL, or the definitions file is unreadable or does not load. A load failure carries its diagnostics.
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
    };

    // SAFETY: every pointer in `raw` is valid for the call, and the callee
    // copies what it keeps. Every path that obtains a report frees it.
    let report = unsafe { ffi::lunette_luau_check(&raw) };
    if report.is_null() {
        return Err(Error::Failed {
            reason: "the checker returned nothing".to_owned(),
            diagnostics: Vec::new(),
        });
    }

    // SAFETY: a non-null report is a live allocation that the callee
    // populated, and its arrays are valid for their stated counts.
    let outcome = unsafe { collect(report) };
    // SAFETY: the report has not been freed, and nothing borrows it after
    // `collect` copies everything out.
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
        // SAFETY: the pointer is non-null, and the count belongs to the
        // callee's report.
        unsafe { slice::from_raw_parts(report.diagnostics, report.diagnostic_count) }
            .iter()
            // SAFETY: each string is NUL-terminated and remains valid until
            // the report is freed.
            .map(|raw| unsafe { diagnostic(raw) })
            .collect()
    };

    if !report.failure.is_null() {
        // SAFETY: the pointer is non-null, and the string is NUL-terminated.
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
        // SAFETY: the pointer is non-null, the count belongs to the callee's report, and each string is NUL-terminated until the report is freed.
        unsafe { slice::from_raw_parts(report.checked, report.checked_count) }
            .iter()
            // SAFETY: the pointer for the string is valid for the
            // lifetime of the report's checked array.
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
    // SAFETY: the caller guarantees the string is NUL-terminated and
    // remains valid until the report is freed.
    let message = unsafe { CStr::from_ptr(raw.message) }
        .to_string_lossy()
        .into_owned();

    Diagnostic {
        kind,
        module: PathBuf::from(module),
        line: raw.line.max(0).unsigned_abs(),
        column: raw.column.max(0).unsigned_abs(),
        end_line: raw.end_line.max(0).unsigned_abs(),
        end_column: raw.end_column.max(0).unsigned_abs(),
        message,
    }
}

/// A check that cannot run.
#[derive(Debug)]
pub enum Error {
    /// A path holds an interior NUL.
    Path(NulError),
    /// The checker rejects the request. `diagnostics` holds what it produced alongside the rejection, including why a definitions file fails to load.
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
    }

    #[repr(C)]
    pub struct lunette_luau_diagnostic {
        pub kind: c_int,
        pub module: *mut c_char,
        pub line: c_int,
        pub column: c_int,
        pub end_line: c_int,
        pub end_column: c_int,
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

    /// A root that cannot be read produces no diagnostics, so without the skipped-roots report an unresolved require would skip a whole file silently.
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
