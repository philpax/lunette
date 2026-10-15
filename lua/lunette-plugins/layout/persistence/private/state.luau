-- The loaded arrangement and the window slots persist across provider activations. Each binding's source and
-- listeners end with its activation.

local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local arrangementContract = require '@lunette-contracts/arrangement'
local panelsContract = require '@lunette-contracts/panels'
local rulesContract = require '@lunette-contracts/rules'
local tagsContract = require '@lunette-contracts/tags'
local vocabulary = require '@lunette-contracts/vocabulary'
local format = require './format'
local logging = require '@lunette-plugins/diagnostics/desktop-logging'
local slots = require './slots'
local capture = require './capture'

local state = {}

export type State = {
  read bind: (
    State,
    plugin.Context,
    panelsContract.Service,
    tagsContract.Service,
    rulesContract.Service
  ) -> arrangementContract.Service,
}

state.FILE = 'arrangement.state'

local function report(message: string): ()
  logging.report(message, 'warn')
end

function state.new(file: string): State
  local path = lovr.filesystem.getSaveDirectory() .. '/' .. file
  local text: string? = lovr.filesystem.read(file)
  local arrangement: format.File = { entries = {} }
  -- A refused file is left alone: saving over it would discard what this version cannot read.
  local declined: string? = nil
  if text then
    local loaded = format.read(text)
    if loaded.kind == 'arrangement' then
      arrangement = loaded.file
      for _, message in ipairs(loaded.skipped) do
        report(message)
      end
    elseif loaded.kind == 'broken' then
      declined = path .. ' could not be read: ' .. loaded.message .. ', so it is left alone'
      report(declined)
    else
      declined = path
        .. ' was written by version '
        .. loaded.found
        .. ', and this lunette writes version '
        .. format.VERSION
        .. ', so it is left alone'
      report(declined)
    end
  end
  -- Held slots keep live windows on their slots across provider outages.
  local held = slots.new()

  -- Each unmatched entry is reported once per loaded or saved arrangement.
  local reportedStale: { [format.Entry]: boolean } = setmetatable({} :: { [format.Entry]: boolean }, { __mode = 'k' })
  local function restore(context: plugin.Context, panels: panelsContract.Service, tags: tagsContract.Service): number
    local restored, stale = capture.restore(held, context, panels, tags, arrangement)
    for _, entry in ipairs(stale) do
      if not reportedStale[entry] then
        reportedStale[entry] = true
        report('nothing matched the saved ' .. entry.kind .. " '" .. entry.key .. "'")
      end
    end
    return #restored
  end

  return {
    bind = function(
      _self: State,
      context: plugin.Context,
      panels: panelsContract.Service,
      tags: tagsContract.Service,
      rules: rulesContract.Service
    ): arrangementContract.Service
      rules:addSource(context, {
        name = 'desktop.persist',
        precedence = vocabulary.PRECEDENCE.persisted,
        resolve = function(window: lunette.Window): rulesContract.Properties?
          return capture.answer(capture.slotsFor(arrangement), held, window)
        end,
      })
      restore(context, panels, tags)
      panels:onAdded(context, {
        run = function(target: panelsContract.Panel)
          capture.arrived(held, context, panels, tags, arrangement, target)
        end,
      })
      return {
        save = function(_service: arrangementContract.Service): (boolean, string?)
          if not context:active() then
            return false, 'arrangement save: the provider is inactive'
          end
          if declined then
            return false, declined
          end
          local captured = capture.capture(held, panels, tags)
          if not lovr.filesystem.write(file, format.render(captured)) then
            return false, path .. ' could not be written'
          end
          arrangement = captured
          return true, nil
        end,
        restore = function(_service: arrangementContract.Service): number
          if not context:active() then
            return 0
          end
          return restore(context, panels, tags)
        end,
      }
    end,
  }
end

return state
