//! Which input provider lunette ends up using, and why the others were not.
//!
//! The order is a real fallback chain rather than a switch. WayVR's
//! `HidWrapper::new` (`subsystem/input.rs:22-41`) matches a configuration enum,
//! calls exactly one initialiser, and installs a dummy provider on failure; it
//! never tries the next mechanism. `docs/host-desktop.md:37` — "uinput is tried
//! first because it works regardless of the host compositor" — describes a chain
//! that does not exist there. It exists here: [`select`] walks the order, and
//! every failure it passes over is kept so the user is told what was tried and
//! what each attempt said.
//!
//! Pure. [`select`] takes a function that opens a provider, so the chain's
//! behaviour is exercised against fabricated outcomes and nothing here opens a
//! device or connects to a compositor.

use std::{error::Error, fmt, io, path::PathBuf};

/// One mechanism for reaching the host's keyboard and pointer.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum ProviderKind {
    /// `/dev/uinput`. Works under any compositor and under X11, because it
    /// injects below all of them, and needs write access to the device node.
    Uinput,
    /// `zwlr_virtual_pointer_v1` and `zwp_virtual_keyboard_v1`. Needs no
    /// permissions, and is implemented by the wlroots family only — KWin and
    /// mutter do not implement it and have said they do not plan to.
    WlVirtual,
    /// Nothing. Accepts every call and reaches nothing, so that a session
    /// without host input still runs.
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

/// The order the mechanisms are tried in.
///
/// [`Self::default`] is uinput and then `wl_virtual`. uinput first because it
/// works under any compositor and under X11; `wl_virtual` second because it is
/// wlroots-only. The dummy is not a member — [`select`] appends it, so it is
/// always last and can never be left out.
///
/// Duplicates are dropped on the way in, so an override that names a mechanism
/// already in the order moves it rather than adding a second attempt at it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ProviderOrder(Vec<ProviderKind>);

impl ProviderOrder {
    /// The order as configured, with duplicates and the dummy removed.
    ///
    /// The dummy is removed rather than honoured in place, because a dummy
    /// ahead of a real provider would make the chain stop at it and report
    /// success, which is the one outcome a fallback chain must not produce
    /// silently. Asking for no host input is
    /// [`crate::hid::HidConfig::disabled`], which says so.
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

    /// The default order with `preferred` moved to the front.
    ///
    /// This is the configuration override: a user who wants a specific provider
    /// names it, and the rest of the chain still stands behind it.
    #[must_use]
    pub fn preferring(preferred: ProviderKind) -> Self {
        let mut kinds = vec![preferred];
        kinds.extend(Self::default().0);
        Self::new(kinds)
    }

    /// The empty order, which selects the dummy without attempting anything.
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

/// What the chain settled on.
#[derive(Debug)]
pub struct Selected<P> {
    /// The provider that opened, or the dummy when none did.
    pub provider: P,
    pub kind: ProviderKind,
    /// Every attempt that failed before this one, in the order they were tried.
    pub failures: Vec<ProviderFailure>,
}

impl<P> Selected<P> {
    /// The error to report when nothing reached the host, or `None` when
    /// something did.
    ///
    /// A failure list that is not empty is worth reporting even when a later
    /// provider succeeded — the user asked for uinput and got `wl_virtual`, and
    /// that is a fact about their session. It is not an error, though, which is
    /// why only the dummy case produces one.
    #[must_use]
    pub fn unreachable(&self) -> Option<NoHostInput> {
        (self.kind == ProviderKind::Dummy && !self.failures.is_empty())
            .then(|| NoHostInput::from_failures(self.failures.clone()))
    }
}

/// Walks the order, taking the first provider that opens.
///
/// `open` is the seam. In production it opens a real device or connects to the
/// host compositor; in a test it returns whatever outcome the case is about, so
/// the chain's behaviour is checked without either.
///
/// `dummy` is the provider installed when the order is exhausted. It is a
/// separate argument rather than a variant `open` could return, so the chain
/// cannot terminate on anything but a real success or the dummy.
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

/// One provider that could not be opened, and why.
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
    /// A system call failed. `operation` names what was being done, and `path`
    /// is the file it was being done to where there is one.
    Io {
        operation: &'static str,
        path: Option<PathBuf>,
        source: io::Error,
    },
    /// The provider needs something the caller did not supply — a Wayland
    /// socket for `wl_virtual`, a keymap for a keyboard. Not a fault in the
    /// session: a headless host has no socket, and saying so is more useful
    /// than an error from a connect that was never going to work.
    NotConfigured { what: &'static str },
    /// The host compositor does not offer an interface the provider needs, or
    /// offers a version it cannot use.
    MissingInterface {
        interface: &'static str,
        detail: String,
    },
    /// The connection to the host compositor failed or ended.
    ///
    /// A host session ending is ordinary rather than exceptional, which is why
    /// it is an error the caller can act on rather than the panic WayVR takes
    /// at `wl_virtual.rs:146`, `:176`, `:199`, and `:204`.
    Disconnected { detail: String },
}

impl ProviderError {
    /// Whether the provider is finished rather than merely having failed once.
    ///
    /// A disconnected compositor never comes back on the same connection, so
    /// the provider is replaced. A single failed write is not grounds for that.
    #[must_use]
    pub const fn is_fatal(&self) -> bool {
        matches!(self, Self::Disconnected { .. })
    }

    /// A copy of this error.
    ///
    /// Written by hand rather than derived, because [`io::Error`] is not
    /// [`Clone`]: the raw OS error survives, and everything else is rendered
    /// into the message. The copy is for reporting, not for retrying.
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

/// Nothing in the chain reached the host.
///
/// Names every mechanism that was tried and what each said, because the whole
/// point of the chain is that the answer is rarely one thing. [`Error::source`]
/// walks to the first failure — the one the user asked for first, and so the one
/// they most likely want to fix — and from there to the system error under it.
#[derive(Clone, Debug)]
pub struct NoHostInput(Vec<ProviderFailure>);

impl NoHostInput {
    /// Reports that none of `failures` reached the host.
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

    /// A stand-in provider, so the chain is exercised without opening anything.
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

    /// Runs the chain against a set of mechanisms declared available.
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
        // The chain must actually attempt each mechanism, not pick the one it
        // guesses will work.
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
        // A fallback chain is exactly where a walkable chain earns its keep:
        // the top line says nothing reached the host, and the source says the
        // preferred mechanism was denied by the operating system.
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
        // Otherwise the chain stops at the dummy and reports success, which is
        // the one failure mode a fallback chain must not have.
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
        // Host input turned off is a choice, not a fault.
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
