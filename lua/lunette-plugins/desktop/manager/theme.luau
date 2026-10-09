-- Publishes the manager's theme tokens only after replacement measurements are ready.
local plugin = require '@lunette-plugin'
local theme = require '@lunette-contracts/theme'
local ui = require '@lunette-contracts/ui'
local draw = require './draw'

local styles = {}

export type Prepare = (theme.Theme, theme.Theme, Font) -> () -> ()
export type Style = {
  read current: () -> theme.Theme,
  read refresh: (Prepare?) -> (),
  read checkRefresh: () -> (),
  read destroy: () -> (),
}

function styles.draw(style: Style, pass: Pass, visual: ui.Theme, run: (draw.Style) -> ()): ()
  local tokens = style.current()
  local pushedState, pushedTransform = false, false
  local ok, failure = pcall(function(): ()
    pass:push 'state'
    pushedState = true
    pass:push 'transform'
    pushedTransform = true
    pass:setFont(visual.font)
    run { theme = tokens, visual = visual }
  end)
  if pushedTransform then
    local restored, restoreFailure = pcall(pass.pop, pass, 'transform')
    if ok and not restored then
      ok, failure = false, restoreFailure
    end
  end
  if pushedState then
    local restored, restoreFailure = pcall(pass.pop, pass, 'state')
    if ok and not restored then
      ok, failure = false, restoreFailure
    end
  end
  if not ok then
    error(failure, 0)
  end
end

function styles.new(service: theme.Service, owner: plugin.Context): Style
  local applied = service:current()
  local dead, refreshing = false, false
  local preparingRevision: number? = nil
  local refresh: (Prepare?) -> ()
  refresh = function(prepare: Prepare?): ()
    if dead or refreshing or not owner:active() then
      return
    end
    local candidate = service:current()
    if dead or not owner:active() or candidate.revision == applied.revision then
      return
    end
    refreshing = true
    preparingRevision = candidate.revision
    local ok, failure = pcall(function(): ()
      local publish: (() -> ())? = nil
      if prepare then
        publish = prepare(applied.theme, candidate.theme, service:font(candidate.theme.typography.font))
      end
      assert(not dead and owner:active(), 'manager theme: the owner is inactive')
      assert(service:current().revision == candidate.revision, 'manager theme: the revision changed during preparation')
      if publish then
        publish()
      end
      assert(not dead and owner:active(), 'manager theme: the owner became inactive during publication')
      assert(service:current().revision == candidate.revision, 'manager theme: the revision changed during publication')
    end)
    refreshing = false
    preparingRevision = nil
    if not ok then
      error(failure, 0)
    end
    applied = candidate
  end
  return {
    current = function(): theme.Theme
      return applied.theme
    end,
    refresh = refresh,
    checkRefresh = function(): ()
      assert(not dead and owner:active(), 'manager theme: the owner is inactive')
      assert(service:current().revision == preparingRevision, 'manager theme: the revision changed during publication')
    end,
    destroy = function(): ()
      dead = true
    end,
  }
end

return styles
