local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local panelsContract = require '@lunette-contracts/panels'
local rulesContract = require '@lunette-contracts/rules'
local tagsContract = require '@lunette-contracts/tags'
local persist = require '@lunette-desktop/persist'

local filesystem: persist.Filesystem = {
  read = function(_filename: string): string?
    return nil
  end,
  write = function(_filename: string, _text: string): boolean
    return true
  end,
  getSaveDirectory = function(): string
    return '/save'
  end,
}
local state: persist.State = persist.new { filesystem = filesystem }
local binding: persist.Binding? = nil
local consumer: plugin.Definition<{}> = plugin.define {
  name = 'consumer',
  requires = { panels = panelsContract.capability, tags = tagsContract.capability, rules = rulesContract.capability },
  init = function(context: plugin.Context, _config: {}, _publish: plugin.Publisher): ()
    binding = state:bind(
      context,
      context:require(panelsContract.capability),
      context:require(tagsContract.capability),
      context:require(rulesContract.capability)
    )
  end,
}
local function save(options: persist.SaveOptions?): (boolean, string?)
  local current = binding
  if not current then
    return false, 'desktop: persistence is not bound'
  end
  return current:save(options)
end
local function matches(window: lunette.Window): boolean
  local resolve = persist.source(state:arrangement())
  return resolve(window) ~= nil
end
return { state = state, consumer = consumer, save = save, matches = matches }
