//! Parser observations of global module-loader use and named member calls.

use std::{
    ffi::{CStr, CString, c_char, c_int},
    path::{Path, PathBuf},
    slice,
};

use crate::analyze::{Error, annotation_path, diagnostic, ffi::lunette_luau_diagnostic};

/// Source and explicit resolution context for observing module-loader uses.
#[derive(Clone, Debug)]
pub struct RequireRequest {
    pub source: PathBuf,
    pub allowed_roots: Vec<PathBuf>,
    /// Request-scoped overrides, with unprefixed alias names. Empty keeps ordinary `.luaurc` resolution.
    pub aliases: Vec<RequireAlias>,
    /// Exact terminal module names, with no file target or graph node.
    pub preloaded: Vec<String>,
    /// Exact bare literals resolved from a configuration's source anchor through Navigator.
    pub configured: Vec<ConfiguredRequire>,
}

#[derive(Clone, Debug)]
pub struct RequireAlias {
    pub name: String,
    pub path: PathBuf,
}

#[derive(Clone, Debug)]
pub struct ConfiguredRequire {
    pub literal: String,
    pub anchor: PathBuf,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RequireObservation {
    /// One-based source line.
    pub line: u32,
    /// Zero-based source column, matching Luau diagnostics.
    pub column: u32,
    pub requested: Option<String>,
    pub outcome: RequireOutcome,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum RequireOutcome {
    Resolved(PathBuf),
    Preloaded(String),
    Dynamic,
    Escaped,
    Overwritten,
    Unsupported,
    Unresolved(String),
}

/// A syntactic call to a named dot, colon, or constant-index member, independent of receiver binding.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MemberCallObservation {
    /// One-based source line.
    pub line: u32,
    /// Zero-based source column.
    pub column: u32,
    /// Present only when the call has exactly one literal string argument.
    pub argument: Option<String>,
}

/// Observes global loader calls, escapes, overwrites, and unsupported direct `_G` access.
///
/// Local shadows and service member calls are not module-loader uses. Resolved paths are canonical and remain inside the allowed roots, including through symlinks.
///
/// # Errors
///
/// Rejects invalid context data, unreadable source files, parse failures, or values that cannot be represented across the FFI boundary.
pub fn inspect_requires(request: &RequireRequest) -> Result<Vec<RequireObservation>, Error> {
    let source = path_string(&request.source)?;
    let roots = request
        .allowed_roots
        .iter()
        .map(|path| path_string(path))
        .collect::<Result<Vec<_>, _>>()?;
    let root_pointers: Vec<_> = roots.iter().map(|root| root.as_ptr()).collect();
    let aliases = request
        .aliases
        .iter()
        .map(|alias| Ok((text_string(&alias.name)?, path_string(&alias.path)?)))
        .collect::<Result<Vec<_>, Error>>()?;
    let alias_pointers: Vec<_> = aliases
        .iter()
        .map(|(name, path)| ffi::Alias {
            name: name.as_ptr(),
            path: path.as_ptr(),
        })
        .collect();
    let preloaded = request
        .preloaded
        .iter()
        .map(|name| text_string(name))
        .collect::<Result<Vec<_>, _>>()?;
    let preload_pointers: Vec<_> = preloaded.iter().map(|name| name.as_ptr()).collect();
    let configured = request
        .configured
        .iter()
        .map(|entry| Ok((text_string(&entry.literal)?, path_string(&entry.anchor)?)))
        .collect::<Result<Vec<_>, Error>>()?;
    let configured_pointers: Vec<_> = configured
        .iter()
        .map(|(literal, anchor)| ffi::Configured {
            literal: literal.as_ptr(),
            anchor: anchor.as_ptr(),
        })
        .collect();
    let raw = ffi::Request {
        source: source.as_ptr(),
        allowed_roots: root_pointers.as_ptr(),
        allowed_root_count: roots.len(),
        aliases: alias_pointers.as_ptr(),
        alias_count: aliases.len(),
        preloaded: preload_pointers.as_ptr(),
        preloaded_count: preloaded.len(),
        configured: configured_pointers.as_ptr(),
        configured_count: configured.len(),
    };
    // SAFETY: every request pointer lives for the call, which retains no request data.
    let report = unsafe { ffi::lunette_luau_inspect_requires(&raw) };
    let owned = OwnedReport::new(report)?;
    owned
        .observations()?
        .iter()
        .map(|raw| {
            let requested = requested(raw)?;
            let outcome = match raw.outcome {
                ffi::RESOLVED => RequireOutcome::Resolved(detail_path(raw)?),
                ffi::PRELOADED => RequireOutcome::Preloaded(detail(raw)?),
                ffi::DYNAMIC => RequireOutcome::Dynamic,
                ffi::ESCAPED => RequireOutcome::Escaped,
                ffi::OVERWRITTEN => RequireOutcome::Overwritten,
                ffi::UNSUPPORTED => RequireOutcome::Unsupported,
                ffi::UNRESOLVED => RequireOutcome::Unresolved(detail(raw)?),
                _ => return Err(failed("the observer returned an unknown outcome")),
            };
            Ok(RequireObservation {
                line: raw.line.max(0).unsigned_abs(),
                column: raw.column.max(0).unsigned_abs(),
                requested,
                outcome,
            })
        })
        .collect()
}

/// Observes calls to a named member without inferring what its receiver represents.
///
/// # Errors
///
/// Returns source-read and parse failures, or unrepresentable input/output values, rather than an empty success.
pub fn inspect_member_calls(
    source: &Path,
    member_name: &str,
) -> Result<Vec<MemberCallObservation>, Error> {
    let source = path_string(source)?;
    let member = text_string(member_name)?;
    // SAFETY: both strings live for the call, and ownership of the result is transferred.
    let raw = unsafe { ffi::lunette_luau_inspect_member_calls(source.as_ptr(), member.as_ptr()) };
    let report = OwnedReport::new(raw)?;
    report
        .observations()?
        .iter()
        .map(|raw| {
            Ok(MemberCallObservation {
                line: raw.line.max(0).unsigned_abs(),
                column: raw.column.max(0).unsigned_abs(),
                argument: requested(raw)?,
            })
        })
        .collect()
}

fn path_string(path: &Path) -> Result<CString, Error> {
    CString::new(path.as_os_str().as_encoded_bytes()).map_err(Error::Path)
}

fn text_string(text: &str) -> Result<CString, Error> {
    CString::new(text).map_err(|_| failed("a resolution name holds an interior NUL"))
}

fn failed(reason: &str) -> Error {
    Error::Failed {
        reason: reason.to_owned(),
        diagnostics: Vec::new(),
    }
}

struct OwnedReport(*mut ffi::Report);

impl OwnedReport {
    fn new(raw: *mut ffi::Report) -> Result<Self, Error> {
        if raw.is_null() {
            return Err(failed("the observer returned nothing"));
        }
        Ok(Self(raw))
    }

    fn observations(&self) -> Result<&[ffi::Observation], Error> {
        // SAFETY: this owner holds a live report until Drop.
        let report = unsafe { &*self.0 };
        if !report.failure.is_null() {
            // SAFETY: the report owns a NUL-terminated failure string.
            let reason = unsafe { CStr::from_ptr(report.failure) }
                .to_string_lossy()
                .into_owned();
            let diagnostics = if report.diagnostic_count == 0 {
                Vec::new()
            } else {
                if report.diagnostics.is_null() {
                    return Err(failed("the observer returned a missing diagnostic array"));
                }
                // SAFETY: the report's array matches its count and owns each diagnostic string.
                unsafe { slice::from_raw_parts(report.diagnostics, report.diagnostic_count) }
                    .iter()
                    // SAFETY: each diagnostic's strings live for the report's lifetime.
                    .map(|raw| unsafe { diagnostic(raw, annotation_path) })
                    .collect()
            };
            return Err(Error::Failed {
                reason,
                diagnostics,
            });
        }
        if report.observation_count == 0 {
            return Ok(&[]);
        }
        if report.observations.is_null() {
            return Err(failed("the observer returned a missing observation array"));
        }
        // SAFETY: the report owns an array of the stated count, valid until this owner is dropped.
        Ok(unsafe { slice::from_raw_parts(report.observations, report.observation_count) })
    }
}

impl Drop for OwnedReport {
    fn drop(&mut self) {
        // SAFETY: this owner holds the report and keeps no outstanding borrows when dropped.
        unsafe { ffi::lunette_require_report_free(self.0) };
    }
}

fn requested(raw: &ffi::Observation) -> Result<Option<String>, Error> {
    if raw.requested.is_null() {
        return Ok(None);
    }
    // SAFETY: the shim owns the literal buffer of the stated length until report destruction.
    let bytes = unsafe { slice::from_raw_parts(raw.requested.cast::<u8>(), raw.requested_length) };
    String::from_utf8(bytes.to_vec())
        .map(Some)
        .map_err(|_| failed("a source literal cannot be represented as UTF-8"))
}

fn detail(raw: &ffi::Observation) -> Result<String, Error> {
    if raw.detail.is_null() {
        return Err(failed("the observer returned no outcome detail"));
    }
    // SAFETY: the shim owns a NUL-terminated string until report destruction.
    unsafe { CStr::from_ptr(raw.detail) }
        .to_str()
        .map(str::to_owned)
        .map_err(|_| failed("an outcome detail cannot be represented as UTF-8"))
}

fn detail_path(raw: &ffi::Observation) -> Result<PathBuf, Error> {
    if raw.detail.is_null() {
        return Err(failed("the observer returned no resolved path"));
    }
    // SAFETY: the shim owns a NUL-terminated path until report destruction.
    Ok(annotation_path(unsafe { CStr::from_ptr(raw.detail) }))
}

#[cfg(test)]
mod tests {
    use std::ptr;

    use super::{OwnedReport, ffi, requested, text_string};

    #[test]
    fn null_reports_are_errors() {
        assert!(OwnedReport::new(ptr::null_mut()).is_err());
    }

    #[test]
    fn literal_lengths_preserve_nul_bytes_and_reject_invalid_utf8() {
        let mut literal = *b"a\0b";
        let mut raw = ffi::Observation {
            line: 1,
            column: 0,
            requested: literal.as_mut_ptr().cast(),
            requested_length: literal.len(),
            outcome: ffi::UNRESOLVED,
            detail: ptr::null_mut(),
        };
        assert!(matches!(requested(&raw), Ok(Some(value)) if value == "a\0b"));
        let mut invalid = [0xff_u8];
        raw.requested = invalid.as_mut_ptr().cast();
        raw.requested_length = invalid.len();
        assert!(requested(&raw).is_err());
        raw.requested = ptr::null_mut();
        assert!(matches!(requested(&raw), Ok(None)));
    }

    #[test]
    fn names_with_interior_nul_are_rejected_before_ffi() {
        assert!(text_string("module\0name").is_err());
    }
}

mod ffi {
    use super::{c_char, c_int, lunette_luau_diagnostic};

    pub const RESOLVED: c_int = 0;
    pub const PRELOADED: c_int = 1;
    pub const DYNAMIC: c_int = 2;
    pub const ESCAPED: c_int = 3;
    pub const OVERWRITTEN: c_int = 4;
    pub const UNSUPPORTED: c_int = 5;
    pub const UNRESOLVED: c_int = 6;

    #[repr(C)]
    pub struct Alias {
        pub name: *const c_char,
        pub path: *const c_char,
    }

    #[repr(C)]
    pub struct Configured {
        pub literal: *const c_char,
        pub anchor: *const c_char,
    }

    #[repr(C)]
    pub struct Request {
        pub source: *const c_char,
        pub allowed_roots: *const *const c_char,
        pub allowed_root_count: usize,
        pub aliases: *const Alias,
        pub alias_count: usize,
        pub preloaded: *const *const c_char,
        pub preloaded_count: usize,
        pub configured: *const Configured,
        pub configured_count: usize,
    }

    #[repr(C)]
    pub struct Observation {
        pub line: c_int,
        pub column: c_int,
        pub requested: *mut c_char,
        pub requested_length: usize,
        pub outcome: c_int,
        pub detail: *mut c_char,
    }

    #[repr(C)]
    pub struct Report {
        pub observations: *mut Observation,
        pub observation_count: usize,
        pub diagnostics: *mut lunette_luau_diagnostic,
        pub diagnostic_count: usize,
        pub failure: *mut c_char,
    }

    unsafe extern "C" {
        pub fn lunette_luau_inspect_requires(request: *const Request) -> *mut Report;
        pub fn lunette_luau_inspect_member_calls(
            source: *const c_char,
            member: *const c_char,
        ) -> *mut Report;
        pub fn lunette_require_report_free(report: *mut Report);
    }
}
