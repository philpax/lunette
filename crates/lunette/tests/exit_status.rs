//! Linux-specific test for the process exit status requested by a Lua session.
//!
//! `boot.lua` returns the requested status followed by a cookie. Reading stack index -1
//! reads the nil cookie, which converts to zero and hides nonzero exit statuses.
//! `boot::run` returns an opaque `ExitCode`, so the test observes the process.

use crate::session::assert_exit_status;

mod session;

#[test]
fn a_quit_status_reaches_the_process_exit_status() {
    assert_exit_status("quit-with-status", 3);
}

#[test]
fn a_quit_without_a_status_exits_zero() {
    assert_exit_status("quit-without-status", 0);
}

/// Checks that a configuration can require `lunette` in the LÖVR-created state.
///
/// The fixture reports through distinct exit statuses because it has no other output channel.
#[test]
fn a_configuration_can_require_the_lunette_module() {
    assert_exit_status("require-lunette", 9);
}

/// A relative require resolves against the requiring file, in the session as
/// in the checker. `luau_check.rs` checks the same fixture.
#[test]
fn a_relative_require_resolves_against_the_requiring_file() {
    assert_exit_status("require-relative", 9);
}
