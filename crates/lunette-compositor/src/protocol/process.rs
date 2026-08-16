//! What a spawned process is asked for, and what becomes of it.
//!
//! A spawn is one [`SpawnRequest`] across the channel and one
//! [`crate::protocol::Event::ProcessExited`] back, so what is here is the two
//! ends of that and the identifiers in between: the argument vector, the exit
//! outcome, the signals lunette will send, and the process identifier the
//! operating system answers with.

use std::{
    ffi::{OsStr, OsString},
    fmt,
    num::NonZeroI32,
    path::PathBuf,
};

use lunette_luau::closed_set;

use crate::protocol::{OutputId, ProcessId};

/// What to start, and how to attribute what connects afterwards.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SpawnRequest {
    /// Allocated by the main thread before the request is sent, so
    /// `lunette.spawn` can return a handle without waiting for a reply.
    pub process: ProcessId,
    pub argv: Argv,
    /// Added to the environment the child inherits, not a replacement for it.
    pub env: Vec<(OsString, OsString)>,
    pub cwd: Option<PathBuf>,
    /// The only output this client is shown. Absent means the output every
    /// session starts with, which is what a client lunette did not spawn is
    /// shown too.
    ///
    /// An output that does not exist when the spawn arrives is refused and the
    /// client falls back to the default one: a client shown no monitor at all
    /// cannot pick a scale or a refresh rate.
    pub output: Option<OutputId>,
    /// Whether the child is launched against an X server rather than the
    /// Wayland socket directly.
    pub xwayland: bool,
}

/// A command line, which is a program and its arguments rather than a list that
/// might be empty.
///
/// `execvp` has no meaning for an empty list, so the emptiness is rejected once
/// here rather than being re-checked at every layer that handles a spawn.
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

    /// Splits a caller-supplied list into a program and its arguments,
    /// rejecting an empty list.
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

/// How a process ended.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ProcessOutcome {
    Exited {
        code: i32,
    },
    Signalled {
        signal: SignalNumber,
    },
    /// The child never ran. The message names what failed, and is the only
    /// report a caller gets for a mistyped program name.
    SpawnFailed {
        message: String,
    },
}

impl ProcessOutcome {
    /// The name Lua reads on `event.outcome`, which says which of the other
    /// fields the event carries.
    #[must_use]
    pub const fn as_str(&self) -> &'static str {
        match self {
            Self::Exited { .. } => "exited",
            Self::Signalled { .. } => "signalled",
            Self::SpawnFailed { .. } => "spawnFailed",
        }
    }

    /// Every name, in the order the declared union states them.
    ///
    /// A list rather than a derivation, because the variants carry payloads and
    /// so cannot be enumerated as values; `every_outcome_is_named` is what holds
    /// it to the enum.
    pub const NAMES: &'static [&'static str] = &["exited", "signalled", "spawnFailed"];

    /// The status a process exited with, for the outcome that has one.
    #[must_use]
    pub const fn code(&self) -> Option<i32> {
        match self {
            Self::Exited { code } => Some(*code),
            Self::Signalled { .. } | Self::SpawnFailed { .. } => None,
        }
    }

    /// The signal that killed the process, for the outcome that has one.
    #[must_use]
    pub const fn signal(&self) -> Option<SignalNumber> {
        match self {
            Self::Signalled { signal } => Some(*signal),
            Self::Exited { .. } | Self::SpawnFailed { .. } => None,
        }
    }

    /// What failed, for the outcome that never ran.
    #[must_use]
    pub fn message(&self) -> Option<&str> {
        match self {
            Self::SpawnFailed { message } => Some(message),
            Self::Exited { .. } | Self::Signalled { .. } => None,
        }
    }
}

/// A signal lunette is willing to send to a process group.
///
/// A closed set rather than a number, because sending an arbitrary signal is
/// not a capability the Lua API offers.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum ProcessSignal {
    Hangup,
    Interrupt,
    Terminate,
    Kill,
}

/// The number of a signal that killed a process. Any signal may be observed,
/// so this is not the same domain as [`ProcessSignal`].
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
    /// One of a child's captured output streams.
    #[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
    pub enum Stream {
        Stdout = "stdout",
        Stderr = "stderr",
    }
}

/// A process identifier. Non-zero, and never negative: a process group is
/// addressed by negating this at the point of the signal, not by carrying a
/// negative number around.
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

    /// The names and the variants are two statements of one set, and the match
    /// is exhaustive, so a variant added to [`ProcessOutcome`] fails to compile
    /// here rather than going unnamed in what Lua is told an event carries.
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
