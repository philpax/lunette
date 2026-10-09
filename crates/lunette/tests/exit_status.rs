//! Linux-only: the process exit status a Lua session requests.
//!
//! `boot.lua` returns the status followed by a cookie, so reading the top of the stack would
//! hide nonzero statuses.

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

/// `luau_check.rs` checks the same fixture in the checker.
#[test]
fn a_relative_require_resolves_against_the_requiring_file() {
    assert_exit_status("require-relative", 9);
}
