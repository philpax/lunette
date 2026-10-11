//! Linux-only: reads `/proc/<pid>/stat` and `/proc/<pid>/environ`.
//!
//! The process-observation seam behind attribution and adopted-process liveness.

use std::{fs, io};

use crate::{
    protocol::{Pid, ProcessInstance, ProcessObservation, ProcessObservationFailure},
    wayvr::process::get_process_env_value,
};

/// Provides process observations without owning or waiting for processes.
/// Environments remain raw bytes because they need not be UTF-8.
pub trait ProcessInspector: Send {
    /// Returns `None` when `key` is absent and preserves the value's bytes.
    ///
    /// # Errors
    ///
    /// Returns an I/O error when the environment cannot be read. `NotFound`
    /// means the process disappeared; `PermissionDenied` means access is denied.
    fn read_environment(&self, pid: Pid, key: &str) -> io::Result<Option<Vec<u8>>>;

    /// Observes identity, parent PID, and liveness together. Missing and terminal
    /// records are `Ended`; denied reads are `Unavailable`, never process death.
    fn observe(&self, pid: Pid) -> ProcessObservation;
}

/// Uses the host's Linux `/proc` filesystem for process inspection.
#[derive(Clone, Copy, Debug, Default)]
pub struct ProcFilesystem;

impl ProcessInspector for ProcFilesystem {
    fn read_environment(&self, pid: Pid, key: &str) -> io::Result<Option<Vec<u8>>> {
        get_process_env_value(pid, key)
    }

    fn observe(&self, pid: Pid) -> ProcessObservation {
        match fs::read(format!("/proc/{pid}/stat")) {
            Ok(stat) => parse_process_stat(pid, &stat).unwrap_or(ProcessObservation::Unavailable(
                ProcessObservationFailure::InvalidData,
            )),
            Err(error) => observation_error(&error),
        }
    }
}

/// Captures identity once. A later observation cannot bind an unobserved
/// registration to a possibly reused PID, or revive an ended instance.
#[derive(Clone, Copy, Debug)]
pub(crate) struct ProcessRecord {
    pub(crate) instance: Option<ProcessInstance>,
    pub(crate) observation: ProcessObservation,
}

impl ProcessRecord {
    pub(crate) fn capture(pid: Pid, inspector: &dyn ProcessInspector) -> Self {
        let observation = inspector.observe(pid);
        Self {
            instance: observation.instance(),
            observation,
        }
    }

    pub(crate) fn refresh(&mut self, pid: Pid, inspector: &dyn ProcessInspector) -> bool {
        if self.observation == ProcessObservation::Ended {
            return false;
        }
        let observed = inspector.observe(pid);
        let next = match observed {
            ProcessObservation::Live { instance, .. } => match self.instance {
                Some(captured) if captured == instance => observed,
                Some(_) => ProcessObservation::Ended,
                None => self.observation,
            },
            ProcessObservation::Ended | ProcessObservation::Unavailable(_) => observed,
        };
        let changed = self.observation != next;
        self.observation = next;
        changed
    }
}

fn observation_error(error: &io::Error) -> ProcessObservation {
    match error.kind() {
        io::ErrorKind::NotFound => ProcessObservation::Ended,
        io::ErrorKind::PermissionDenied => {
            ProcessObservation::Unavailable(ProcessObservationFailure::AccessDenied)
        }
        _ if error.raw_os_error() == Some(libc::ESRCH) => ProcessObservation::Ended,
        _ => ProcessObservation::Unavailable(ProcessObservationFailure::Other),
    }
}

/// Parses fields 1, 3, 4, and 22 without treating spaces or parentheses in the
/// command name as separators. The command name is not required to be UTF-8.
fn parse_process_stat(pid: Pid, stat: &[u8]) -> Option<ProcessObservation> {
    let open = stat.iter().position(|byte| *byte == b'(')?;
    let close = stat.iter().rposition(|byte| *byte == b')')?;
    if close <= open || stat.get(open.wrapping_sub(1)) != Some(&b' ') {
        return None;
    }
    let recorded_pid = std::str::from_utf8(&stat[..open])
        .ok()?
        .trim()
        .parse::<i32>()
        .ok()?;
    if Pid::new(recorded_pid) != Some(pid) || stat.get(close + 1) != Some(&b' ') {
        return None;
    }
    let mut fields = stat[close + 2..]
        .split(|byte| byte.is_ascii_whitespace())
        .filter(|field| !field.is_empty());
    let state = fields.next()?;
    if state.len() != 1 || !b"RSDZTWtXxKPI".contains(&state[0]) {
        return None;
    }
    let parent = std::str::from_utf8(fields.next()?)
        .ok()?
        .parse::<i32>()
        .ok()?;
    let parent = match parent {
        0 => None,
        value => Some(Pid::new(value)?),
    };
    let start_time = std::str::from_utf8(fields.nth(17)?)
        .ok()?
        .parse::<u64>()
        .ok()?;
    if b"ZXx".contains(&state[0]) {
        Some(ProcessObservation::Ended)
    } else {
        Some(ProcessObservation::Live {
            instance: ProcessInstance::new(pid, start_time),
            parent,
        })
    }
}

/// Finds a variable in a NUL-separated environment block, as
/// `/proc/<pid>/environ` presents it. It skips entries without `=`, and keeps
/// non-UTF-8 values and everything after the first `=` in the matching entry.
pub(crate) fn find_environment_value(env_data: &[u8], key: &[u8]) -> Option<Vec<u8>> {
    env_data
        .split(|byte| *byte == 0)
        .filter(|line| !line.is_empty())
        .find_map(|line| {
            let separator = line.iter().position(|byte| *byte == b'=')?;
            (&line[..separator] == key).then(|| line[separator + 1..].to_vec())
        })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pid() -> Pid {
        Pid::new(123).expect("positive fixture PID")
    }

    #[test]
    fn stat_parser_handles_spaces_parentheses_and_non_utf8_names() {
        for name in [
            b"plain".as_slice(),
            b"space name",
            b"((nested) name) (",
            b"raw\xff)",
        ] {
            let mut stat = b"123 (".to_vec();
            stat.extend_from_slice(name);
            // Fields 5..21 use distinct values so an off-by-one start time fails.
            stat.extend_from_slice(
                b") S 42 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 987654 23\n",
            );
            assert_eq!(
                parse_process_stat(pid(), &stat),
                Some(ProcessObservation::Live {
                    instance: ProcessInstance::new(pid(), 987654),
                    parent: Pid::new(42),
                })
            );
        }
    }

    #[test]
    fn stat_parser_rejects_incomplete_invalid_and_wrong_pid_records() {
        for stat in [
            b"".as_slice(),
            b"123 no command S 42",
            b"123 (name) S 42",
            b"123 (name) ? 42 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22",
            b"124 (name) S 42 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22",
            b"123 (name) S -1 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22",
            b"123 (name) S 42 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 nope",
            b"123 (name) S 42 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 -1",
        ] {
            assert_eq!(parse_process_stat(pid(), stat), None, "{stat:?}");
        }
    }

    #[test]
    fn stat_parser_observes_parent_zero_and_terminal_states() {
        assert_eq!(
            parse_process_stat(
                pid(),
                b"123 (init) S 0 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22"
            ),
            Some(ProcessObservation::Live {
                instance: ProcessInstance::new(pid(), 22),
                parent: None,
            })
        );
        for state in *b"ZXx" {
            let mut stat =
                b"123 (name) S 0 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22".to_vec();
            stat[11] = state;
            assert_eq!(
                parse_process_stat(pid(), &stat),
                Some(ProcessObservation::Ended)
            );
        }
    }

    #[test]
    fn observation_errors_distinguish_missing_from_denied() {
        assert_eq!(
            observation_error(&io::ErrorKind::NotFound.into()),
            ProcessObservation::Ended
        );
        assert_eq!(
            observation_error(&io::Error::from_raw_os_error(libc::ESRCH)),
            ProcessObservation::Ended
        );
        assert_eq!(
            observation_error(&io::ErrorKind::PermissionDenied.into()),
            ProcessObservation::Unavailable(ProcessObservationFailure::AccessDenied)
        );
        assert_eq!(
            observation_error(&io::ErrorKind::Other.into()),
            ProcessObservation::Unavailable(ProcessObservationFailure::Other)
        );
    }
}
