-- Keeps the manual demonstration's log and public child-instance handles in one activation.
local plugin = require '@lunette-plugin'
local theme = require '@lunette-contracts/theme'
local inspection = require '@lunette-contracts/inspection'

local session = {}

export type Child = {
  read name: string,
  read instance: plugin.Instance<{}>,
}
export type Action = {
  read id: string,
  read label: string,
  read run: () -> (),
}
export type Session = {
  read context: plugin.Context,
  read themes: theme.Service,
  read actions: { Action },
  read log: (string) -> (),
  read check: (boolean, string) -> (),
  read child: (string, (plugin.Context) -> ()) -> Child,
  read action: (string, string, () -> (), (() -> ())?) -> (),
  read report: () -> string,
  read invocations: () -> number,
  read metadata: (inspection.Details) -> string,
}

function session.new(context: plugin.Context, themes: theme.Service): Session
  local lines: { string } = {}
  local children: { Child } = {}
  local actions: { Action } = {}
  local sequence = 0
  local status = 'Ready. Select an action, then run it. Errors occur only in marked actions.'
  local function log(message: string): ()
    sequence += 1
    table.insert(lines, tostring(sequence) .. ' ' .. message:gsub('[%z\1-\9\11-\31\127]', ' '))
    if #lines > 12 then
      table.remove(lines, 1)
    end
  end
  local function check(condition: boolean, message: string): ()
    log((if condition then 'OK ' else 'FAILED ') .. message)
    assert(condition, 'theme registration example: ' .. message)
  end
  local function metadata(details: inspection.Details): string
    local keys: { string } = {}
    for key in details do
      table.insert(keys, key)
    end
    table.sort(keys)
    local fields: { string } = {}
    for _, key in keys do
      table.insert(fields, key .. '=' .. tostring(details[key]))
    end
    return table.concat(fields, ' ')
  end
  local function invocations(): number
    local count = 0
    for _, entry in themes:inspect().registrations do
      local value = entry.details.invocations
      if entry.kind == 'hold' and type(value) == 'number' then
        count += value
      end
    end
    return count
  end
  return {
    context = context,
    themes = themes,
    actions = actions,
    log = log,
    check = check,
    metadata = metadata,
    invocations = invocations,
    child = function(name: string, start: (plugin.Context) -> ()): Child
      local definition = plugin.define<<{}>> {
        name = 'example/ui/theme-registration/' .. name,
        requires = { theme = theme.capability },
        init = function(owner: plugin.Context, _config: {}, _publish: plugin.Publisher): ()
          start(owner)
        end,
      }
      local child = { name = name, instance = context:child(definition, {}) }
      table.insert(children, child)
      log('Child ' .. name .. ' ' .. child.instance:state())
      return child
    end,
    action = function(id: string, label: string, run: () -> (), after: (() -> ())?): ()
      table.insert(actions, {
        id = id,
        label = label,
        run = function(): ()
          if not context:active() then
            return
          end
          local before = themes:current().revision
          log('Action: ' .. label)
          local ok, failure = pcall(run)
          local verified, verification = pcall(function(): ()
            if after then
              after()
            end
          end)
          status = label .. ': ' .. (if ok and verified then 'complete' else 'reported error')
          log('Revision ' .. tostring(before) .. ' -> ' .. tostring(themes:current().revision))
          if not ok then
            log('Error: ' .. tostring(failure))
            error(failure, 0)
          end
          if not verified then
            log('Verification: ' .. tostring(verification))
            error(verification, 0)
          end
        end,
      })
    end,
    report = function(): string
      local snapshot = themes:current()
      local observed = themes:inspect()
      local color = snapshot.theme.colors.background
      local states: { string } = {}
      for index = math.max(1, #children - 7), #children do
        local child = children[index]
        table.insert(states, child.name .. ':' .. child.instance:state())
      end
      local selected = 'none'
      local readers, listeners = 0, 0
      for _, entry in observed.registrations do
        if entry.kind == 'selection' and entry.details.selected == true then
          selected = metadata(entry.details)
        elseif entry.kind == 'hold' then
          readers += 1
        elseif entry.kind == 'listener' then
          listeners += 1
        end
      end
      return status
        .. '\nRevision '
        .. tostring(snapshot.revision)
        .. string.format('; background %.3f %.3f %.3f %.3f', color[1], color[2], color[3], color[4])
        .. '\nSelected: '
        .. selected
        .. '\nRegistrations '
        .. tostring(observed.logicalRegistrationCount)
        .. '; readers '
        .. tostring(readers)
        .. '; listeners '
        .. tostring(listeners)
        .. '; invocations '
        .. tostring(invocations())
        .. '\nChildren: '
        .. table.concat(states, ' ')
        .. '\n'
        .. table.concat(lines, '\n')
    end,
  }
end

return session
