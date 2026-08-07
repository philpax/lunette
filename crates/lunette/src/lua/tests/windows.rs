//! Window handles: what one reports, what it does, and what it does once its
//! window has gone.
//!
//! The dead-handle rule is most of what is here. A handle whose window the
//! snapshot no longer lists answers from what it last knew and returns `false`
//! from its methods rather than raising, because a window closing half a frame
//! early is ordinary and taking the session down over it is not.

use lunette_compositor::protocol::{
    Command, ContentType, FramePacing, PixelSize, ToplevelState, ToplevelStates,
};
use pretty_assertions::assert_eq;

use crate::{
    import::formats::Alpha,
    lua::tests::{FakeTexture, error, lua, run, session, snapshot, surface_id, window, window_id},
    texture::{TextureDescription, TextureRef},
};

#[test]
fn a_snapshot_of_two_windows_becomes_two_handles() {
    let session = session(vec![
        window(1, "htop", "foot", PixelSize::new(1280, 720)),
        window(
            2,
            "editor",
            "org.gnome.TextEditor",
            PixelSize::new(1920, 1080),
        ),
    ]);
    let lua = lua(&session);

    let (count, first_title, first_app, first_width, first_height): (
        usize,
        String,
        String,
        u32,
        u32,
    ) = run(
        &lua,
        "local w = lunette.windows()
         return #w, w[1].title, w[1].appId, w[1].width, w[1].height",
    );

    assert_eq!(count, 2);
    assert_eq!(first_title, "htop");
    assert_eq!(first_app, "foot");
    assert_eq!(
        (first_width, first_height),
        (1280, 720),
        "the dimensions are pixels, which is what a panel converts a ray hit into"
    );

    let (second_title, second_width): (String, u32) = run(
        &lua,
        "local w = lunette.windows() return w[2].title, w[2].width",
    );
    assert_eq!(second_title, "editor");
    assert_eq!(second_width, 1920);
}

#[test]
fn windows_are_empty_before_anything_has_mapped() {
    let session = session(Vec::new());
    let lua = lua(&session);

    assert_eq!(run::<usize>(&lua, "return #lunette.windows()"), 0);
}

#[test]
fn a_window_reports_the_identifier_it_keeps_for_its_whole_life() {
    let session = session(vec![window(7, "term", "foot", PixelSize::new(64, 32))]);
    let lua = lua(&session);

    assert_eq!(run::<u64>(&lua, "return lunette.windows()[1].id"), 7);
    assert!(!run::<bool>(&lua, "return lunette.windows()[1].dead"));
}

#[test]
fn a_handle_follows_its_window_across_frames() {
    let session = session(vec![window(1, "before", "foot", PixelSize::new(64, 32))]);
    let lua = lua(&session);
    run::<()>(&lua, "held = lunette.windows()[1]");

    session.begin(snapshot(
        vec![window(1, "after", "foot", PixelSize::new(128, 64))],
        Vec::new(),
    ));

    let (title, width): (String, u32) = run(&lua, "return held.title, held.width");
    assert_eq!(title, "after");
    assert_eq!(width, 128);
}

#[test]
fn a_dead_handle_reads_its_last_known_values_and_raises_nothing() {
    let session = session(vec![window(1, "htop", "foot", PixelSize::new(1280, 720))]);
    let lua = lua(&session);
    run::<()>(&lua, "held = lunette.windows()[1]");

    session.begin(snapshot(Vec::new(), Vec::new()));

    let (dead, title, app_id, width, height): (bool, String, String, u32, u32) = run(
        &lua,
        "return held.dead, held.title, held.appId, held.width, held.height",
    );

    assert!(dead);
    assert_eq!(title, "htop");
    assert_eq!(app_id, "foot");
    assert_eq!((width, height), (1280, 720));
}

#[test]
fn every_method_of_a_dead_handle_returns_false() {
    let session = session(vec![window(1, "htop", "foot", PixelSize::new(1280, 720))]);
    session.with_textures(|textures| {
        textures.install(
            surface_id(1),
            FakeTexture(11),
            TextureDescription {
                size: PixelSize::new(1280, 720),
                alpha: Alpha::Present,
            },
        )
    });
    let lua = lua(&session);
    run::<()>(&lua, "held = lunette.windows()[1] sink = held.sink");

    session.begin(snapshot(Vec::new(), Vec::new()));

    let (texture, pointer, button, sink_dead): (bool, bool, bool, bool) = run(
        &lua,
        "return held:getTexture(), sink:pointer(4, 5), sink:button('left', true), sink.dead",
    );

    assert!(!texture);
    assert!(!pointer);
    assert!(!button);
    assert!(sink_dead);
    assert!(
        session.flush().is_empty(),
        "a refused mutation must not reach the compositor"
    );
}

#[test]
fn get_texture_answers_with_the_texture_the_ledger_holds() {
    let session = session(vec![window(1, "htop", "foot", PixelSize::new(64, 32))]);
    session.with_textures(|textures| {
        textures.install(
            surface_id(1),
            FakeTexture(42),
            TextureDescription {
                size: PixelSize::new(64, 32),
                alpha: Alpha::Present,
            },
        )
    });
    let lua = lua(&session);

    assert_eq!(
        run::<i64>(&lua, "return lunette.windows()[1]:getTexture()"),
        42
    );
}

#[test]
fn a_window_whose_buffer_has_no_alpha_channel_reports_itself_opaque() {
    // The regression: an X-variant fourcc maps to an alpha Vulkan format, so
    // the padding byte arrives as alpha and is usually zero. Nothing consumed
    // the distinction, and a `XR24` client drew fully invisible.
    let session = session(vec![window(1, "htop", "foot", PixelSize::new(64, 32))]);
    session.with_textures(|textures| {
        textures.install(
            surface_id(1),
            FakeTexture(42),
            TextureDescription {
                size: PixelSize::new(64, 32),
                alpha: Alpha::Opaque,
            },
        )
    });
    let lua = lua(&session);

    assert!(
        run::<bool>(&lua, "return lunette.windows()[1].opaque"),
        "a consumer forces alpha to one for these, and this is what tells it to"
    );
}

#[test]
fn a_window_whose_buffer_carries_alpha_does_not_report_itself_opaque() {
    let session = session(vec![window(1, "htop", "foot", PixelSize::new(64, 32))]);
    session.with_textures(|textures| {
        textures.install(
            surface_id(1),
            FakeTexture(42),
            TextureDescription {
                size: PixelSize::new(64, 32),
                alpha: Alpha::Present,
            },
        )
    });
    let lua = lua(&session);

    assert!(!run::<bool>(&lua, "return lunette.windows()[1].opaque"));
}

#[test]
fn a_window_with_no_buffer_yet_is_not_reported_opaque() {
    let session = session(vec![window(1, "htop", "foot", PixelSize::new(64, 32))]);
    let lua = lua(&session);

    assert!(
        !run::<bool>(&lua, "return lunette.windows()[1].opaque"),
        "there is no texture to draw, so there is nothing to force alpha on"
    );
}

#[test]
fn get_texture_answers_false_before_the_client_has_committed_anything() {
    let session = session(vec![window(1, "htop", "foot", PixelSize::new(64, 32))]);
    let lua = lua(&session);

    assert!(!run::<bool>(
        &lua,
        "return lunette.windows()[1]:getTexture()"
    ));
}

#[test]
fn a_texture_handle_is_refused_once_its_frame_has_passed() {
    // Not reachable from Lua, which resolves a reference in the call that
    // built it. The ledger's rule is what `getTexture` relies on, so the test
    // states it at the boundary rather than only inside `texture.rs`.
    let session = session(Vec::new());
    session.with_textures(|textures| {
        textures.install(
            surface_id(1),
            FakeTexture(42),
            TextureDescription {
                size: PixelSize::new(64, 32),
                alpha: Alpha::Present,
            },
        )
    });

    let obtained = session.generation();
    session.begin(snapshot(Vec::new(), Vec::new()));
    let current = session.generation();

    session.with_textures(|textures| {
        assert!(
            textures
                .lookup(TextureRef::new(surface_id(1), obtained), current)
                .is_err()
        );
        assert!(
            textures
                .lookup(TextureRef::new(surface_id(1), current), current)
                .is_ok()
        );
    });
}

#[test]
fn closing_asks_the_client_and_does_not_remove_the_window_itself() {
    let session = session(vec![window(1, "editor", "foot", PixelSize::new(64, 32))]);
    let lua = lua(&session);

    assert!(run::<bool>(&lua, "return lunette.windows()[1]:close()"));
    assert_eq!(
        run::<usize>(&lua, "return #lunette.windows()"),
        1,
        "the client decides: it may prompt, or refuse, and the window goes when it unmaps"
    );

    match session.flush().as_slice() {
        [Command::CloseWindow { window }] => assert_eq!(*window, window_id(1)),
        other => panic!("expected a close command, got {other:?}"),
    }
}

#[test]
fn resizing_configures_the_toplevel_without_waiting_for_the_client() {
    let session = session(vec![window(1, "editor", "foot", PixelSize::new(64, 32))]);
    let lua = lua(&session);

    assert!(run::<bool>(
        &lua,
        "return lunette.windows()[1]:resize(1920, 1080)"
    ));
    let (width, height): (u32, u32) = run(
        &lua,
        "local w = lunette.windows()[1] return w.width, w.height",
    );
    assert_eq!(
        (width, height),
        (64, 32),
        "the size reported is the one the client last committed, not the one asked of it"
    );

    match session.flush().as_slice() {
        [
            Command::ConfigureWindow {
                window,
                size,
                states,
            },
        ] => {
            assert_eq!(*window, window_id(1));
            assert_eq!(*size, Some(PixelSize::new(1920, 1080)));
            assert!(states.is_empty());
        }
        other => panic!("expected a configure command, got {other:?}"),
    }
}

#[test]
fn resizing_restates_the_states_the_window_is_already_in() {
    let mut maximized = window(1, "editor", "foot", PixelSize::new(64, 32));
    maximized.states = ToplevelStates::from_iter([ToplevelState::Maximized]);

    let session = session(vec![maximized]);
    let lua = lua(&session);
    run::<bool>(&lua, "return lunette.windows()[1]:resize(800, 600)");

    match session.flush().as_slice() {
        [Command::ConfigureWindow { states, .. }] => assert!(
            states.contains(&ToplevelState::Maximized),
            "a configure replaces the state set wholesale, so omitting them would unmaximise it"
        ),
        other => panic!("expected a configure command, got {other:?}"),
    }
}

#[test]
fn a_window_reports_the_content_type_its_client_set() {
    let mut playing = window(1, "mpv", "mpv", PixelSize::new(64, 32));
    playing.content_type = ContentType::Video;
    let session = session(vec![playing]);
    let lua = lua(&session);

    assert_eq!(
        run::<String>(&lua, "return lunette.windows()[1].contentType"),
        "video"
    );
}

#[test]
fn a_window_whose_client_said_nothing_reports_none() {
    let session = session(vec![window(1, "foot", "foot", PixelSize::new(64, 32))]);
    let lua = lua(&session);

    assert_eq!(
        run::<String>(&lua, "return lunette.windows()[1].contentType"),
        "none",
        "the protocol's own default, and what most clients report"
    );
}

#[test]
fn setting_a_frame_rate_paces_the_window_s_surface() {
    let session = session(vec![window(1, "mpv", "mpv", PixelSize::new(64, 32))]);
    let lua = lua(&session);

    assert!(run::<bool>(
        &lua,
        "return lunette.windows()[1]:setFrameRate(10)"
    ));

    match session.flush().as_slice() {
        [Command::SetFramePacing { surface, pacing }] => {
            assert_eq!(*surface, surface_id(1));
            match pacing {
                FramePacing::Limited(rate) => assert!((rate.get() - 10.0).abs() < f64::EPSILON),
                other => panic!("expected a limited pacing, got {other:?}"),
            }
        }
        other => panic!("expected a pacing command, got {other:?}"),
    }
}

#[test]
fn setting_no_frame_rate_returns_the_window_to_unthrottled() {
    let session = session(vec![window(1, "mpv", "mpv", PixelSize::new(64, 32))]);
    let lua = lua(&session);

    assert!(run::<bool>(
        &lua,
        "return lunette.windows()[1]:setFrameRate()"
    ));

    match session.flush().as_slice() {
        [
            Command::SetFramePacing {
                pacing: FramePacing::Unthrottled,
                ..
            },
        ] => {}
        other => panic!("expected an unthrottled pacing command, got {other:?}"),
    }
}

#[test]
fn a_frame_rate_that_is_not_a_positive_number_is_reported() {
    let session = session(vec![window(1, "mpv", "mpv", PixelSize::new(64, 32))]);
    let lua = lua(&session);

    for chunk in [
        "lunette.windows()[1]:setFrameRate(0)",
        "lunette.windows()[1]:setFrameRate(-1)",
        "lunette.windows()[1]:setFrameRate(0 / 0)",
        "lunette.windows()[1]:setFrameRate(1 / 0)",
    ] {
        let message = error(&lua, chunk);
        assert!(
            message.contains("is not a frame rate"),
            "unhelpful message for {chunk}: {message}"
        );
    }

    assert!(
        session.flush().is_empty(),
        "a refused rate must not reach the compositor"
    );
}

#[test]
fn a_size_that_is_not_a_pair_of_pixel_counts_is_reported() {
    let session = session(vec![window(1, "editor", "foot", PixelSize::new(64, 32))]);
    let lua = lua(&session);

    for chunk in [
        "lunette.windows()[1]:resize(0, 600)",
        "lunette.windows()[1]:resize(-1, 600)",
        "lunette.windows()[1]:resize(800, 0.5)",
        "lunette.windows()[1]:resize(800, 0 / 0)",
        "lunette.windows()[1]:resize(800, 2 ^ 40)",
    ] {
        let message = error(&lua, chunk);
        assert!(
            message.contains("is not a window size"),
            "unhelpful message for {chunk}: {message}"
        );
    }

    assert!(
        session.flush().is_empty(),
        "a refused configure must not reach the compositor"
    );
}

#[test]
fn stabilizing_hands_back_the_same_texture_while_the_buffer_rotates() {
    let session = session(vec![window(1, "htop", "foot", PixelSize::new(64, 32))]);
    session.with_textures(|textures| {
        textures.install(
            surface_id(1),
            FakeTexture(42),
            TextureDescription {
                size: PixelSize::new(64, 32),
                alpha: Alpha::Present,
            },
        )
    });
    let lua = lua(&session);

    let (stable, again, imported): (i64, i64, i64) = run(
        &lua,
        "local w = lunette.windows()[1]
         return w:stabilize(), w:stabilize(), w:getTexture()",
    );

    assert_eq!(
        stable, again,
        "a second call returns the same texture rather than allocating another"
    );
    assert_ne!(stable, imported, "the copy is lunette's, not the client's");

    // The client commits its next buffer, which is a different texture.
    session.with_textures(|textures| {
        textures.install(
            surface_id(1),
            FakeTexture(43),
            TextureDescription {
                size: PixelSize::new(64, 32),
                alpha: Alpha::Present,
            },
        )
    });
    session.begin(snapshot(
        vec![window(1, "htop", "foot", PixelSize::new(64, 32))],
        Vec::new(),
    ));

    let (after, rotated): (i64, i64) = run(
        &lua,
        "local w = lunette.windows()[1] return w:stabilize(), w:getTexture()",
    );
    assert_eq!(
        after, stable,
        "the identity is what the copy exists to provide"
    );
    assert_eq!(rotated, 43, "the imported texture rotated underneath it");
}

#[test]
fn stabilizing_answers_false_before_the_client_has_committed_anything() {
    let session = session(vec![window(1, "htop", "foot", PixelSize::new(64, 32))]);
    let lua = lua(&session);

    assert!(!run::<bool>(
        &lua,
        "return lunette.windows()[1]:stabilize()"
    ));
}

#[test]
fn every_mutation_of_a_dead_handle_returns_false() {
    let session = session(vec![window(1, "htop", "foot", PixelSize::new(64, 32))]);
    session.with_textures(|textures| {
        textures.install(
            surface_id(1),
            FakeTexture(42),
            TextureDescription {
                size: PixelSize::new(64, 32),
                alpha: Alpha::Present,
            },
        )
    });
    let lua = lua(&session);
    run::<()>(&lua, "held = lunette.windows()[1]");

    session.begin(snapshot(Vec::new(), Vec::new()));

    let (closed, resized, stabilized): (bool, bool, bool) = run(
        &lua,
        "return held:close(), held:resize(800, 600), held:stabilize()",
    );

    assert!(!closed);
    assert!(!resized);
    assert!(!stabilized);
    assert!(
        session.flush().is_empty(),
        "a refused mutation must not reach the compositor"
    );
}
