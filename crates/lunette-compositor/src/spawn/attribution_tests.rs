//! Deterministic process identity, attribution, and ownership regressions.

use std::{ffi::OsString, io};

use slotmap::DenseSlotMap;

use crate::{
    protocol::{
        Argv, Pid, ProcessId, ProcessInstance, ProcessObservation, ProcessObservationFailure,
        ProcessOutcome,
    },
    spawn::{
        AUTH_VARIABLE, AdoptedIds, DisplayEnvironment, Report, SpawnRequest, add_external_process,
        poll, snapshot, spawn_process,
    },
    testing::{FakeInspector, FakeSpawner, InspectorStep},
    wayvr::process::{Process, ProcessHandle, find_by_instance, find_by_pid},
};

type Processes = DenseSlotMap<ProcessHandle, Process>;

fn pid(raw: i32) -> Pid {
    Pid::new(raw).expect("positive fixture PID")
}

fn live(pid: Pid, start: u64) -> ProcessObservation {
    ProcessObservation::Live {
        instance: ProcessInstance::new(pid, start),
        parent: Some(self::pid(20)),
    }
}

fn denied() -> ProcessObservation {
    ProcessObservation::Unavailable(ProcessObservationFailure::AccessDenied)
}

fn managed(inspector: &FakeInspector) -> (Processes, FakeSpawner, ProcessId, Pid, Vec<u8>) {
    let mut processes = Processes::with_key();
    let mut spawner = FakeSpawner::default();
    let id = ProcessId::new(7).expect("nonzero fixture id");
    let argv = Argv::new("wrapper", Vec::new());
    let display = DisplayEnvironment {
        wayland_display: OsString::from("wayland-fixture"),
        x11_display: OsString::from(":20"),
    };
    spawn_process(
        &mut processes,
        &mut spawner,
        inspector,
        SpawnRequest {
            process: id,
            argv: &argv,
            env: &[],
            cwd: None,
            display: &display,
        },
    )
    .expect("fake spawn succeeds");
    let root = spawner.log.pid(0).expect("spawned pid");
    let plans = spawner.log.requested();
    let token = plans[0]
        .env
        .iter()
        .find(|(key, _)| key == AUTH_VARIABLE)
        .expect("spawn token")
        .1
        .as_encoded_bytes()
        .to_vec();
    (processes, spawner, id, root, token)
}

#[test]
fn process_instance_reuse_rejected() {
    let inspector = FakeInspector::default();
    let (mut processes, spawner, id, root, token) = managed(&inspector);
    let original = ProcessInstance::new(root, 1);
    assert_eq!(
        find_by_instance(&processes, original, &inspector).map(|h| processes[h].id()),
        Some(id)
    );

    inspector.set_observation(root.get(), live(root, 2));
    inspector.set_variable(root.get(), AUTH_VARIABLE, &token);
    assert_eq!(find_by_instance(&processes, original, &inspector), None);
    assert_eq!(
        find_by_instance(&processes, ProcessInstance::new(root, 2), &inspector),
        None
    );
    assert_eq!(find_by_pid(&processes, root, &inspector), None);
    poll(&mut processes, &inspector);
    assert_eq!(
        snapshot(&processes)[0].observation,
        ProcessObservation::Ended
    );
    assert!(
        snapshot(&processes)[0].alive,
        "the owned child remains until reaping"
    );
    assert!(spawner.log.signals(0).is_empty());

    let mut adopted = Processes::with_key();
    let external = pid(4242);
    inspector.set_observation(external.get(), live(external, 10));
    add_external_process(
        &mut adopted,
        &mut AdoptedIds::default(),
        external,
        &inspector,
    );
    inspector.set_observation(external.get(), live(external, 11));
    assert_eq!(find_by_pid(&adopted, external, &inspector), None);
    let reports = poll(&mut adopted, &inspector);
    assert!(reports.iter().any(|r| matches!(r, Report::Vanished { .. })));
    assert!(adopted.is_empty());
}

#[test]
fn a_new_adoption_matches_even_with_a_stale_pid_record() {
    let inspector = FakeInspector::default();
    let mut processes = Processes::with_key();
    let external = pid(4242);
    let mut ids = AdoptedIds::default();
    inspector.set_observation(external.get(), live(external, 10));
    let old = add_external_process(&mut processes, &mut ids, external, &inspector);
    inspector.set_observation(external.get(), live(external, 11));
    let new = add_external_process(&mut processes, &mut ids, external, &inspector);
    assert_ne!(old, new);
    assert_eq!(
        find_by_pid(&processes, external, &inspector).map(|h| processes[h].id()),
        Some(new)
    );
    poll(&mut processes, &inspector);
    assert_eq!(snapshot(&processes).len(), 1);
    assert_eq!(snapshot(&processes)[0].process, new);
}

#[test]
fn denied_managed_registration_retains_the_child_without_later_attribution() {
    let inspector = FakeInspector::default();
    // The fake's first stat read is registration, so no real PID is consulted.
    let mut spawner = FakeSpawner::default();
    let plans = DisplayEnvironment {
        wayland_display: OsString::from("wayland-fixture"),
        x11_display: OsString::from(":20"),
    };
    let mut processes = Processes::with_key();
    let argv = Argv::new("wrapper", Vec::new());
    let id = ProcessId::new(7).expect("nonzero fixture id");
    let root = pid(10_001);
    inspector.set_observation(root.get(), denied());
    spawn_process(
        &mut processes,
        &mut spawner,
        &inspector,
        SpawnRequest {
            process: id,
            argv: &argv,
            env: &[],
            cwd: None,
            display: &plans,
        },
    )
    .expect("fake spawn succeeds");
    assert_eq!(spawner.log.pid(0), Some(root));
    assert_eq!(snapshot(&processes)[0].instance, None);
    inspector.set_observation(root.get(), live(root, 50));
    poll(&mut processes, &inspector);
    assert!(snapshot(&processes)[0].alive);
    assert_eq!(snapshot(&processes)[0].instance, None);
    assert_eq!(find_by_pid(&processes, root, &inspector), None);
    drop(processes);
    assert_eq!(
        spawner.log.signals(0),
        [crate::protocol::ProcessSignal::Terminate]
    );
}

#[test]
fn descendant_audio_attribution() {
    let inspector = FakeInspector::default();
    let (processes, _spawner, id, root, token) = managed(&inspector);
    let descendant = pid(4242);
    let observation = ProcessObservation::Live {
        instance: ProcessInstance::new(descendant, 77),
        parent: Some(root),
    };
    inspector.script([
        InspectorStep::Stat(descendant, observation),
        InspectorStep::Environment(descendant, Ok(Some(token))),
        InspectorStep::Stat(descendant, observation),
        InspectorStep::Stat(root, live(root, 1)),
    ]);
    assert_eq!(
        find_by_instance(
            &processes,
            observation.instance().expect("live"),
            &inspector
        )
        .map(|h| processes[h].id()),
        Some(id)
    );
    inspector.assert_script_finished();
}

#[test]
fn descendant_audio_attribution_rejects_stat_environment_stat_mutations() {
    let inspector = FakeInspector::default();
    let (processes, _spawner, _id, _root, token) = managed(&inspector);
    let descendant = pid(4242);
    let candidate = ProcessInstance::new(descendant, 77);
    for changed in [live(descendant, 78), denied(), ProcessObservation::Ended] {
        inspector.script([
            InspectorStep::Stat(descendant, live(descendant, 77)),
            InspectorStep::Environment(descendant, Ok(Some(token.clone()))),
            InspectorStep::Stat(descendant, changed),
        ]);
        assert_eq!(find_by_instance(&processes, candidate, &inspector), None);
        inspector.assert_script_finished();
    }
}

#[test]
fn descendant_audio_attribution_rejects_dead_reused_and_inaccessible_roots() {
    let inspector = FakeInspector::default();
    let (mut processes, spawner, _id, root, token) = managed(&inspector);
    let descendant = pid(4242);
    let candidate = ProcessInstance::new(descendant, 77);
    for root_observation in [live(root, 2), denied(), ProcessObservation::Ended] {
        inspector.script([
            InspectorStep::Stat(descendant, live(descendant, 77)),
            InspectorStep::Environment(descendant, Ok(Some(token.clone()))),
            InspectorStep::Stat(descendant, live(descendant, 77)),
            InspectorStep::Stat(root, root_observation),
        ]);
        assert_eq!(find_by_instance(&processes, candidate, &inspector), None);
        inspector.assert_script_finished();
    }
    spawner.log.finish(0, ProcessOutcome::Exited { code: 0 });
    poll(&mut processes, &inspector);
    inspector.script([
        InspectorStep::Stat(descendant, live(descendant, 77)),
        InspectorStep::Environment(descendant, Ok(Some(token))),
        InspectorStep::Stat(descendant, live(descendant, 77)),
    ]);
    assert_eq!(find_by_instance(&processes, candidate, &inspector), None);
    inspector.assert_script_finished();
}

#[test]
fn descendant_audio_attribution_rejects_unavailable_environment_and_candidate() {
    let inspector = FakeInspector::default();
    let (processes, _spawner, _id, _root, _token) = managed(&inspector);
    let descendant = pid(4242);
    let candidate = ProcessInstance::new(descendant, 77);
    for unavailable in [denied(), ProcessObservation::Ended, live(descendant, 78)] {
        inspector.script([InspectorStep::Stat(descendant, unavailable)]);
        assert_eq!(find_by_instance(&processes, candidate, &inspector), None);
        inspector.assert_script_finished();
    }
    for environment in [
        Err(io::ErrorKind::PermissionDenied),
        Err(io::ErrorKind::NotFound),
        Ok(None),
        Ok(Some(b"wrong".to_vec())),
    ] {
        let has_value = matches!(&environment, Ok(Some(_)));
        let mut script = vec![
            InspectorStep::Stat(descendant, live(descendant, 77)),
            InspectorStep::Environment(descendant, environment),
        ];
        if has_value {
            script.push(InspectorStep::Stat(descendant, live(descendant, 77)));
        }
        inspector.script(script);
        assert_eq!(find_by_instance(&processes, candidate, &inspector), None);
        inspector.assert_script_finished();
    }
}

#[test]
fn denied_observation_preserves_ownership_reaping_and_adopted_liveness() {
    let inspector = FakeInspector::default();
    let (mut processes, spawner, id, root, _token) = managed(&inspector);
    inspector.set_observation(root.get(), denied());
    let reports = poll(&mut processes, &inspector);
    assert!(
        matches!(reports.as_slice(), [Report::ObservationChanged { id: reported, observation }] if *reported == id && *observation == denied())
    );
    assert!(snapshot(&processes)[0].alive);
    assert_eq!(
        snapshot(&processes)[0].instance,
        Some(ProcessInstance::new(root, 1))
    );
    assert_eq!(
        find_by_instance(&processes, ProcessInstance::new(root, 1), &inspector),
        None
    );
    assert!(
        poll(&mut processes, &inspector).is_empty(),
        "no duplicate observation events"
    );
    spawner.log.finish(0, ProcessOutcome::Exited { code: 4 });
    assert!(
        matches!(poll(&mut processes, &inspector).as_slice(), [Report::Exited { id: reported, .. }] if *reported == id)
    );
    assert!(processes.is_empty());
    assert!(spawner.log.signals(0).is_empty());

    let external = pid(4242);
    add_external_process(
        &mut processes,
        &mut AdoptedIds::default(),
        external,
        &inspector,
    );
    inspector.set_observation(external.get(), denied());
    poll(&mut processes, &inspector);
    assert!(snapshot(&processes)[0].alive);
    inspector.set_observation(external.get(), live(external, 1));
    poll(&mut processes, &inspector);
    assert_eq!(
        snapshot(&processes)[0].observation.instance(),
        Some(ProcessInstance::new(external, 1))
    );
    inspector.kill(external.get());
    poll(&mut processes, &inspector);
    assert!(processes.is_empty());
}

#[test]
fn denied_registration_is_never_bound_to_a_later_pid_observation() {
    let inspector = FakeInspector::default();
    let external = pid(4242);
    inspector.set_observation(external.get(), denied());
    let mut processes = Processes::with_key();
    add_external_process(
        &mut processes,
        &mut AdoptedIds::default(),
        external,
        &inspector,
    );
    assert_eq!(snapshot(&processes)[0].instance, None);
    inspector.set_observation(external.get(), live(external, 50));
    poll(&mut processes, &inspector);
    assert_eq!(snapshot(&processes)[0].instance, None);
    assert_eq!(snapshot(&processes)[0].observation, denied());
    assert_eq!(find_by_pid(&processes, external, &inspector), None);
    inspector.kill(external.get());
    poll(&mut processes, &inspector);
    assert!(processes.is_empty());
}
