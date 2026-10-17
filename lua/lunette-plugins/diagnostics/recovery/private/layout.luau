-- Lays out the recovery panel in logical units, from the top-left corner, and answers which action a point hits.
-- The layout reserves a row for every error the settings allow, so the buttons stay put while errors arrive.

local layout = {}

export type ActionId = 'appearance' | 'reload' | 'restore' | 'without-saved' | 'safe-mode'

export type Action = {
  read id: ActionId,
  read label: string,
  read enabled: boolean,
  -- Why a disabled action is disabled.
  read note: string?,
}

export type Content = {
  read reason: string,
  read errors: { read [number]: string },
  read status: string?,
  read actions: { read [number]: Action },
}

export type Rect = {
  read x: number,
  read y: number,
  read width: number,
  read height: number,
}

export type Line = {
  read text: string,
  read x: number,
  read y: number,
  read size: number,
}

export type PlacedAction = {
  read action: Action,
  read rect: Rect,
}

export type Layout = {
  read width: number,
  read height: number,
  read lines: { read [number]: Line },
  read actions: { read [number]: PlacedAction },
}

export type Limits = {
  read recentErrors: number,
  read columns: number,
}

layout.WIDTH = 1000

local PADDING = 30
local TITLE = 54
local ROW = 40
local ERROR_ROW = 32
local GAP = 16
local BUTTON = 76
local BUTTON_GAP = 14
-- Every panel lists the same actions, so the height does not depend on the content.
local ACTIONS = 5

-- The first line of `text`, cut to `columns` characters with an ellipsis. Invalid UTF-8 is cut by bytes.
function layout.clip(text: string, columns: number): string
  local first = text:match '^[^\n]*' or ''
  local length = utf8.len(first)
  if length == nil then
    return if #first > columns then first:sub(1, math.max(columns - 1, 0)) .. '…' else first
  end
  if length <= columns then
    return first
  end
  local cut = utf8.offset(first, columns) or (#first + 1)
  return first:sub(1, cut - 1) .. '…'
end

function layout.height(limits: Limits): number
  return PADDING
    + TITLE
    + ROW
    + ROW
    + limits.recentErrors * ERROR_ROW
    + GAP
    + ACTIONS * (BUTTON + BUTTON_GAP)
    + ROW
    + PADDING
end

function layout.build(content: Content, limits: Limits): Layout
  local lines: { Line } = {}
  local inner = layout.WIDTH - 2 * PADDING
  local y = PADDING
  lines[#lines + 1] = { text = 'Recovery', x = PADDING, y = y + TITLE / 2, size = 40 }
  y += TITLE
  lines[#lines + 1] = { text = layout.clip(content.reason, limits.columns), x = PADDING, y = y + ROW / 2, size = 26 }
  y += ROW
  local errors = content.errors
  lines[#lines + 1] = {
    text = if #errors == 0 then 'No errors reported.' else 'Recent errors, newest first:',
    x = PADDING,
    y = y + ROW / 2,
    size = 24,
  }
  y += ROW
  for index = 1, math.min(#errors, limits.recentErrors) do
    lines[#lines + 1] = {
      text = layout.clip(errors[index], limits.columns),
      x = PADDING,
      y = y + (index - 0.5) * ERROR_ROW,
      size = 20,
    }
  end
  y += limits.recentErrors * ERROR_ROW + GAP

  local placed: { PlacedAction } = {}
  for index = 1, math.min(#content.actions, ACTIONS) do
    placed[#placed + 1] = {
      action = content.actions[index],
      rect = { x = PADDING, y = y, width = inner, height = BUTTON },
    }
    y += BUTTON + BUTTON_GAP
  end
  y = PADDING + TITLE + 2 * ROW + limits.recentErrors * ERROR_ROW + GAP + ACTIONS * (BUTTON + BUTTON_GAP)
  local status = content.status
  if status then
    lines[#lines + 1] = { text = layout.clip(status, limits.columns), x = PADDING, y = y + ROW / 2, size = 24 }
  end

  return {
    width = layout.WIDTH,
    height = layout.height(limits),
    lines = lines,
    actions = placed,
  }
end

function layout.inside(rect: Rect, x: number, y: number): boolean
  return x >= rect.x and x <= rect.x + rect.width and y >= rect.y and y <= rect.y + rect.height
end

-- The action under a point, enabled or not.
function layout.hit(placed: Layout, x: number, y: number): Action?
  for _, entry in placed.actions do
    if layout.inside(entry.rect, x, y) then
      return entry.action
    end
  end
  return nil
end

return layout
