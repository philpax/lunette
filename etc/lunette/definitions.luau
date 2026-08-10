-- Type definitions for the globals mullion and the shipped configuration see
-- at runtime. `luau-analyze` reads this via --definitions so that `lovr`,
-- `lunette`, and the standard globals resolve instead of being reported as
-- unknown globals.
--
-- These are the shapes the tree actually uses; the source of truth for the
-- `lunette` API is the Rust `register_lunette` surface, and this file is kept
-- in step with it by hand until that surface generates definitions.

declare lunette: {
    windows: () -> { any },
    spawn: (command: string) -> any,
    newSeat: (name: string) -> any,
    seats: () -> { any },
    scaleSteps: () -> { number },
    reload: () -> (boolean, string?),
    claimLayer: (layer: any) -> any,
}

declare lovr: {
    math: {
        vec3: (...number) -> any,
        mat4: (...any) -> any,
        quat: (...number) -> any,
    },
    graphics: any,
    filesystem: {
        read: (string) -> string?,
        write: (string, string) -> boolean,
        getSource: (string) -> string?,
        getSaveDirectory: () -> string?,
    },
    timer: any,
    keypressed: (key: string, scancode: string, isrepeat: boolean) -> (),
    textinput: (text: string) -> (),
    update: (dt: number) -> (),
    draw: () -> (),
    load: (arg: any) -> (),
    conf: any,
    errhand: any,
    quit: () -> (),
    headset: any,
    system: any,
    lun: any,
    lunerror: any,
    lunlayergranted: any,
    lunprocessexited: any,
    lunwindowclosed: any,
    lunwindowopened: any,
}

declare io: {
    open: (string, string?) -> any,
    lines: (string) -> { string },
    write: (...any) -> (),
}

declare arg: { string }
declare print: (...any) -> ()
declare pcall: any
declare xpcall: any
declare ipairs: any
declare pairs: any
declare select: any
declare type: any
declare tostring: any
declare tonumber: any
declare error: any
declare require: any
declare setfenv: any
declare getfenv: any
declare loadstring: any
declare unpack: any
declare rawequal: any
declare rawget: any
declare rawset: any
declare next: any
declare coroutine: any
declare os: any
declare table: any
declare string: any
declare math: any