//! Pure selection of a host input provider.
//!
//! [`select`] tries providers in the configured order, records failures, and
//! returns a dummy provider when none succeeds. Its opener is a function
//! parameter, so selection tests do not access devices or compositors.

use std::{error::Error, fmt, io, path::PathBuf};

/// One mechanism for reaching the host's keyboard and pointer.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum ProviderKind {
    /// Injects below the compositor through `/dev/uinput` and requires write
    /// access to the device node.
    Uinput,
    /// Uses `zwlr_virtual_pointer_v1` and `zwp_virtual_keyboard_v1` without
    /// special permissions. Only the wlroots family implements these protocols.
    WlVirtual,
    /// Accepts every call without reaching the host desktop.
    Dummy,
}

impl ProviderKind {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Uinput => "uinput",
            Self::WlVirtual => "wl_virtual",
            Self::Dummy => "dummy",
        }
    }
}

impl fmt::Display for ProviderKind {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// The configured order of real providers.
///
/// The default tries uinput and then `wl_virtual`. uinput works under any
/// compositor and under X11; `wl_virtual` is implemented by the wlroots family.
/// [`select`] uses the dummy when no configured provider succeeds. Duplicate
/// providers are removed while preserving their first position.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ProviderOrder(Vec<ProviderKind>);

impl ProviderOrder {
    /// Removes the dummy and duplicate providers while preserving order.
    ///
    /// A dummy before a real provider would stop the chain and report success.
    /// [`crate::hid::HidConfig::disabled`] represents an intentional choice to
    /// use no host input.
    #[must_use]
    pub fn new(order: impl IntoIterator<Item = ProviderKind>) -> Self {
        let mut kinds = Vec::new();
        for kind in order {
            if kind != ProviderKind::Dummy && !kinds.contains(&kind) {
                kinds.push(kind);
            }
        }
        Self(kinds)
    }

    /// Moves `preferred` to the front when it names a real provider.
    #[must_use]
    pub fn preferring(preferred: ProviderKind) -> Self {
        let mut kinds = vec![preferred];
        kinds.extend(Self::default().0);
        Self::new(kinds)
    }

    /// Returns an empty order. The caller selects the dummy without attempting
    /// a real provider.
    #[must_use]
    pub const fn none() -> Self {
        Self(Vec::new())
    }

    #[must_use]
    pub fn kinds(&self) -> &[ProviderKind] {
        &self.0
    }
}

impl Default for ProviderOrder {
    fn default() -> Self {
        Self(vec![ProviderKind::Uinput, ProviderKind::WlVirtual])
    }
}

impl fmt::Display for ProviderOrder {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if self.0.is_empty() {
            return f.write_str("nothing");
        }
        for (index, kind) in self.0.iter().enumerate() {
            if index > 0 {
                f.write_str(", then ")?;
            }
            write!(f, "{kind}")?;
        }
        Ok(())
    }
}

#[derive(Debug)]
pub struct Selected<P> {
    /// The selected provider, or the dummy when no configured provider succeeds.
    pub provider: P,
    pub kind: ProviderKind,
    /// Every configured provider that failed, in the order it was tried.
    pub failures: Vec<ProviderFailure>,
}

impl<P> Selected<P> {
    /// Returns the failures when the dummy provider was selected after at least
    /// one configured provider failed. An empty order returns `None`.
    #[must_use]
    pub fn unreachable(&self) -> Option<NoHostInput> {
        (self.kind == ProviderKind::Dummy && !self.failures.is_empty())
            .then(|| NoHostInput::from_failures(self.failures.clone()))
    }
}

/// Tries each provider in order and returns the first successful result.
///
/// `open` is the production device or compositor boundary and the test seam.
/// `dummy` supplies the result when every configured provider fails, so an
/// opener cannot accidentally report the dummy as a successful provider.
pub fn select<P>(
    order: &ProviderOrder,
    mut open: impl FnMut(ProviderKind) -> Result<P, ProviderError>,
    dummy: impl FnOnce() -> P,
) -> Selected<P> {
    let mut failures = Vec::new();
    for kind in order.kinds().iter().copied() {
        match open(kind) {
            Ok(provider) => {
                return Selected {
                    provider,
                    kind,
                    failures,
                };
            }
            Err(cause) => failures.push(ProviderFailure { kind, cause }),
        }
    }
    Selected {
        provider: dummy(),
        kind: ProviderKind::Dummy,
        failures,
    }
}

/// A failed provider attempt and its cause.
#[derive(Debug)]
pub struct ProviderFailure {
    kind: ProviderKind,
    cause: ProviderError,
}

impl ProviderFailure {
    #[must_use]
    pub const fn kind(&self) -> ProviderKind {
        self.kind
    }

    #[must_use]
    pub const fn cause(&self) -> &ProviderError {
        &self.cause
    }
}

impl Clone for ProviderFailure {
    fn clone(&self) -> Self {
        Self {
            kind: self.kind,
            cause: self.cause.cloned(),
        }
    }
}

impl fmt::Display for ProviderFailure {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}: {}", self.kind, self.cause)
    }
}

impl Error for ProviderFailure {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        Some(&self.cause)
    }
}

/// Why one provider could not be opened, or could not carry on.
#[derive(Debug)]
pub enum ProviderError {
    /// A system call failed. `operation` describes the operation, and `path`
    /// identifies its file when one exists.
    Io {
        operation: &'static str,
        path: Option<PathBuf>,
        source: io::Error,
    },
    /// The provider needs a value that the caller did not supply, such as the
    /// host Wayland socket. This also describes a headless host without a
    /// Wayland socket, before any connection attempt is made.
    NotConfigured { what: &'static str },
    /// The host compositor does not offer a required interface or usable version.
    MissingInterface {
        interface: &'static str,
        detail: String,
    },
    /// The connection to the host compositor failed or ended. The provider
    /// cannot continue using that connection.
    Disconnected { detail: String },
}

impl ProviderError {
    /// Returns whether the provider cannot be used again on its current
    /// connection. A single failed write is not fatal.
    #[must_use]
    pub const fn is_fatal(&self) -> bool {
        matches!(self, Self::Disconnected { .. })
    }

    /// Clones this error for reporting. Raw OS error codes are preserved, and
    /// other error state is rendered into a message; the copy is not for retrying.
    #[must_use]
    fn cloned(&self) -> Self {
        match self {
            Self::Io {
                operation,
                path,
                source,
            } => Self::Io {
                operation,
                path: path.clone(),
                source: match source.raw_os_error() {
                    Some(code) => io::Error::from_raw_os_error(code),
                    None => io::Error::new(source.kind(), source.to_string()),
                },
            },
            Self::NotConfigured { what } => Self::NotConfigured { what },
            Self::MissingInterface { interface, detail } => Self::MissingInterface {
                interface,
                detail: detail.clone(),
            },
            Self::Disconnected { detail } => Self::Disconnected {
                detail: detail.clone(),
            },
        }
    }
}

impl fmt::Display for ProviderError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Io {
                operation,
                path: Some(path),
                ..
            } => write!(f, "could not {operation} {}", path.display()),
            Self::Io {
                operation,
                path: None,
                ..
            } => write!(f, "could not {operation}"),
            Self::NotConfigured { what } => write!(f, "no {what} was supplied"),
            Self::MissingInterface { interface, detail } => {
                write!(
                    f,
                    "the host compositor does not offer {interface}: {detail}"
                )
            }
            Self::Disconnected { detail } => {
                write!(f, "the host compositor connection ended: {detail}")
            }
        }
    }
}

impl Error for ProviderError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        match self {
            Self::Io { source, .. } => Some(source),
            Self::NotConfigured { .. }
            | Self::MissingInterface { .. }
            | Self::Disconnected { .. } => None,
        }
    }
}

/// Reports that no provider reached the host.
///
/// Stores every provider failure for display. [`Error::source`] returns the
/// first failure, which may wrap an underlying system error.
#[derive(Clone, Debug)]
pub struct NoHostInput(Vec<ProviderFailure>);

impl NoHostInput {
    #[must_use]
    pub fn from_failures(failures: Vec<ProviderFailure>) -> Self {
        Self(failures)
    }

    #[must_use]
    pub fn failures(&self) -> &[ProviderFailure] {
        &self.0
    }
}

impl fmt::Display for NoHostInput {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("host input: no provider could reach the host desktop")?;
        for failure in &self.0 {
            write!(f, "; {failure}")?;
        }
        Ok(())
    }
}

impl Error for NoHostInput {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        self.0
            .first()
            .map(|failure| failure as &(dyn Error + 'static))
    }
}

#[cfg(test)]
#[expect(
    clippy::expect_used,
    reason = "a failed expectation is how a test reports a failure; the ban is on production code"
)]
mod tests {
    use pretty_assertions::assert_eq;

    use super::*;

    /// A test provider that avoids opening devices or compositors.
    #[derive(Debug, PartialEq, Eq)]
    struct Opened(ProviderKind);

    fn missing(interface: &'static str) -> ProviderError {
        ProviderError::MissingInterface {
            interface,
            detail: "not present".to_owned(),
        }
    }

    fn denied() -> ProviderError {
        ProviderError::Io {
            operation: "open",
            path: Some(PathBuf::from("/dev/uinput")),
            source: io::Error::from_raw_os_error(13),
        }
    }

    fn chain(order: &ProviderOrder, available: &[ProviderKind]) -> Selected<Opened> {
        select(
            order,
            |kind| {
                if available.contains(&kind) {
                    Ok(Opened(kind))
                } else if kind == ProviderKind::Uinput {
                    Err(denied())
                } else {
                    Err(missing("zwlr_virtual_pointer_v1"))
                }
            },
            || Opened(ProviderKind::Dummy),
        )
    }

    #[test]
    fn uinput_available_selects_uinput() {
        let selected = chain(&ProviderOrder::default(), &[ProviderKind::Uinput]);

        assert_eq!(selected.kind, ProviderKind::Uinput);
        assert!(selected.failures.is_empty());
        assert!(selected.unreachable().is_none());
    }

    #[test]
    fn uinput_unavailable_falls_through_to_wl_virtual() {
        let selected = chain(&ProviderOrder::default(), &[ProviderKind::WlVirtual]);

        assert_eq!(selected.kind, ProviderKind::WlVirtual);
        assert_eq!(
            selected
                .failures
                .iter()
                .map(ProviderFailure::kind)
                .collect::<Vec<_>>(),
            vec![ProviderKind::Uinput],
        );
    }

    #[test]
    fn a_provider_ahead_in_the_order_is_still_tried_first() {
        let mut attempted = Vec::new();
        let selected = select(
            &ProviderOrder::default(),
            |kind| {
                attempted.push(kind);
                Err::<Opened, _>(missing("anything"))
            },
            || Opened(ProviderKind::Dummy),
        );

        assert_eq!(
            attempted,
            vec![ProviderKind::Uinput, ProviderKind::WlVirtual],
        );
        assert_eq!(selected.kind, ProviderKind::Dummy);
    }

    #[test]
    fn neither_available_selects_the_dummy_and_names_both_failures() {
        let selected = chain(&ProviderOrder::default(), &[]);

        assert_eq!(selected.kind, ProviderKind::Dummy);

        let error = selected.unreachable().expect("nothing reached the host");
        let rendered = error.to_string();

        assert!(
            rendered.contains("uinput: could not open /dev/uinput"),
            "{rendered}"
        );
        assert!(
            rendered
                .contains("wl_virtual: the host compositor does not offer zwlr_virtual_pointer_v1"),
            "{rendered}",
        );
    }

    #[test]
    fn the_cause_chain_walks_from_the_first_failure_to_its_system_error() {
        let selected = chain(&ProviderOrder::default(), &[]);
        let error = selected.unreachable().expect("nothing reached the host");

        let first = error.source().expect("the first failure");
        assert_eq!(first.to_string(), "uinput: could not open /dev/uinput");

        let cause = first.source().expect("what that mechanism said");
        assert_eq!(cause.to_string(), "could not open /dev/uinput");

        let system = cause.source().expect("the system error under it");
        assert_eq!(
            system
                .downcast_ref::<io::Error>()
                .map(io::Error::raw_os_error),
            Some(Some(13)),
        );
    }

    #[test]
    fn the_configured_override_is_tried_first_and_the_rest_still_stand_behind_it() {
        let order = ProviderOrder::preferring(ProviderKind::WlVirtual);

        assert_eq!(
            order.kinds(),
            [ProviderKind::WlVirtual, ProviderKind::Uinput],
        );

        let selected = chain(&order, &[ProviderKind::Uinput, ProviderKind::WlVirtual]);
        assert_eq!(selected.kind, ProviderKind::WlVirtual);
    }

    #[test]
    fn an_override_naming_the_default_first_choice_changes_nothing() {
        assert_eq!(
            ProviderOrder::preferring(ProviderKind::Uinput),
            ProviderOrder::default(),
        );
    }

    #[test]
    fn the_dummy_cannot_be_placed_ahead_of_a_real_provider() {
        let order = ProviderOrder::new([ProviderKind::Dummy, ProviderKind::Uinput]);

        assert_eq!(order.kinds(), [ProviderKind::Uinput]);
    }

    #[test]
    fn an_order_naming_a_mechanism_twice_attempts_it_once() {
        let order = ProviderOrder::new([ProviderKind::Uinput, ProviderKind::Uinput]);

        assert_eq!(order.kinds(), [ProviderKind::Uinput]);
    }

    #[test]
    fn an_empty_order_selects_the_dummy_without_reporting_a_failure() {
        let selected = chain(&ProviderOrder::none(), &[ProviderKind::Uinput]);

        assert_eq!(selected.kind, ProviderKind::Dummy);
        assert!(selected.failures.is_empty());
        assert!(selected.unreachable().is_none());
    }

    #[test]
    fn a_disconnected_compositor_is_fatal_and_a_missing_interface_is_not() {
        assert!(
            ProviderError::Disconnected {
                detail: "broken pipe".to_owned(),
            }
            .is_fatal()
        );
        assert!(!missing("zwlr_virtual_pointer_v1").is_fatal());
        assert!(!denied().is_fatal());
    }
}
