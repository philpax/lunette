#![expect(
    clippy::expect_used,
    reason = "a failed expectation is how a test reports a failure; the ban is on production code"
)]

use std::ffi::{OsStr, OsString};

use pretty_assertions::assert_eq;
use slotmap::DenseSlotMap;

use crate::{
    protocol::{Argv, Pid, ProcessId, ProcessOutcome, ProcessSignal},
    spawn::{
        inspect::{ProcessInspector, find_environment_value},
        plan::{AUTH_VARIABLE, AuthToken, SpawnRequest, TOKEN_BYTES, decode_hex, is_flatpak},
        system::{DisplayEnvironment, SpawnError, SpawnPlan},
        table::{AdoptedIds, Report, add_external_process, poll, snapshot, spawn_process},
    },
    testing::{FakeInspector, FakeSpawner},
    wayvr::process::{Process, ProcessHandle, find_by_pid},
};

type Processes = DenseSlotMap<ProcessHandle, Process>;

/// The identifier Lua sees for the process a connecting PID is attributed to.
fn identify(
    processes: &Processes,
    pid: Pid,
    inspector: &dyn ProcessInspector,
) -> Option<ProcessId> {
    find_by_pid(processes, pid, inspector).map(|handle| processes[handle].id())
}

#[test]
fn spawn_errors_preserve_the_io_kind_for_optional_executables() {
    for kind in [
        std::io::ErrorKind::NotFound,
        std::io::ErrorKind::PermissionDenied,
        std::io::ErrorKind::InvalidInput,
        std::io::ErrorKind::Other,
    ] {
        let error = SpawnError::for_test(
            OsString::from("xwayland-satellite"),
            std::io::Error::new(kind, "spawn refused"),
        );
        assert_eq!(error.kind(), kind);
    }
}

fn display() -> DisplayEnvironment {
    DisplayEnvironment {
        wayland_display: OsString::from("wayland-20"),
        x11_display: OsString::from(":20"),
    }
}

fn argv(parts: &[&str]) -> Argv {
    Argv::from_list(parts.iter().map(OsString::from).collect()).expect("non-empty")
}

fn process(raw: u64) -> ProcessId {
    ProcessId::new(raw).expect("non-zero")
}

fn value<'a>(plan: &'a SpawnPlan, key: &str) -> Option<&'a OsStr> {
    plan.env
        .iter()
        .rev()
        .find(|(name, _)| name == OsStr::new(key))
        .map(|(_, value)| value.as_os_str())
}

fn spawn_into(
    processes: &mut Processes,
    spawner: &mut FakeSpawner,
    id: ProcessId,
    parts: &[&str],
) -> Result<ProcessHandle, SpawnError> {
    let argv = argv(parts);
    let display = display();
    spawn_process(
        processes,
        spawner,
        SpawnRequest {
            process: id,
            argv: &argv,
            env: &[],
            cwd: None,
            display: &display,
        },
    )
}

#[test]
fn a_spawn_carries_the_display_and_the_toolkit_hints() {
    let mut processes = Processes::with_key();
    let mut spawner = FakeSpawner::default();

    spawn_into(&mut processes, &mut spawner, process(1), &["foot"])
        .expect("the fake spawner starts anything");

    let requested = spawner.log.requested();
    let plan = &requested[0];
    assert_eq!(
        value(plan, "WAYLAND_DISPLAY"),
        Some(OsStr::new("wayland-20"))
    );
    assert_eq!(value(plan, "DISPLAY"), Some(OsStr::new(":20")));
    assert_eq!(value(plan, "GDK_BACKEND"), Some(OsStr::new("wayland,x11")));
    assert_eq!(
        value(plan, "ELECTRON_OZONE_PLATFORM_HINT"),
        Some(OsStr::new("wayland"))
    );
    assert!(
        value(plan, AUTH_VARIABLE).is_some_and(|token| token.len() == TOKEN_BYTES * 2),
        "the token is present and the full width"
    );
}

#[test]
fn two_spawns_get_different_tokens() {
    let mut processes = Processes::with_key();
    let mut spawner = FakeSpawner::default();

    spawn_into(&mut processes, &mut spawner, process(1), &["foot"]).expect("started");
    spawn_into(&mut processes, &mut spawner, process(2), &["foot"]).expect("started");

    let requested = spawner.log.requested();
    let first = value(&requested[0], AUTH_VARIABLE).expect("a token");
    let second = value(&requested[1], AUTH_VARIABLE).expect("a token");
    assert_ne!(first, second);
}

#[test]
fn a_flatpak_launch_passes_its_environment_after_run() {
    let mut processes = Processes::with_key();
    let mut spawner = FakeSpawner::default();

    spawn_into(
        &mut processes,
        &mut spawner,
        process(1),
        &["/usr/bin/flatpak", "run", "org.example.App", "--window"],
    )
    .expect("started");

    let requested = spawner.log.requested();
    let arguments: Vec<String> = requested[0]
        .argv
        .arguments()
        .iter()
        .map(|argument| argument.to_string_lossy().into_owned())
        .collect();

    assert_eq!(arguments[0], "run", "--env must follow run, not precede it");
    assert!(
        arguments
            .iter()
            .any(|argument| argument.starts_with("--env=GDK_BACKEND=")),
        "the hints travel as arguments: {arguments:?}"
    );
    assert_eq!(
        arguments.last().map(String::as_str),
        Some("--window"),
        "the application's own arguments stay after the environment"
    );
    assert!(
        arguments
            .iter()
            .position(|argument| argument == "org.example.App")
            .is_some_and(|index| index > 1),
        "the application id stays after run: {arguments:?}"
    );
}

#[test]
fn a_program_merely_named_flatpak_run_is_not_a_flatpak_launch() {
    assert!(!is_flatpak(&argv(&["flatpak"])));
    assert!(!is_flatpak(&argv(&["flatpak", "list"])));
    assert!(!is_flatpak(&argv(&["flatpakker", "run"])));
    assert!(is_flatpak(&argv(&["flatpak", "run", "org.example.App"])));
    assert!(is_flatpak(&argv(&["/usr/bin/flatpak", "run"])));
}

#[test]
fn a_caller_supplied_variable_overrides_a_toolkit_hint() {
    let mut processes = Processes::with_key();
    let mut spawner = FakeSpawner::default();
    let argv = argv(&["foot"]);
    let display = display();

    spawn_process(
        &mut processes,
        &mut spawner,
        SpawnRequest {
            process: process(1),
            argv: &argv,
            env: &[(OsString::from("GDK_BACKEND"), OsString::from("x11"))],
            cwd: None,
            display: &display,
        },
    )
    .expect("started");

    assert_eq!(
        value(&spawner.log.requested()[0], "GDK_BACKEND"),
        Some(OsStr::new("x11")),
        "lunette's hint is a default, not a policy"
    );
}

#[test]
fn a_spawn_that_fails_registers_nothing() {
    let mut processes = Processes::with_key();
    let mut spawner = FakeSpawner::default();
    spawner.log.refuse("no such file or directory");

    let error = spawn_into(&mut processes, &mut spawner, process(1), &["not-a-program"])
        .expect_err("a refused spawn is an error");

    assert!(error.message().contains("not-a-program"));
    assert!(
        processes.is_empty(),
        "a process that never ran is not tracked"
    );
    assert!(snapshot(&processes).is_empty());
}

#[test]
fn a_client_is_matched_by_its_connecting_pid_first() {
    let mut processes = Processes::with_key();
    let mut spawner = FakeSpawner::default();
    spawn_into(&mut processes, &mut spawner, process(7), &["foot"]).expect("started");

    let pid = spawner
        .log
        .pid(0)
        .expect("the fake spawner gave the child a pid");
    assert_eq!(
        identify(&processes, pid, &FakeInspector::default()),
        Some(process(7)),
        "the pid match must not need the environment at all"
    );
}

#[test]
fn a_client_behind_a_wrapper_is_matched_by_its_token() {
    let mut processes = Processes::with_key();
    let mut spawner = FakeSpawner::default();
    spawn_into(&mut processes, &mut spawner, process(7), &["sh"]).expect("started");

    let requested = spawner.log.requested();
    let token = value(&requested[0], AUTH_VARIABLE).expect("a token");
    let environment = FakeInspector::default();
    let mut block = Vec::new();
    block.extend_from_slice(b"HOME=/home/somebody\0");
    block.extend_from_slice(AUTH_VARIABLE.as_bytes());
    block.push(b'=');
    block.extend_from_slice(token.as_encoded_bytes());
    block.push(0);
    environment.set_environment(4242, block);

    let grandchild = Pid::new(4242).expect("positive");
    assert_eq!(
        identify(&processes, grandchild, &environment),
        Some(process(7))
    );
}

#[test]
fn a_client_presenting_a_wrong_token_is_not_matched() {
    let mut processes = Processes::with_key();
    let mut spawner = FakeSpawner::default();
    spawn_into(&mut processes, &mut spawner, process(7), &["sh"]).expect("started");

    let environment = FakeInspector::default();
    for presented in [
        b"".to_vec(),
        b"not-hexadecimal".to_vec(),
        b"00".to_vec(),
        vec![b'a'; TOKEN_BYTES * 2],
    ] {
        environment.set_variable(4242, AUTH_VARIABLE, &presented);

        assert_eq!(
            identify(&processes, Pid::new(4242).expect("positive"), &environment),
            None,
            "a token of {presented:?} must not match"
        );
    }
}

#[test]
fn a_client_with_no_token_and_no_matching_pid_is_unknown() {
    let processes = Processes::with_key();
    let environment = FakeInspector::default();
    environment.set_environment(4242, b"HOME=/home/somebody\0".to_vec());

    assert_eq!(
        identify(&processes, Pid::new(4242).expect("positive"), &environment),
        None,
        "an unmatched client is external, which the caller decides, not this"
    );
}

#[test]
fn an_adopted_process_is_reported_external_and_alive() {
    let mut processes = Processes::with_key();
    let id = add_external_process(
        &mut processes,
        &mut AdoptedIds::default(),
        Pid::new(4242).expect("positive"),
    );

    let snapshot = snapshot(&processes);
    assert_eq!(snapshot.len(), 1);
    assert_eq!(snapshot[0].process, id);
    assert_eq!(snapshot[0].pid, Pid::new(4242));
    assert!(snapshot[0].external);
    assert!(snapshot[0].alive);
}

#[test]
fn an_adopted_process_that_disappears_is_reported_once() {
    let mut processes = Processes::with_key();
    let id = add_external_process(
        &mut processes,
        &mut AdoptedIds::default(),
        Pid::new(4242).expect("positive"),
    );

    assert!(poll(&mut processes, &FakeInspector::default()).is_empty());

    let gone = FakeInspector::default();
    gone.kill(4242);
    let reports = poll(&mut processes, &gone);
    assert_eq!(reports.len(), 1);
    assert!(matches!(reports[0], Report::Vanished { id: reported } if reported == id));

    assert!(
        poll(&mut processes, &gone).is_empty(),
        "a disappearance is reported once, not on every poll"
    );
    assert!(processes.is_empty());
}

#[test]
fn a_child_that_has_exited_is_never_signalled_again() {
    let mut processes = Processes::with_key();
    let mut spawner = FakeSpawner::default();
    spawn_into(&mut processes, &mut spawner, process(1), &["foot"]).expect("started");

    spawner.log.finish(0, ProcessOutcome::Exited { code: 0 });
    let reports = poll(&mut processes, &FakeInspector::default());
    assert_eq!(reports.len(), 1, "the exit is reported: {reports:?}");

    // Reaping frees the child's process-group identifier for reuse. Signalling it afterward
    // could target an unrelated process group.
    assert_eq!(
        spawner.log.signals(0),
        Vec::new(),
        "a reaped child's process group must not be signalled"
    );

    if let Some(entry) = processes
        .values_mut()
        .find(|entry| entry.id() == process(1))
    {
        entry.kill(ProcessSignal::Terminate);
    }
    assert_eq!(
        spawner.log.signals(0),
        Vec::new(),
        "nor after the entry is gone"
    );
}

#[test]
fn a_child_that_is_still_running_is_asked_to_stop_when_the_registry_goes() {
    let mut spawner = FakeSpawner::default();
    let mut processes = Processes::with_key();
    spawn_into(&mut processes, &mut spawner, process(1), &["foot"]).expect("started");

    drop(processes);

    assert_eq!(
        spawner.log.signals(0),
        vec![ProcessSignal::Terminate],
        "a live child's group is asked to stop as lunette shuts down"
    );
}

#[test]
fn an_environment_block_is_read_as_bytes() {
    let mut block = Vec::new();
    block.extend_from_slice(b"PATH=/usr/bin\0");
    block.extend_from_slice(b"ODD=");
    block.extend_from_slice(&[0xFF, 0xFE, 0x80]);
    block.push(0);
    block.extend_from_slice(b"LAST=1\0");

    assert_eq!(
        find_environment_value(&block, b"ODD"),
        Some(vec![0xFF, 0xFE, 0x80]),
        "a non-UTF-8 value must survive, because it is legal"
    );
    assert_eq!(find_environment_value(&block, b"LAST"), Some(b"1".to_vec()));
    assert_eq!(find_environment_value(&block, b"ABSENT"), None);
}

#[test]
fn an_environment_entry_with_no_separator_is_skipped() {
    let block = b"BROKEN\0GOOD=yes\0".to_vec();
    assert_eq!(
        find_environment_value(&block, b"GOOD"),
        Some(b"yes".to_vec())
    );
    assert_eq!(find_environment_value(&block, b"BROKEN"), None);
}

#[test]
fn an_environment_value_containing_an_equals_keeps_all_of_it() {
    let block = b"KEY=a=b=c\0".to_vec();
    assert_eq!(
        find_environment_value(&block, b"KEY"),
        Some(b"a=b=c".to_vec())
    );
}

#[test]
fn an_empty_environment_block_yields_nothing() {
    assert_eq!(find_environment_value(b"", b"ANY"), None);
    assert_eq!(find_environment_value(b"\0\0\0", b"ANY"), None);
}

#[test]
fn a_token_round_trips_through_its_encoded_form() {
    let token = AuthToken::generate(OsStr::new("foot")).expect("the random source answers");
    let encoded = token.encoded();

    assert_eq!(encoded.len(), TOKEN_BYTES * 2);
    assert!(token.matches(&AuthToken::from_bytes(encoded.as_bytes())));
}

#[test]
fn a_token_does_not_match_a_prefix_of_itself() {
    let token = AuthToken::generate(OsStr::new("foot")).expect("the random source answers");
    let encoded = token.encoded();

    assert!(!token.matches(&AuthToken::from_bytes(
        &encoded.as_bytes()[..encoded.len() - 2]
    )));
    assert!(!token.matches(&[]));
}

#[test]
fn hexadecimal_decoding_rejects_what_is_not_hexadecimal() {
    assert_eq!(decode_hex(b"00ff"), Some(vec![0x00, 0xFF]));
    assert_eq!(decode_hex(b""), Some(Vec::new()));
    assert_eq!(decode_hex(b"0"), None, "an odd length is not a byte string");
    assert_eq!(decode_hex(b"zz"), None);
    assert_eq!(decode_hex(b"0x"), None);
    assert_eq!(
        decode_hex("00ÿ".as_bytes()),
        None,
        "a multi-byte character is not two hexadecimal digits"
    );
}

#[test]
fn a_token_is_not_written_into_a_log_line() {
    let token = AuthToken::generate(OsStr::new("foot")).expect("the random source answers");
    let rendered = format!("{token:?}");

    assert!(!rendered.contains(&token.encoded()));
    assert_eq!(rendered, "AuthToken(<redacted>)");
}
