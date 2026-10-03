-- Frame pacing for the panels in the scene: each frame, every window panel's pacer is given what was
-- observed, and a changed rate is applied with `window:setFrameRate`.
--
-- Commits are observed only while a window is unthrottled, because a throttled client's commits describe
-- the throttle and would end a video's exemption a second after its panel was hidden. A hidden monitor
-- panel's capture is paused while `pauseMonitors` holds. Unloading unthrottles and resumes everything this
-- activation changed.
local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local frame = require '@lunette-contracts/frame'
local panels = require '@lunette-contracts/panels'
local pacing = require '@lunette-contracts/pacing'

-- What a configuration gives: every option optional.
export type Config = {
  read pauseMonitors: boolean?,
}

export type Settings = {
  read pauseMonitors: boolean,
}

local DEFAULTS: Settings = { pauseMonitors = true }

-- One paced window: its handle, its pacer, the commit read on the previous
-- frame, and the rate last applied, nil while unthrottled.
type Paced = {
  window: lunette.Window,
  pacer: pacing.Pacer,
  commit: number?,
  rate: number?,
}

local required: plugin.Declaration = {
  frame = frame.capability,
  panels = panels.capability,
  pacing = pacing.capability,
}

return plugin.define {
  name = 'desktop/pacing',
  requires = required,
  init = function(context: plugin.Context, config: Config, _publish: plugin.Publisher): ()
    local settings: Settings = plugin.options { name = 'desktop/pacing', defaults = DEFAULTS, config = config }
    local frameService: frame.Service = context:require(frame.capability)
    local panelService: panels.Service = context:require(panels.capability)
    local pacingService: pacing.Service = context:require(pacing.capability)
    local paced: { [number]: Paced } = {}
    local paused: { [string]: lunette.Monitor } = {}

    local function track(window: lunette.Window): Paced
      local entry: Paced = { window = window, pacer = pacingService:newPacer(), commit = nil, rate = nil }
      paced[window.id] = entry
      return entry
    end

    local function apply(entry: Paced, rate: number?): ()
      if rate ~= entry.rate then
        entry.window:setFrameRate(rate)
        entry.rate = rate
      end
    end

    local function release(id: number, entry: Paced): ()
      paced[id] = nil
      if entry.rate ~= nil and not entry.window.dead then
        entry.window:setFrameRate(nil)
      end
    end

    local function resume(id: string, monitor: lunette.Monitor): ()
      paused[id] = nil
      if not monitor.dead then
        monitor:setPaused(false)
      end
    end

    local function paceWindow(panel: panels.Panel, window: lunette.Window, seen: { [number]: boolean }): ()
      if window.dead then
        return
      end
      seen[window.id] = true
      local entry: Paced = paced[window.id] or track(window)
      local commit = window.commit
      local drew: boolean? = nil
      if entry.rate == nil and entry.commit ~= nil then
        drew = commit ~= entry.commit
      end
      entry.commit = commit
      local rate = entry.pacer:observe { visible = not panel.hidden, contentType = window.contentType, drew = drew }
      apply(entry, rate)
    end

    local function pauseMonitor(panel: panels.Panel, monitor: lunette.Monitor, shown: { [string]: boolean }): ()
      if monitor.dead then
        return
      end
      shown[monitor.id] = true
      if panel.hidden then
        if not paused[monitor.id] and monitor:setPaused(true) then
          paused[monitor.id] = monitor
        end
      elseif paused[monitor.id] then
        resume(monitor.id, monitor)
      end
    end

    frameService:onUpdate(context, {
      phase = 'overlay',
      run = function(_dt: number)
        local seen: { [number]: boolean } = {}
        local shown: { [string]: boolean } = {}
        for _, panel in ipairs(panelService:all()) do
          if panel.dead then
            continue
          end
          if panel.kind == 'window' then
            paceWindow(panel, panel.source, seen)
          elseif settings.pauseMonitors then
            pauseMonitor(panel, panel.source, shown)
          end
        end
        for id, entry in table.clone(paced) do
          if not seen[id] then
            release(id, entry)
          end
        end
        for id, monitor in table.clone(paused) do
          if not shown[id] then
            resume(id, monitor)
          end
        end
      end,
    })

    context:effect(function(): () -> ()
      return function(): ()
        for id, entry in table.clone(paced) do
          release(id, entry)
        end
        for id, monitor in table.clone(paused) do
          resume(id, monitor)
        end
      end
    end)
  end,
}
