use std::{
    ffi::{OsStr, OsString},
    fmt,
    num::NonZeroI32,
    path::PathBuf,
};

use lunette_luau::closed_set;

use crate::protocol::{OutputId, ProcessId};

/// A request to start a process and assign its clients to an output.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SpawnRequest {
    /// The main thread allocates this before sending the request, so the API can
    /// return a stable process handle without waiting for the compositor.
    pub process: ProcessId,
    pub argv: Argv,
    /// Entries are added to the child's inherited environment in order; they do
    /// not replace that environment.
    pub env: Vec<(OsString, OsString)>,
    pub cwd: Option<PathBuf>,
    /// The output visible to the child's clients. `None` uses the session's
    /// default output, which is also used for adopted clients.
    ///
    /// An unknown output is ignored and also uses the default output.
    pub output: Option<OutputId>,
    /// Whether the child uses the X11 bridge or connects to Wayland directly.
    pub xwayland: bool,
}

/// A command line split into its program and arguments.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Argv {
    program: OsString,
    arguments: Vec<OsString>,
}

impl Argv {
    pub fn new(program: impl Into<OsString>, arguments: Vec<OsString>) -> Self {
        Self {
            program: program.into(),
            arguments,
        }
    }

    /// Returns `None` for an empty list; otherwise stores its first item as the
    /// program and the remaining items as arguments.
    pub fn from_list(list: Vec<OsString>) -> Option<Self> {
        let mut items = list.into_iter();
        let program = items.next()?;
        Some(Self {
            program,
            arguments: items.collect(),
        })
    }

    #[must_use]
    pub fn program(&self) -> &OsStr {
        &self.program
    }

    #[must_use]
    pub fn arguments(&self) -> &[OsString] {
        &self.arguments
    }
}

/// The terminal result reported for a process.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ProcessOutcome {
    Exited {
        code: i32,
    },
    Signalled {
        signal: SignalNumber,
    },
    /// The program could not be started. The message identifies the failure, and
    /// this outcome is reported through [`crate::protocol::Event::ProcessExited`].
    SpawnFailed {
        message: String,
    },
}

impl ProcessOutcome {
    /// The discriminator sent to Lua as `event.outcome`; each variant exposes a
    /// value through its corresponding accessor.
    #[must_use]
    pub const fn as_str(&self) -> &'static str {
        match self {
            Self::Exited { .. } => "exited",
            Self::Signalled { .. } => "signalled",
            Self::SpawnFailed { .. } => "spawnFailed",
        }
    }

    /// The complete discriminator set exposed to Lua, in declaration order.
    /// Keep this list aligned with the variants and their [`Self::as_str`] values.
    pub const NAMES: &'static [&'static str] = &["exited", "signalled", "spawnFailed"];

    /// Returns the exit status, or `None` for the other outcomes.
    #[must_use]
    pub const fn code(&self) -> Option<i32> {
        match self {
            Self::Exited { code } => Some(*code),
            Self::Signalled { .. } | Self::SpawnFailed { .. } => None,
        }
    }

    /// Returns the terminating signal, or `None` for the other outcomes.
    #[must_use]
    pub const fn signal(&self) -> Option<SignalNumber> {
        match self {
            Self::Signalled { signal } => Some(*signal),
            Self::Exited { .. } | Self::SpawnFailed { .. } => None,
        }
    }

    /// Returns the spawn-failure message, or `None` for the other outcomes.
    #[must_use]
    pub fn message(&self) -> Option<&str> {
        match self {
            Self::SpawnFailed { message } => Some(message),
            Self::Exited { .. } | Self::Signalled { .. } => None,
        }
    }
}

/// A signal the process API can send to a process group.
///
/// This closed set does not represent every signal the operating system can
/// report.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum ProcessSignal {
    Hangup,
    Interrupt,
    Terminate,
    Kill,
}

/// The operating-system number of a signal that terminated a process.
///
/// This domain is separate from [`ProcessSignal`], which is limited to the
/// signals the process API can send.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct SignalNumber(i32);

impl SignalNumber {
    #[must_use]
    pub const fn new(raw: i32) -> Self {
        Self(raw)
    }

    #[must_use]
    pub const fn get(self) -> i32 {
        self.0
    }
}

impl fmt::Display for SignalNumber {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.0)
    }
}

closed_set! {
    /// A captured output stream reported by the process event API.
    #[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
    pub enum Stream {
        Stdout = "stdout",
        Stderr = "stderr",
    }
}

/// A positive operating-system process identifier.
///
/// The process API derives a process-group target from this value when sending a
/// signal, so the identifier itself never carries a negative group value.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct Pid(NonZeroI32);

impl Pid {
    #[must_use]
    pub const fn new(raw: i32) -> Option<Self> {
        match NonZeroI32::new(raw) {
            Some(raw) if raw.get() > 0 => Some(Self(raw)),
            _ => None,
        }
    }

    #[must_use]
    pub const fn get(self) -> i32 {
        self.0.get()
    }
}

impl fmt::Display for Pid {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.0)
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

    /// The exhaustive match makes a new outcome a compile error until its Lua
    /// discriminator and payload accessor are handled in this match.
    #[test]
    fn every_outcome_is_named_and_carries_exactly_its_own_field() {
        let signal = SignalNumber::new(9);
        for outcome in [
            ProcessOutcome::Exited { code: 0 },
            ProcessOutcome::Signalled { signal },
            ProcessOutcome::SpawnFailed {
                message: String::new(),
            },
        ] {
            let (name, filled) = match &outcome {
                ProcessOutcome::Exited { .. } => ("exited", outcome.code().is_some()),
                ProcessOutcome::Signalled { .. } => ("signalled", outcome.signal().is_some()),
                ProcessOutcome::SpawnFailed { .. } => ("spawnFailed", outcome.message().is_some()),
            };
            assert_eq!(outcome.as_str(), name);
            assert!(filled, "{name} does not carry its own field");
            assert!(
                ProcessOutcome::NAMES.contains(&name),
                "{name} is missing from the declared union"
            );
            let others = [
                outcome.code().is_some(),
                outcome.signal().is_some(),
                outcome.message().is_some(),
            ]
            .into_iter()
            .filter(|present| *present)
            .count();
            assert_eq!(others, 1, "{name} carries a field belonging to another");
        }
        assert_eq!(ProcessOutcome::NAMES.len(), 3);
    }

    #[test]
    fn a_pid_rejects_zero_and_negatives() {
        assert_eq!(Pid::new(0), None);
        assert_eq!(Pid::new(-1), None);
        assert_eq!(Pid::new(i32::MIN), None);
        assert_eq!(Pid::new(7).map(Pid::get), Some(7));
    }

    #[test]
    fn an_argv_rejects_an_empty_list() {
        assert_eq!(Argv::from_list(Vec::new()), None);
    }

    #[test]
    fn an_argv_splits_a_list_into_a_program_and_its_arguments() {
        let argv = Argv::from_list(vec![
            OsString::from("foot"),
            OsString::from("-e"),
            OsString::from("htop"),
        ])
        .expect("a non-empty list is accepted");

        assert_eq!(argv.program(), OsStr::new("foot"));
        assert_eq!(
            argv.arguments(),
            [OsString::from("-e"), OsString::from("htop")]
        );
    }

    #[test]
    fn an_argv_of_one_has_no_arguments() {
        let argv = Argv::from_list(vec![OsString::from("foot")]).expect("non-empty");

        assert_eq!(argv.program(), OsStr::new("foot"));
        assert!(argv.arguments().is_empty());
    }
}
