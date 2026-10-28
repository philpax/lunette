//! Exercises the transformed boot frame loop without a graphics device or headset.

#![expect(
    clippy::expect_used,
    reason = "tests report setup failures with context"
)]

use mlua::Lua;

use super::*;

fn setup() -> Lua {
    let lua = crate::test_lua::session_lua();
    lua.load("clock = 0; lovr = { timer = { getTime = function() clock += .001; return clock end, step = function() return .011 end } }")
        .exec().expect("clock");
    install(&lua, "interpreter").expect("sampler");
    lua.globals()
        .set("sampler", sampler(&lua).expect("sampler"))
        .expect("sampler global");
    let source = instrument_boot(lunette_lovr::BOOT_LUA).expect("boot anchors");
    let start = source.find("function lovr.run()").expect("run start");
    let end = source.find("\nfunction lovr.mirror(").expect("run end");
    lua.load(format!("local frameTrace = ...\n{}", &source[start..end]))
        .call::<()>(sampler(&lua).expect("sampler"))
        .expect("frame loop");
    lua
}

#[test]
fn disabled_loop_does_not_sample_and_no_module_loop_is_supported() {
    let lua = setup();
    lua.load("frame = lovr.run(); frame(); assert(clock == 0)")
        .exec()
        .expect("inactive loop");
    let listener = lua
        .load("return function(row) assert(row.update == nil and row.heapUpdate == nil); assert(row.sync == nil); assert(row.syncTime ~= nil); calls = (calls or 0) + 1 end")
        .eval()
        .expect("listener");
    let _cancel = observe(&lua, Listener(listener)).expect("observer");
    lua.load("frame()").exec().expect("active no-module loop");
    collected(&lua, 0.0, 0, 0, false, false).expect("GC boundary");
    publish(&lua, None).expect("publish");
    assert_eq!(lua.globals().get::<u32>("calls").expect("calls"), 1);
}

#[test]
fn update_timing_and_heap_are_absent_when_callback_is_removed() {
    let lua = setup();
    lua.load("lovr.update = function() updates = (updates or 0) + 1 end")
        .exec()
        .expect("update callback");
    let listener = lua
        .load(
            "return function(row)
                calls = (calls or 0) + 1
                if calls == 1 then
                    assert(row.update ~= nil and row.heapUpdate ~= nil)
                else
                    assert(row.update == nil, 'missing update duration must be nil')
                    assert(row.heapUpdate == nil, 'missing update heap must be nil')
                end
            end",
        )
        .eval()
        .expect("listener");
    let _cancel = observe(&lua, Listener(listener)).expect("observer");
    lua.load("frame = lovr.run(); frame()")
        .exec()
        .expect("update frame");
    publish(&lua, None).expect("update publish");
    lua.load("lovr.update = nil; frame()")
        .exec()
        .expect("frame without update");
    publish(&lua, None).expect("missing update publish");
    assert_eq!(lua.globals().get::<u32>("calls").expect("calls"), 2);
    assert_eq!(lua.globals().get::<u32>("updates").expect("updates"), 1);
}

#[test]
fn headset_graphics_submission_timing_requires_a_pass() {
    for headset_pass in [false, true] {
        for window_pass in [false, true] {
            let lua = setup();
            lua.load(HEADSET).exec().expect("headset facade");
            lua.globals()
                .set("headsetPass", headset_pass)
                .expect("headset pass");
            lua.globals()
                .set("windowPass", window_pass)
                .expect("window pass");
            lua.load(
                "lovr.graphics = {
                    isTimingEnabled = function() return false end,
                    getWindowPass = function() return windowPass and {} or nil end,
                    submit = function() graphicsSubmits = (graphicsSubmits or 0) + 1 end,
                    present = function() presents = (presents or 0) + 1 end,
                }",
            )
            .exec()
            .expect("graphics facade");
            let listener = lua
                .load(
                    "return function(row)
                        if headsetPass or windowPass then
                            assert(row.graphicsSubmit ~= nil and row.heapGraphicsSubmit ~= nil)
                        else
                            assert(row.graphicsSubmit == nil, 'missing graphics submission duration must be nil')
                            assert(row.heapGraphicsSubmit == nil, 'missing graphics submission heap must be nil')
                        end
                        assert(row.draw ~= nil and row.heapDraw ~= nil)
                        assert(row.headsetSubmit ~= nil and row.heapHeadsetSubmit ~= nil)
                        assert(row.present ~= nil and row.heapPresent ~= nil)
                        observed = true
                    end",
                )
                .eval()
                .expect("listener");
            let _cancel = observe(&lua, Listener(listener)).expect("observer");
            lua.load("frame = lovr.run(); frame()")
                .exec()
                .expect("headset frame");
            publish(&lua, None).expect("headset publish");
            assert!(lua.globals().get::<bool>("observed").expect("observed"));
            assert_eq!(
                lua.globals()
                    .get::<Option<u32>>("graphicsSubmits")
                    .expect("graphics submissions"),
                if headset_pass || window_pass {
                    Some(1)
                } else {
                    None
                }
            );
            assert_eq!(
                lua.globals()
                    .get::<u32>("headsetSubmits")
                    .expect("headset submissions"),
                1
            );
            assert_eq!(lua.globals().get::<u32>("presents").expect("presents"), 1);
        }
    }
}

#[test]
fn headset_sampling_never_acquires_a_texture_with_or_without_graphics() {
    for graphics in [false, true] {
        let lua = setup();
        lua.load(HEADSET).exec().expect("headset facade");
        if graphics {
            lua.load(
                "lovr.graphics = {
                    isTimingEnabled = function() return false end,
                    getWindowPass = function() end,
                    submit = function() error('no passes to submit') end,
                    present = function() end,
                }",
            )
            .exec()
            .expect("graphics facade");
        }
        let listener = lua
            .load(
                "return function(row)
                    assert(row.active and row.visible and row.focused)
                    assert(row.sync ~= nil and row.sync > 0)
                    assert(row.refreshRate == 90 and row.foveation == 2)
                    assert(row.nativeInterval == .011 and row.nativeWork == .004 and row.skipped == 0)
                    assert(row.headsetSubmit ~= nil and row.heapHeadsetSubmit ~= nil)
                    observed = true
                end",
            )
            .eval()
            .expect("listener");
        let _cancel = observe(&lua, Listener(listener)).expect("observer");
        lua.load("frame = lovr.run(); frame()")
            .exec()
            .expect("metadata sampling without texture acquisition");
        publish(&lua, None).expect("metadata publish");
        assert!(lua.globals().get::<bool>("observed").expect("observed"));
    }
}

const HEADSET: &str = "lovr.headset = {
    pollEvents = function() end,
    update = function() end,
    isActive = function() return true end,
    isVisible = function() return true end,
    isFocused = function() return true end,
    getRefreshRate = function() return 90 end,
    getFrameTiming = function() return { interval = .011, work = .004, skipped = 0 } end,
    getFoveation = function() return 2 end,
    getTexture = function() error('sampler must not acquire a headset texture') end,
    getPass = function() return headsetPass and {} or nil end,
    submit = function() headsetSubmits = (headsetSubmits or 0) + 1 end,
}";

#[test]
fn partial_acquisition_and_event_quit_do_not_publish_rows() {
    let lua = setup();
    let acquire = lua
        .create_function(|lua, ()| {
            let listener = lua
                .load("return function() calls = (calls or 0) + 1 end")
                .eval()?;
            observe(lua, Listener(listener)).map(|_| ())
        })
        .expect("acquire");
    lua.globals()
        .set("acquire", acquire)
        .expect("acquire global");
    lua.load(
        "lovr.update = function() acquire(); lovr.update = nil end; frame = lovr.run(); frame()",
    )
    .exec()
    .expect("partial frame");
    publish(&lua, None).expect("partial publish");
    assert!(
        lua.globals()
            .get::<Option<u32>>("calls")
            .expect("calls")
            .is_none()
    );
    lua.load("lovr.event = { poll = function() return coroutine.wrap(function() coroutine.yield('quit', 0) end) end }; assert(frame() == 0)")
        .exec().expect("quit frame");
    publish(&lua, None).expect("quit publish");
    assert!(
        lua.globals()
            .get::<Option<u32>>("calls")
            .expect("calls")
            .is_none()
    );
}

#[test]
fn window_draw_time_is_present_even_when_draw_suppresses_submission() {
    for skip in [true, false] {
        let lua = setup();
        lua.globals().set("skip", skip).expect("draw result");
        lua.load("lovr.graphics = { isTimingEnabled = function() return false end, getWindowPass = function() return {} end, submit = function() submits = (submits or 0) + 1 end, present = function() end }; lovr.draw = function() return skip end")
            .exec().expect("graphics facade");
        let listener = lua
            .load("return function(row) assert(row.draw ~= nil); observed = true end")
            .eval()
            .expect("listener");
        let _cancel = observe(&lua, Listener(listener)).expect("observer");
        lua.load("frame = lovr.run(); frame()")
            .exec()
            .expect("window frame");
        publish(&lua, None).expect("publish");
        assert!(
            lua.globals()
                .get::<bool>("observed")
                .expect("draw observed")
        );
        assert_eq!(
            lua.globals()
                .get::<Option<u32>>("submits")
                .expect("submissions"),
            if skip { None } else { Some(1) }
        );
    }
}

#[test]
fn preparatory_passes_precede_headset_and_mirror_in_one_submission() {
    for bits in 0..32 {
        let tracing = bits & 1 != 0;
        let headset = bits & 2 != 0;
        let window = bits & 4 != 0;
        let skip = bits & 8 != 0;
        let mirror_skip = bits & 16 != 0;
        for preparations in ["nil", "{}", "table.freeze { first, second }"] {
            let lua = setup();
            lua.load(HEADSET).exec().expect("headset facade");
            lua.load(format!(
                                "first, second, headset, window = {{}}, {{}}, {{}}, {{}}
                                local expected = {{}}
                                if {headset} and not {skip} then
                                    for _, pass in ipairs({preparations} or {{}}) do expected[#expected + 1] = pass end
                                    expected[#expected + 1] = headset
                                end
                                if {window} and not {mirror_skip} then expected[#expected + 1] = window end
                                lovr.headset.getPass = function() return {headset} and headset or nil end
                                lovr.graphics = {{
                                    getWindowPass = function() return {window} and window or nil end,
                                    submit = function(...)
                                        local actual = {{}}
                                        local firstArgument = ...
                                        if firstArgument and firstArgument ~= headset and firstArgument ~= window then
                                            assert(select('#', ...) == 1, 'table submission has no extra arguments')
                                            actual = firstArgument
                                        else
                                            for i = 1, select('#', ...) do
                                                local pass = select(i, ...)
                                                if pass then actual[#actual + 1] = pass end
                                            end
                                        end
                                        assert(#actual == #expected, 'submission pass count')
                                        for i, pass in ipairs(expected) do assert(actual[i] == pass, 'submission order') end
                                        submits = (submits or 0) + 1
                                    end,
                                    present = function() presents = (presents or 0) + 1 end,
                                    isTimingEnabled = function() return false end,
                                }}
                                lovr.draw = function(pass)
                                    assert(pass == headset)
                                    draws = (draws or 0) + 1
                                    return {skip}, {preparations}
                                end
                                lovr.mirror = function(pass) assert(pass == window); return {mirror_skip} end
                                expectedSubmits = #expected > 0 and 1 or 0"
                            ))
                            .exec()
                            .expect("ordered headset setup");
            let _cancel = if tracing {
                let listener = lua.load("return function() end").eval().expect("listener");
                Some(observe(&lua, Listener(listener)).expect("observer"))
            } else {
                None
            };
            lua.load(
                                "frame = lovr.run(); frame()
                                assert((submits or 0) == expectedSubmits, 'one graphics submission')
                                assert(headsetSubmits == 1 and presents == 1, 'presentation unchanged')",
                            )
                            .exec()
                            .expect("ordered headset frame");
        }
    }
}

#[test]
fn window_preparations_are_invocation_local_and_draw_veto_discards_them() {
    for skip in [false, true] {
        let lua = setup();
        lua.load(format!(
            "first, second, window = {{}}, {{}}, {{}}
            drawCalls = 0
            lovr.graphics = {{
                getWindowPass = function() return window end,
                submit = function(...)
                    submits = (submits or 0) + 1
                    if drawCalls == 1 then
                        local passes = ...
                        assert(select('#', ...) == 1 and #passes == 3)
                        assert(passes[1] == first and passes[2] == second and passes[3] == window)
                    else
                        assert(select('#', ...) == 1 and (...) == window, 'no stale preparations')
                    end
                end,
                present = function() presents = (presents or 0) + 1 end,
            }}
            lovr.draw = function(pass)
                assert(pass == window)
                drawCalls += 1
                return {skip}, drawCalls == 1 and {{ first, second }} or nil
            end
            frame = lovr.run(); frame(); frame()
            lovr.draw = nil; frame()
            assert((submits or 0) == ({skip} and 1 or 3))
            assert(presents == 3)"
        ))
        .exec()
        .expect("window preparations and veto");
    }
}

#[test]
fn callback_reacquisition_survives_old_cancel_and_error_and_records_are_readonly() {
    let lua = setup();
    let acquire = lua
        .create_function(|lua, ()| {
            clear(lua)?;
            let listener = lua
                .load("return function() replacement = true end")
                .eval()?;
            observe(lua, Listener(listener)).map(|_| ())
        })
        .expect("acquire");
    lua.globals()
        .set("acquire", acquire)
        .expect("acquire global");
    let listener = lua.load("return function(row) assert(not pcall(function() row.update = 99 end)); acquire(); error('old observer') end")
        .eval().expect("listener");
    let old_cancel = observe(&lua, Listener(listener)).expect("observer");
    lua.load("frame = lovr.run(); frame()")
        .exec()
        .expect("frame");
    assert!(publish(&lua, None).is_err());
    old_cancel.0.call::<()>(()).expect("old cancel");
    assert!(active(&lua).expect("replacement active"));
    lua.load("frame()").exec().expect("replacement frame");
    publish(&lua, None).expect("replacement publish");
    assert!(
        lua.globals()
            .get::<bool>("replacement")
            .expect("replacement callback")
    );
}
