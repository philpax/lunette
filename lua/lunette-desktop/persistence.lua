-- The desktop's saved arrangement, kept across this consumer's outages.
--
-- The module is a definition factory. Each definition it makes creates one
-- persistence state from `@lunette-desktop/persist`, outside any activation, so
-- the loaded arrangement, the slots live windows hold, and a refusal to
-- overwrite an unreadable or newer file survive the consumer being disabled
-- and enabled again. Each activation binds the state: the arrangement becomes
-- a rules source, a drop heard through lunette/drops saves it, and a normal
-- quit saves it once more. A drop save that fails is logged; a quit save that
-- fails raises, and the frame provider reports it without vetoing the quit.
-- The consumer takes no options.
local plugin = require '@lunette-plugin'
local drops = require '@lunette-contracts/drops'
local frame = require '@lunette-contracts/frame'
local panels = require '@lunette-contracts/panels'
local rules = require '@lunette-contracts/rules'
local tags = require '@lunette-contracts/tags'
local logging = require '@lunette-desktop/logging'
local persist = require '@lunette-desktop/persist'

local required: plugin.Declaration = {
  drops = drops.capability,
  frame = frame.capability,
  panels = panels.capability,
  rules = rules.capability,
  tags = tags.capability,
}

local function define(): plugin.Definition<{}>
  local arrangement = persist.new()
  return plugin.define {
    name = 'desktop/persistence',
    requires = required,
    init = function(context: plugin.Context, config: {}, _publish: plugin.Publisher): ()
      -- The consumer takes no options, so any option is a mistake worth naming.
      plugin.options { name = 'desktop/persistence', defaults = {}, config = config }
      local frameService: frame.Service = context:require(frame.capability)
      local binding = arrangement:bind(
        context,
        context:require(panels.capability),
        context:require(tags.capability),
        context:require(rules.capability)
      )
      local dropService: drops.Service = context:require(drops.capability)
      dropService:onDropped(context, {
        run = function(_drop: drops.Drop): ()
          if not binding:active() then
            return
          end
          local written, message = binding:save()
          if not written and message then
            logging.report(message, 'warn')
          end
        end,
      })
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
    end,
  }
end

return define
