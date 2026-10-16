-- The gallery's pages, as components, so the development plugin and the snapshot fixtures render the same content.

local ui = require '@lunette-plugins/ui/react'
local uiHost = require '@lunette-contracts/ui-host'
local notifications = require '@lunette-contracts/notifications'

local pages = {}

export type Props = {
  host: uiHost.Service,
  page: string?,
  -- The overlays page opens dialogs over this panel, as this owner, and shows toasts when notifications are given.
  panel: uiHost.Panel?,
  owner: any?,
  components: any?,
  notifications: notifications.Service?,
}

local Services = ui.createContext(nil :: Props?)

local INTENSITY = {
  { value = 0, label = 'None' },
  { value = 0.25, label = 'Low' },
  { value = 0.5, label = 'Medium' },
  { value = 0.75, label = 'High' },
  { value = 1, label = 'Full' },
}

local ACCENTS = {
  { id = 'ice', label = 'Ice', color = { 0x9f / 255, 0xd3 / 255, 0xe6 / 255, 1 } },
  { id = 'amber', label = 'Amber', color = { 0xe8 / 255, 0xb8 / 255, 0x6a / 255, 1 } },
  { id = 'mint', label = 'Mint', color = { 0x8f / 255, 0xd6 / 255, 0xb0 / 255, 1 } },
  { id = 'rose', label = 'Rose', color = { 0xe6 / 255, 0x9a / 255, 0xb4 / 255, 1 } },
}

pages.PAGES = {
  { id = 'display', label = 'Display' },
  { id = 'actions', label = 'Actions' },
  { id = 'choices', label = 'Choices' },
  { id = 'values', label = 'Values' },
  { id = 'collections', label = 'Collections' },
  { id = 'structure', label = 'Structure' },
  { id = 'overlays', label = 'Overlays' },
}

local Display = ui.component('Display', function(): ui.Child
  local c = ui.useComponents()
  return c.Column {
    gap = 'md',
    c.Section {
      key = 'type',
      title = 'Type',
      c.Text { key = 'title', text = 'Title in IBM Plex Sans', style = 'title' },
      c.Text { key = 'heading', text = 'A heading for a group', style = 'heading' },
      c.Text {
        key = 'body',
        text = 'Body text wraps across lines at the width of its column, shaped natively and drawn from the same face.',
      },
      c.Text { key = 'caption', text = 'A caption gives secondary detail.', style = 'caption', color = 'muted' },
      c.Text { key = 'mono', text = '~/.config/lunette/main.luau', style = 'mono' },
    },
    c.Section {
      key = 'status',
      title = 'Status',
      c.Row {
        key = 'words',
        gap = 'lg',
        c.Text { key = 'running', text = 'Running', color = 'success' },
        c.Text { key = 'failed', text = 'Failed', color = 'danger' },
        c.Text { key = 'paused', text = 'Paused', color = 'muted' },
        c.Text { key = 'playing', text = 'Playing', color = 'accent' },
      },
      c.Progress { key = 'low', value = 0.3 },
      c.Progress { key = 'high', value = 0.75 },
    },
  }
end)

local Actions = ui.component('Actions', function(): ui.Child
  local c = ui.useComponents()
  local count, setCount = ui.useState(0)
  local filters, setFilters = ui.useState { windows = true, monitors = false, audio = true }
  local function filter(id: string, label: string): ui.Child
    return c.Chip {
      key = id,
      label = label,
      selected = filters[id],
      onChange = function(selected: boolean)
        local next = table.clone(filters)
        next[id] = selected
        setFilters(next)
      end,
    }
  end
  return c.Column {
    gap = 'md',
    c.Section {
      key = 'buttons',
      title = 'Buttons',
      c.Row {
        key = 'variants',
        gap = 'sm',
        c.Button {
          key = 'default',
          label = `Pressed {count}`,
          onActivate = function()
            setCount(count + 1)
          end,
        },
        c.Button { key = 'primary', label = 'Apply', variant = 'primary', onActivate = function() end },
        c.Button { key = 'quiet', label = 'Cancel', variant = 'quiet', onActivate = function() end },
        c.Button { key = 'disabled', label = 'Pin', disabledReason = 'Pinning needs the Attention source.' },
      },
    },
    c.Section {
      key = 'chips',
      title = 'Filters',
      c.Row {
        key = 'chips',
        gap = 'sm',
        filter('windows', 'Windows'),
        filter('monitors', 'Monitors'),
        filter('audio', 'Audio'),
      },
    },
  }
end)

local Choices = ui.component('Choices', function(): ui.Child
  local c = ui.useComponents()
  local enabled, setEnabled = ui.useState(true)
  local follow, setFollow = ui.useState(false)
  local source, setSource = ui.useState 'mix'
  local layout, setLayout = ui.useState 'arc'
  local density, setDensity = ui.useState 'comfortable'
  return c.Column {
    gap = 'md',
    c.Section {
      key = 'toggles',
      title = 'Toggles',
      c.Toggle { key = 'enabled', label = 'Backdrop', value = enabled, onChange = setEnabled },
      c.Toggle {
        key = 'follow',
        label = 'Follow gaze',
        detail = 'Panels turn to face the head.',
        value = follow,
        onChange = setFollow,
      },
      c.Checkbox { key = 'check', label = 'Show diagnostics', value = follow, onChange = setFollow },
      c.Toggle {
        key = 'disabled',
        label = 'Passthrough',
        value = false,
        disabledReason = 'The runtime has no passthrough.',
      },
    },
    c.Section {
      key = 'selection',
      title = 'Selection',
      c.Segmented {
        key = 'source',
        value = source,
        onChange = setSource,
        options = {
          { id = 'mix', label = 'System mix' },
          { id = 'pinned', label = 'Pinned' },
          { id = 'attention', label = 'Attention' },
        },
      },
      c.RadioGroup {
        key = 'density',
        value = density,
        onChange = setDensity,
        options = {
          { id = 'compact', label = 'Compact' },
          { id = 'comfortable', label = 'Comfortable' },
          { id = 'spacious', label = 'Spacious', detail = 'Larger targets for hands.' },
        },
      },
      c.Dropdown {
        key = 'layout',
        value = layout,
        onChange = setLayout,
        options = {
          { id = 'arc', label = 'Arc' },
          { id = 'grid', label = 'Grid' },
          { id = 'stack', label = 'Stack' },
        },
      },
    },
  }
end)

local Values = ui.component('Values', function(): ui.Child
  local c = ui.useComponents()
  local response, setResponse = ui.useState(0.75)
  local volume, setVolume = ui.useState(-12)
  return c.Column {
    gap = 'md',
    c.Section {
      key = 'sliders',
      title = 'Sliders',
      c.Slider {
        key = 'response',
        label = 'Response',
        value = response,
        detents = INTENSITY,
        onChange = setResponse,
      },
      c.Slider {
        key = 'volume',
        label = 'Volume',
        value = volume,
        min = -60,
        max = 0,
        step = 1,
        unit = 'dB',
        format = '%d',
        onChange = setVolume,
      },
      c.Slider {
        key = 'disabled',
        label = 'Motion',
        value = 0.5,
        detents = INTENSITY,
        disabledReason = 'Reduced motion is on.',
      },
    },
  }
end)

local APPLICATIONS = {
  { id = 'firefox', title = 'Firefox', detail = 'org.mozilla.firefox · #4120', trailing = 'Playing' },
  { id = 'foot', title = 'foot', detail = 'foot · #3388', trailing = 'Silent' },
  { id = 'mpv', title = 'mpv', detail = 'mpv · #5012', trailing = 'Paused' },
}

local Collections = ui.component('Collections', function(): ui.Child
  local c = ui.useComponents()
  local application, setApplication = ui.useState 'firefox'
  local plugin, setPlugin = ui.useState 'desktop/backdrop'
  return c.Column {
    gap = 'md',
    c.Section {
      key = 'list',
      title = 'Applications',
      c.List { key = 'applications', items = APPLICATIONS, value = application, onChange = setApplication },
    },
    c.Section {
      key = 'table',
      title = 'Plugins',
      c.Table {
        key = 'plugins',
        value = plugin,
        onChange = setPlugin,
        columns = {
          { id = 'name', label = 'Plugin' },
          { id = 'state', label = 'State' },
          { id = 'owner', label = 'Owner' },
        },
        rows = {
          { id = 'desktop/backdrop', cells = { 'desktop/backdrop', 'Running', 'desktop' } },
          { id = 'desktop/keyboard', cells = { 'desktop/keyboard', 'Running', 'desktop' } },
          { id = 'dev/ui-gallery', cells = { 'dev/ui-gallery', 'Running', 'dev' } },
        },
      },
    },
  }
end)

local Structure = ui.component('Structure', function(): ui.Child
  local c = ui.useComponents()
  local rows = {}
  for index = 1, 14 do
    rows[index] = c.ListRow { key = `row-{index}`, title = `Scrolling row {index}`, trailing = `#{index}` }
  end
  return c.Column {
    gap = 'md',
    c.Section {
      key = 'cards',
      title = 'Cards',
      c.Row {
        key = 'cards',
        gap = 'md',
        c.Card {
          key = 'left',
          grow = 1,
          c.Text { key = 'title', text = 'Raised card', style = 'label' },
          c.Text { key = 'body', text = 'Cards group related content.', style = 'caption', color = 'muted' },
        },
        c.Card {
          key = 'right',
          grow = 1,
          c.Text { key = 'title', text = 'Second card', style = 'label' },
          c.Separator { key = 'rule' },
          c.Text { key = 'body', text = 'With a rule inside.', style = 'caption', color = 'muted' },
        },
      },
    },
    c.Section {
      key = 'scroll',
      title = 'Scroll box',
      c.ScrollBox { key = 'box', height = 0.14, c.List { key = 'rows', rows } },
    },
  }
end)

local Confirm = ui.component('Confirm', function(props: { close: () -> () }): ui.Child
  local c = ui.useComponents()
  return c.Dialog {
    title = 'Remove the plugin?',
    actions = {
      { id = 'cancel', label = 'Cancel', variant = 'quiet', onActivate = props.close },
      { id = 'remove', label = 'Remove', variant = 'primary', onActivate = props.close },
    },
    c.Text { key = 'body', text = 'Its settings are kept, and it can be added again from the catalogue.' },
  }
end)

local Overlays = ui.component('Overlays', function(): ui.Child
  local c = ui.useComponents()
  local services = ui.useContext(Services)
  local count, setCount = ui.useState(0)
  local function openDialog(modality: 'panel' | 'session'): ()
    if not services or not services.owner then
      return
    end
    local dialog = services.host:newPanel(services.owner, {
      name = `gallery dialog {count}`,
      presentation = 'dialog',
      parent = if modality == 'panel' then services.panel else nil,
      modality = modality,
    })
    setCount(count + 1)
    ui.mount(
      dialog,
      Confirm {
        close = function()
          dialog:destroy()
        end,
      },
      { components = services.components, owner = services.owner }
    )
  end
  local notifier = services and services.notifications
  return c.Column {
    gap = 'md',
    c.Section {
      key = 'dialogs',
      title = 'Dialogs',
      c.Row {
        key = 'buttons',
        gap = 'sm',
        c.Button {
          key = 'panel',
          label = 'Open a dialog',
          onActivate = function()
            openDialog 'panel'
          end,
        },
        c.Button {
          key = 'session',
          label = 'Session dialog',
          onActivate = function()
            openDialog 'session'
          end,
        },
      },
    },
    c.Section {
      key = 'toasts',
      title = 'Toasts',
      c.Row {
        key = 'buttons',
        gap = 'sm',
        c.Button {
          key = 'info',
          label = 'Show a toast',
          disabledReason = if notifier then nil else 'No notifications provider is loaded.',
          onActivate = function()
            if notifier and services then
              notifier:notify(services.owner, {
                title = 'Screenshot saved',
                body = '~/Pictures/lunette-2026-10-16.png',
                actions = { { id = 'open', label = 'Open', run = function() end } },
              })
            end
          end,
        },
        c.Button {
          key = 'error',
          label = 'Show an error',
          disabledReason = if notifier then nil else 'No notifications provider is loaded.',
          onActivate = function()
            if notifier and services then
              notifier:notify(
                services.owner,
                { title = 'Capture failed', body = 'The portal refused.', level = 'error' }
              )
            end
          end,
        },
      },
    },
    c.Section {
      key = 'menus',
      title = 'Menus',
      c.Text {
        key = 'hint',
        text = 'Menus open as overlays and reach past the panel.',
        style = 'caption',
        color = 'muted',
      },
      c.Dropdown {
        key = 'long',
        value = 'option-1',
        options = {
          { id = 'option-1', label = 'First option' },
          { id = 'option-2', label = 'Second option' },
          { id = 'option-3', label = 'Third option' },
          { id = 'option-4', label = 'Fourth option' },
          { id = 'option-5', label = 'Fifth option' },
          { id = 'option-6', label = 'Sixth option' },
        },
      },
    },
  }
end)

local PAGE_COMPONENTS = {
  display = Display,
  actions = Actions,
  choices = Choices,
  values = Values,
  collections = Collections,
  structure = Structure,
  overlays = Overlays,
}

-- The whole gallery: a header with the theme controls, page tabs, and the page in a scroll box.
pages.Gallery = ui.component('Gallery', function(props: Props): ui.Child
  local c = ui.useComponents()
  local page, setPage = ui.useState(props.page or 'display')
  local mode, setMode = ui.useState(props.host:theme().mode)
  local accent, setAccent = ui.useState 'ice'
  local swatches = {}
  for _, choice in ACCENTS do
    swatches[#swatches + 1] = c.Chip {
      key = choice.id,
      label = choice.label,
      selected = accent == choice.id,
      onChange = function()
        setAccent(choice.id)
        props.host:setAccent(choice.color)
      end,
    }
  end
  local tabs = {}
  for _, entry in pages.PAGES do
    local Page = PAGE_COMPONENTS[entry.id]
    tabs[#tabs + 1] = c.ScrollBox { key = entry.id, grow = 1, Page {} }
  end
  return ui.provide(
    Services,
    props :: Props?,
    c.Panel {
      c.Header {
        key = 'header',
        title = 'Widget gallery',
        detail = 'lunette theme',
      },
      c.Body {
        key = 'body',
        grow = 1,
        c.Row {
          key = 'theme',
          gap = 'sm',
          align = 'center',
          c.Segmented {
            key = 'mode',
            value = mode,
            options = { { id = 'dark', label = 'Dark' }, { id = 'light', label = 'Light' } },
            onChange = function(next: 'dark' | 'light')
              setMode(next)
              props.host:setMode(next)
            end,
          },
          c.Spacer { key = 'gap' },
          swatches,
        },
        c.Tabs { key = 'pages', tabs = pages.PAGES, value = page, onChange = setPage, grow = 1, tabs },
      },
    }
  )
end)

return pages
