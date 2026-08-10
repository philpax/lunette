-- The `lunette` module as the type checker sees it. At runtime this is
-- registered by the host; for static checking it is a stub whose surface
-- matches what `require 'lunette'` returns. It intentionally does not run.
--
-- The source of truth for the API shape is the Rust registration surface;
-- this file is kept in step with it by hand until that surface generates the
-- definitions.

export type Seat = { dead: boolean, name: string }
export type Window = { dead: boolean, title: string? }

local lunette = {
    windows = function(): { Window }
        return {}
    end,
    spawn = function(_: string): any
        return nil
    end,
    newSeat = function(_: string): Seat
        return { dead = false, name = '' }
    end,
    seats = function(): { Seat }
        return {}
    end,
    scaleSteps = function(): { number }
        return {}
    end,
    reload = function(): (boolean, string?)
        return true, nil
    end,
    claimLayer = function(_: any): any
        return nil
    end,
}

return lunette