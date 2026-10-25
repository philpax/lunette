//! Checks opt-in frame observation and checked boot instrumentation.

#![expect(
    clippy::expect_used,
    reason = "tests report setup failures with context"
)]

use mlua::{Function, Table};

use super::*;

#[test]
fn boot_transform_matches_the_embedded_vendor_loop_and_rejects_drift() {
    let patched = instrument_boot(lunette_lovr::BOOT_LUA).expect("known boot loop");
    assert!(patched.contains("local frameTrace = ..."));
    assert!(patched.contains("frameTrace.mark('heapPresent', 'present')"));
    assert!(instrument_boot(b"function lovr.run() end").is_err());
}

#[test]
#[expect(
    clippy::expect_used,
    reason = "tests report Lua setup failures with context"
)]
fn public_subscription_reuses_a_record_and_cancel_is_idempotent() {
    let lua = crate::test_lua::session_lua();
    lua.load("lovr = { timer = { getTime = function() return 1 end } }")
        .exec()
        .expect("clock");
    install(&lua, "tiered").expect("sampler");
    let listener: Function = lua
        .load("return function(row) observed = row; calls = (calls or 0) + 1 end")
        .eval()
        .expect("listener");
    let cancel = observe(&lua, Listener(listener)).expect("subscription");
    let duplicate: Function = lua.load("return function() end").eval().expect("listener");
    assert!(observe(&lua, Listener(duplicate)).is_err());
    let sampler = sampler(&lua).expect("sampler");
    let row: Table = sampler.get("row").expect("record");
    row.set("syncTime", 1).expect("sync time");
    collected(&lua, 0.0002, 200, 1, false, false).expect("GC boundary");
    publish(&lua, Some(0.0003)).expect("publication");
    assert_eq!(lua.globals().get::<u32>("calls").expect("calls"), 1);
    let observed: Table = lua.globals().get("observed").expect("record");
    assert_eq!(observed.to_pointer(), row.to_pointer());
    assert_eq!(observed.get::<f64>("gc").expect("GC duration"), 0.0002);
    cancel.0.call::<()>(()).expect("cancel");
    cancel.0.call::<()>(()).expect("repeat cancel");
    publish(&lua, None).expect("inactive publication");
    assert_eq!(lua.globals().get::<u32>("calls").expect("calls"), 1);
}
