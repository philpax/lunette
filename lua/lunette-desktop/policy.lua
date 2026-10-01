-- Window placement with persistent state outside provider activations.
local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local panels = require '@lunette-contracts/panels'
local tags = require '@lunette-contracts/tags'
local rules = require '@lunette-contracts/rules'
local adoption = require '@lunette-contracts/adoption'
local layout = require '@lunette-contracts/layout'
local frame = require '@lunette-contracts/frame'
local logging = require '@lunette-desktop/logging'
local persist = require '@mullion/persist'

local WORKSPACE = 'main'
local TERMINALS = { 'ghostty', 'foot', 'weston-terminal', 'alacritty', 'kitty', 'xterm' }
local required: plugin.Declaration = {
  panels = panels.capability,
  tags = tags.capability,
  rules = rules.capability,
  adoption = adoption.capability,
  arc = layout.arc,
  frame = frame.capability,
}

local function define(): plugin.Definition<{}>
  -- The state retains saved placement and write refusal through provider outages.
  local arrangement = persist.new()
  local attempted: lunette.Process? = nil
  local attempt = 0
  return plugin.define {
    name = 'desktop/policy',
    requires = required,
    init = function(context: plugin.Context, config: {}, _publish: plugin.Publisher): ()
      -- The consumer takes no options, so any option is a mistake worth naming.
      plugin.options { name = 'desktop/policy', defaults = {}, config = config }
      local frameService: frame.Service = context:require(frame.capability)
      local panelService: panels.Service = context:require(panels.capability)
      local tagService: tags.Service = context:require(tags.capability)
      local ruleService: rules.Service = context:require(rules.capability)
      local adoptionService: adoption.Service = context:require(adoption.capability)
      local arc: layout.ArcService = context:require(layout.arc)
      -- The workspace tag is this activation's own. A tag of that name held by
      -- another owner raises here rather than being borrowed without a say in
      -- its lifetime.
      local workspace = tagService:new(context, WORKSPACE, { selected = true })
      local unplaced: { panels.WindowPanel } = {}

      ruleService:setRules(context, {
        rules = {
          {
            match = { appId = 'firefox' },
            properties = {
              width = 2,
              pose = function()
                return lovr.math.newMat4():translate(-1.4, 1.5, -1.2):rotate(0.9, 0, 1, 0)
              end,
            },
          },
        },
      })
      local binding = arrangement:bind(context, panelService, tagService, ruleService)
      adoptionService:install(context)

      local function arrange(): ()
        local live: { panels.WindowPanel } = {}
        for _, existing in ipairs(unplaced) do
          if not existing.dead then
            live[#live + 1] = existing
          end
        end
        unplaced = live
        local targets: { layout.Panel } = {}
        local function add(target: layout.Panel): ()
          targets[#targets + 1] = target
        end
        for _, item in ipairs(unplaced) do
          if workspace:has(item) then
            add(item)
          end
        end
        arc:apply(targets)
      end
      adoptionService:start(context, {
        defaults = { tags = { WORKSPACE } },
        onPlaced = function(created: panels.WindowPanel, properties: adoption.Properties)
          _G.lunetteDemonstrationSpawned = true
          if properties.pose == nil then
            unplaced[#unplaced + 1] = created
          end
          arrange()
        end,
      })
      arrange()
      context:on {
        event = lunette.onWindowClosed,
        run = function()
          arrange()
        end,
      }
      frameService:onQuit(context, {
        run = function(): ()
          if not binding:active() then
            return
          end
          local written, message = binding:save()
          if not written then
            error('arrangement was not saved: ' .. tostring(message))
          end
        end,
      })

      local function spawnNext(): ()
        attempt += 1
        local program = TERMINALS[attempt]
        if not program then
          attempted = nil
          logging.report('no terminal emulator was found; start a client with WAYLAND_DISPLAY', 'warn')
          return
        end
        attempted = lunette.spawn { argv = { program } }
      end
      context:on {
        event = lunette.onProcessExited,
        run = function(event: lunette.ProcessExitedEvent)
          if not attempted or event.process.id ~= attempted.id then
            return
          end
          if event.outcome == 'spawnFailed' then
            spawnNext()
          else
            attempted = nil
          end
        end,
      }
      if not _G.lunetteDemonstrationSpawned then
        _G.lunetteDemonstrationSpawned = true
        spawnNext()
      end
    end,
  }
end

return define
