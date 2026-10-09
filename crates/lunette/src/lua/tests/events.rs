//! Tests event payloads, ordering, and handler failure behavior.

use std::ffi::OsStr;

use lunette_compositor::protocol::{
    Command, Event as CompositorEvent, PixelSize, ProcessId, ProcessOutcome, SignalNumber, Stream,
};
use mlua::{Table, Value};
use pretty_assertions::assert_eq;

use crate::{
    events::LuaEvent,
    lua::tests::{
        layered_session,
        layers::{ONE_SLOT, settle},
        lua, poll, recording_session, run, session, snapshot, window, window_id,
    },
};

#[test]
fn a_window_opening_hands_the_handler_a_handle_and_a_snapshot_that_holds_it() {
    let (session, sink) =
        recording_session(vec![window(1, "htop", "foot", PixelSize::new(1280, 720))]);
    let lua = lua(&session);
    run::<()>(
        &lua,
        "lunette.onWindowOpened(function(event)
             opened = { id = event.window.id, title = event.window.title, dead = event.window.dead }
             visible = #lunette.windows()
         end)",
    );

    session.push_event(LuaEvent::WindowOpened {
        window: window_id(1),
    });
    poll(&lua, &sink);

    let (id, title, dead, visible): (u64, String, bool, usize) =
        run(&lua, "return opened.id, opened.title, opened.dead, visible");
    assert_eq!((id, title.as_str(), dead), (1, "htop", false));
    assert_eq!(
        visible, 1,
        "the event and the snapshot the handler reads have to describe the same frame"
    );
}

#[test]
fn a_title_change_carries_both_the_window_and_the_new_title() {
    let (session, sink) =
        recording_session(vec![window(1, "htop", "foot", PixelSize::new(1280, 720))]);
    let lua = lua(&session);
    run::<()>(
        &lua,
        "lunette.onTitleChanged(function(event) changed = event end)",
    );

    session.push_event(LuaEvent::TitleChanged {
        window: window_id(1),
        title: "htop — 4 cores".to_owned(),
    });
    poll(&lua, &sink);

    let (title, id): (String, u64) = run(&lua, "return changed.title, changed.window.id");
    assert_eq!(title, "htop — 4 cores");
    assert_eq!(id, 1);
}

#[test]
fn a_client_disconnecting_hands_the_handler_a_dead_handle_that_still_knows_what_it_was() {
    let (session, sink) =
        recording_session(vec![window(1, "htop", "foot", PixelSize::new(1280, 720))]);
    let lua = lua(&session);
    run::<()>(
        &lua,
        "lunette.onWindowClosed(function(event)
             closed = {
                 id = event.window.id,
                 dead = event.window.dead,
                 title = event.window.title,
                 width = event.window.width,
                 texture = event.window:getTexture(),
             }
             remaining = #lunette.windows()
         end)",
    );

    // The event and snapshot are installed in the same frame; the handle is already dead.
    session.begin(snapshot(Vec::new(), Vec::new()));
    session.push_event(LuaEvent::WindowClosed {
        window: window_id(1),
    });
    poll(&lua, &sink);

    let (id, dead, title, width, texture, remaining): (u64, bool, String, u32, bool, usize) = run(
        &lua,
        "return closed.id, closed.dead, closed.title, closed.width, closed.texture, remaining",
    );

    assert_eq!(id, 1);
    assert!(dead);
    assert_eq!(
        (title.as_str(), width),
        ("htop", 1280),
        "the handle reads the last thing the window was known to be, not nothing"
    );
    assert!(!texture, "every method of a dead handle answers false");
    assert_eq!(remaining, 0);
}

#[test]
fn a_spawn_that_never_started_is_reported_as_an_exit_and_opens_no_window() {
    let (session, sink) = recording_session(Vec::new());
    let lua = lua(&session);
    run::<()>(
        &lua,
        "opened = 0
         lunette.onWindowOpened(function() opened = opened + 1 end)
         lunette.onProcessExited(function(event)
             exited = { id = event.process.id, outcome = event.outcome, message = event.message }
         end)",
    );

    let process = ProcessId::new(run::<u64>(
        &lua,
        "return lunette.spawn{ argv = { 'nosuchprogram' } }.id",
    ))
    .expect("non-zero");

    session.push_event(LuaEvent::ProcessExited {
        process,
        outcome: ProcessOutcome::SpawnFailed {
            message: "nosuchprogram: no such file or directory".to_owned(),
        },
    });
    poll(&lua, &sink);

    let (id, outcome, message, opened): (u64, String, String, usize) = run(
        &lua,
        "return exited.id, exited.outcome, exited.message, opened",
    );

    assert_eq!(id, process.get());
    assert_eq!(outcome, "spawnFailed");
    assert!(
        message.contains("no such file or directory"),
        "unhelpful message: {message}"
    );
    assert_eq!(
        opened, 0,
        "a program that never ran cannot have connected a client"
    );
}

#[test]
fn safe_mode_terminal_fallback_runs_through_the_native_event_dispatcher() {
    let (session, sink) = recording_session(Vec::new());
    let lua = lua(&session);
    crate::safe_mode::load(&lua)
        .expect("safe mode compiles")
        .call::<()>(())
        .expect("safe mode loads");
    run::<()>(&lua, "lovr.load()");

    // The first two candidates show the order; the rest fail until the list is exhausted.
    let expected = ["foot", "weston-terminal"];
    let mut attempts = 0;
    loop {
        let commands = session.flush();
        if commands.is_empty() {
            break;
        }
        assert_eq!(commands.len(), 1, "exactly one candidate should be queued");
        let Command::Spawn(request) = &commands[0] else {
            panic!("expected a spawn command: {commands:?}");
        };
        if let Some(program) = expected.get(attempts) {
            assert_eq!(request.argv.program(), OsStr::new(program));
        }
        attempts += 1;
        assert!(attempts <= 16, "the candidate list is finite");

        session.push_event(LuaEvent::ProcessExited {
            process: ProcessId::new(u64::MAX).expect("non-zero"),
            outcome: ProcessOutcome::SpawnFailed {
                message: "unrelated".into(),
            },
        });
        poll(&lua, &sink);
        assert!(session.flush().is_empty());

        let event = CompositorEvent::ProcessExited {
            process: request.process,
            outcome: ProcessOutcome::SpawnFailed {
                message: "program not found".into(),
            },
        };
        session.push_event(LuaEvent::from_compositor(&event).expect("exit converts"));
        poll(&lua, &sink);

        session.push_event(LuaEvent::from_compositor(&event).expect("exit converts"));
        poll(&lua, &sink);
    }
    assert!(
        attempts > expected.len(),
        "every candidate is tried before exhaustion stops spawning"
    );
}

#[test]
fn an_exit_reports_its_code_and_a_signal_reports_its_number() {
    let (session, sink) = recording_session(Vec::new());
    let lua = lua(&session);
    run::<()>(
        &lua,
        "seen = {}
         lunette.onProcessExited(function(event)
             seen[#seen + 1] = { outcome = event.outcome, code = event.code, signal = event.signal }
         end)",
    );

    session.push_event(LuaEvent::ProcessExited {
        process: ProcessId::new(1).expect("non-zero"),
        outcome: ProcessOutcome::Exited { code: 3 },
    });
    session.push_event(LuaEvent::ProcessExited {
        process: ProcessId::new(2).expect("non-zero"),
        outcome: ProcessOutcome::Signalled {
            signal: SignalNumber::new(9),
        },
    });
    poll(&lua, &sink);

    let (first, code, second, signal): (String, i32, String, i32) = run(
        &lua,
        "return seen[1].outcome, seen[1].code, seen[2].outcome, seen[2].signal",
    );

    assert_eq!((first.as_str(), code), ("exited", 3));
    assert_eq!((second.as_str(), signal), ("signalled", 9));
}

#[test]
fn output_arrives_as_bytes_under_the_stream_it_was_written_to() {
    let (session, sink) = recording_session(Vec::new());
    let lua = lua(&session);
    run::<()>(
        &lua,
        "lunette.onProcessOutput(function(event) wrote = event end)",
    );

    // Lua strings preserve byte sequences that are not valid UTF-8.
    session.push_event(LuaEvent::ProcessOutput {
        process: ProcessId::new(1).expect("non-zero"),
        stream: Stream::Stderr,
        bytes: vec![b'o', b'h', 0xff],
    });
    poll(&lua, &sink);

    let (stream, bytes): (String, mlua::LuaString) = run(&lua, "return wrote.stream, wrote.text");
    assert_eq!(stream, "stderr");
    assert_eq!(bytes.as_bytes().to_vec(), vec![b'o', b'h', 0xff]);
}

#[test]
fn a_handler_that_raises_does_not_take_the_rest_of_the_frame_with_it() {
    let (session, sink) = recording_session(vec![
        window(1, "first", "foot", PixelSize::new(64, 32)),
        window(2, "second", "foot", PixelSize::new(64, 32)),
    ]);
    let lua = lua(&session);
    run::<()>(
        &lua,
        "seen = {}
         lunette.onWindowOpened(function(event)
             seen[#seen + 1] = event.window.id
             if event.window.id == 1 then error('a defect in the configuration') end
         end)
         lunette.onTitleChanged(function(event) titled = event.title end)",
    );

    session.push_event(LuaEvent::WindowOpened {
        window: window_id(1),
    });
    session.push_event(LuaEvent::WindowOpened {
        window: window_id(2),
    });
    session.push_event(LuaEvent::TitleChanged {
        window: window_id(2),
        title: "renamed".to_owned(),
    });
    poll(&lua, &sink);

    let (count, first, second, titled): (usize, u64, u64, String) =
        run(&lua, "return #seen, seen[1], seen[2], titled");

    assert_eq!((count, first, second), (2, 1, 2));
    assert_eq!(
        titled, "renamed",
        "one bad handler must not swallow a frame's worth of events"
    );
}

#[test]
fn an_event_never_dispatched_is_not_delivered_against_a_later_frame() {
    let (session, sink) =
        recording_session(vec![window(1, "htop", "foot", PixelSize::new(64, 32))]);
    let lua = lua(&session);
    run::<()>(
        &lua,
        "count = 0 lunette.onWindowOpened(function() count = count + 1 end)",
    );

    session.push_event(LuaEvent::WindowOpened {
        window: window_id(1),
    });
    // Discard the queued event before the next frame, as `lovr.event.clear()` does.
    let _discarded = sink.take();
    session.begin(snapshot(Vec::new(), Vec::new()));

    session.push_event(LuaEvent::WindowOpened {
        window: window_id(2),
    });
    poll(&lua, &sink);

    assert_eq!(
        run::<usize>(&lua, "return count"),
        1,
        "the discarded event must not be delivered against a snapshot from a later frame"
    );
}

#[test]
fn an_event_with_no_handler_is_dispatched_and_dropped() {
    let (session, sink) = recording_session(Vec::new());
    let lua = lua(&session);

    session.push_event(LuaEvent::WindowOpened {
        window: window_id(1),
    });
    poll(&lua, &sink);

    assert_eq!(run::<usize>(&lua, "return #lunette.windows()"), 0);
}

/// Creates two claims and displaces the first from a one-slot pool.
fn contending(source: &str) -> (crate::lua::tests::TestSession, mlua::Lua) {
    let (session, sink, registry) = layered_session(
        vec![
            window(1, "first", "foot", PixelSize::new(640, 480)),
            window(2, "second", "foot", PixelSize::new(640, 480)),
        ],
        ONE_SLOT,
    );
    let lua = lua(&session);
    run::<()>(&lua, source);
    run::<()>(
        &lua,
        "held = {}
         for index = 1, 2 do
             held[index] = lunette.claimLayer{
                 window = lunette.windows()[index],
                 width = 640, height = 480, priority = 6 - index,
             }
         end",
    );

    settle(&session, &registry);
    poll(&lua, &sink);
    run::<()>(&lua, "seen = {}");

    // Revocation and grant occur on separate frame boundaries. The recycled layer must be copied
    // between them.
    run::<()>(&lua, "held[2]:setPriority(9)");
    settle(&session, &registry);
    poll(&lua, &sink);

    (session, lua)
}

#[test]
fn a_displaced_claim_is_revoked_before_its_displacer_is_granted() {
    let (_session, lua) = contending(
        "seen = {}
         lunette.onLayerGranted(function(event)
             seen[#seen + 1] = { name = 'granted', id = event.claim.id }
         end)
         lunette.onLayerRevoked(function(event)
             seen[#seen + 1] = { name = 'revoked', id = event.claim.id }
         end)",
    );

    let (count, first, revoked, second, granted): (usize, String, u64, String, u64) = run(
        &lua,
        "return #seen, seen[1].name, seen[1].id, seen[2].name, seen[2].id",
    );

    assert_eq!(count, 2, "exactly one of each, and neither twice");
    assert_eq!(first, "revoked");
    assert_eq!(second, "granted");
    assert_eq!(
        run::<u64>(&lua, "return held[1].id"),
        revoked,
        "the claim that lost the layer is the one the revocation names"
    );
    assert_eq!(
        run::<u64>(&lua, "return held[2].id"),
        granted,
        "revoking is what frees the layer the grant takes"
    );
}

#[test]
fn a_grant_carries_the_layer_and_agrees_with_the_claim_the_handler_reads() {
    let (_session, lua) = contending(
        "lunette.onLayerGranted(function(event)
             gained = { layer = event.layer, granted = event.claim.granted, own = event.claim.layer }
         end)
         lunette.onLayerRevoked(function(event)
             lost = { granted = event.claim.granted, layer = event.claim.layer, dead = event.claim.dead }
         end)",
    );

    let (layer, granted, own): (Value, bool, Value) =
        run(&lua, "return gained.layer, gained.granted, gained.own");
    assert_eq!(
        layer,
        Value::Integer(1),
        "the event carries the Layer itself"
    );
    assert!(
        granted,
        "the event fires at the boundary the grant lands on, so the claim already reads granted"
    );
    assert_eq!(
        own, layer,
        "and reading it through the claim is the same Layer"
    );

    let (still_granted, lost_layer, dead): (bool, Value, bool) =
        run(&lua, "return lost.granted, lost.layer, lost.dead");
    assert!(!still_granted);
    assert_eq!(lost_layer, Value::Boolean(false));
    assert!(
        !dead,
        "a revoked claim is still a claim; it takes a layer again when one frees"
    );
}

#[test]
fn an_error_in_a_handler_undoes_neither_the_grant_nor_the_revocation() {
    let (_session, lua) = contending(
        "lunette.onLayerRevoked(function() error('a defect in the configuration') end)
         lunette.onLayerGranted(function() error('and another') end)",
    );

    let (first, second): (bool, bool) = run(&lua, "return held[1].granted, held[2].granted");
    assert_eq!(
        (first, second),
        (false, true),
        "both had already happened in Rust before either handler ran"
    );
}

/// A handler error reaches every `lunette.onError` subscriber with its traceback.
#[test]
fn a_handlers_error_reaches_every_subscriber_with_its_traceback() {
    let (session, sink) =
        recording_session(vec![window(1, "htop", "foot", PixelSize::new(64, 32))]);
    let lua = lua(&session);
    run::<()>(
        &lua,
        "seen = {}
         others = 0
         lunette.onError(function() others = others + 1 end)
         lunette.onError(function(event) seen[#seen + 1] = event end)
         lunette.onWindowOpened(function() error('a defect in the configuration') end)",
    );

    session.push_event(LuaEvent::WindowOpened {
        window: window_id(1),
    });
    poll(&lua, &sink);

    let (others, delivered, message, traceback): (usize, usize, String, String) = run(
        &lua,
        "return others, #seen, seen[1].message, seen[1].traceback",
    );
    assert_eq!((others, delivered), (1, 1));
    assert!(
        message.contains("lunette.onWindowOpened") && message.contains("a defect"),
        "the report should name the callback and what it said: {message}"
    );
    assert!(
        traceback.contains("stack traceback:"),
        "a message without a traceback is nearly useless for a callback invoked from native code: \
         {traceback}"
    );
}

/// `lunette.reportError` sends protected handler errors to every listener with context.
#[test]
fn a_reported_error_reaches_every_listener_and_requires_a_message() {
    let session = session(Vec::new());
    let lua = lua(&session);
    run::<()>(
        &lua,
        "seen = {}
         lunette.onError(function() error('a listener that raises') end)
         lunette.onError(function(event) seen[#seen + 1] = event end)
         lunette.reportError { context = 'lovr.draw', message = 'a handler failed', traceback = 'stack traceback: here' }
         lunette.reportError { context = 'lovr.update', message = 'no traceback' }",
    );

    let (count, first, trace, second, empty): (usize, String, String, String, String) = run(
        &lua,
        "return #seen, seen[1].message, seen[1].traceback, seen[2].message, seen[2].traceback",
    );
    assert_eq!(count, 2, "a raising listener does not stop the next");
    assert_eq!(first, "lovr.draw: a handler failed");
    assert_eq!(trace, "stack traceback: here");
    assert_eq!(second, "lovr.update: no traceback");
    assert_eq!(empty, "");

    let missing: String = run(
        &lua,
        "local ok, message = pcall(function() lunette.reportError { context = 'lovr.draw' } end)
         assert(not ok, 'the report should have raised')
         return tostring(message)",
    );
    assert!(missing.contains("reportError's message"), "{missing}");
}

#[test]
fn a_dispatcher_is_installed_for_every_event_the_module_can_push() {
    let session = session(Vec::new());
    let lua = lua(&session);

    let mut names: Vec<String> = run::<Table>(&lua, "return lovr.handlers")
        .pairs::<String, Value>()
        .map(|pair| pair.expect("the handler keys are strings").0)
        .collect();
    names.sort();

    assert_eq!(
        names,
        vec![
            "lunlayergranted".to_owned(),
            "lunlayerrevoked".to_owned(),
            "lunmonitoradded".to_owned(),
            "lunprocessexited".to_owned(),
            "lunprocessoutput".to_owned(),
            "luntitlechanged".to_owned(),
            "lunwindowclosed".to_owned(),
            "lunwindowopened".to_owned(),
        ],
        "a name here is what `docs/dev/lua-api.md` promises a configuration can hook"
    );
}
