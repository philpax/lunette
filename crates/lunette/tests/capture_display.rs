//! Hosted applications receive lunette's display without changing the host
//! display used by direct capture.

#![expect(
    clippy::expect_used,
    reason = "a failed expectation is how a test reports a failure"
)]

use std::ffi::OsString;

use lunette_compositor::{
    client::DisplayName,
    protocol::{Argv, Command, ProcessId, SpawnRequest},
    state::CompositorConfig,
    testing::TestCompositor,
};

#[test]
fn hosted_clients_receive_lunettes_display_without_a_global_export() {
    let display = DisplayName::for_test(47);
    let mut compositor = TestCompositor::with_config(CompositorConfig {
        display: Some(display),
        ..CompositorConfig::default()
    });
    compositor.send(Command::Spawn(SpawnRequest {
        process: ProcessId::new(1).expect("one is nonzero"),
        argv: Argv::new("test-client", Vec::new()),
        env: Vec::new(),
        cwd: None,
        output: None,
        xwayland: false,
    }));
    compositor.step();

    let plans = compositor.spawns().requested();
    let plan = plans.first().expect("the compositor produced a spawn plan");
    // Apply the plan to a distinct inherited host display, without mutating the
    // test process environment or starting a real application.
    let mut child_display = OsString::from("wayland-host");
    for (key, value) in &plan.env {
        if key == "WAYLAND_DISPLAY" {
            child_display.clone_from(value);
        }
    }
    assert_eq!(child_display, display.wayland());
    assert_ne!(child_display, OsString::from("wayland-host"));
}
