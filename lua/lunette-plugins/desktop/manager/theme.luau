-- Holds the manager's custom-drawing face until replacement measurements are ready.
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
  read withFont: ((Font, theme.Theme) -> ()) -> (),
  read destroy: () -> (),
}

function styles.draw(style: Style, pass: Pass, visual: ui.Theme, run: (draw.Style) -> ()): ()
  style.withFont(function(_font: Font, tokens: theme.Theme): ()
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
  end)
end

function styles.new(service: theme.Service, owner: plugin.Context): Style
  local applied = service:current()
  local lease = service:acquireFont(owner, applied.theme.typography.font)
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
    local nextLease: theme.FontLease? = nil
    local ok, failure = pcall(function(): ()
      local acquired = service:acquireFont(owner, candidate.theme.typography.font)
      nextLease = acquired
      local publish: (() -> ())? = nil
      acquired:withFont(function(font: Font): ()
        if prepare then
          publish = prepare(applied.theme, candidate.theme, font)
        end
      end)
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
      local acquired = nextLease
      if acquired then
        local released, releaseFailure = pcall(acquired.dispose, acquired)
        if not released then
          error(tostring(failure) .. '; manager theme cleanup: ' .. tostring(releaseFailure), 0)
        end
      end
      error(failure, 0)
    end
    local previous = lease
    assert(nextLease, 'manager theme: the replacement face was not acquired')
    applied, lease = candidate, nextLease
    previous:dispose()
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
    withFont = function(run: (Font, theme.Theme) -> ()): ()
      local captured, tokens = lease, applied.theme
      captured:withFont(function(font: Font): ()
        run(font, tokens)
      end)
    end,
    destroy = function(): ()
      if not dead then
        dead = true
        lease:dispose()
      end
    end,
  }
end

return styles
