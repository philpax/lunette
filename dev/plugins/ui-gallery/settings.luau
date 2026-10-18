-- The gallery's settings page in the plugin manager: the theme mode, shown when the manager selects the gallery.

local uiHost = require '@lunette-contracts/ui-host'
local theme = require '@lunette-contracts/theme'
local pluginManager = require '@lunette-contracts/plugin-manager'
local ui = require '@lunette-plugins/ui/react'

local settings = {}

local NAME = 'dev/ui-gallery'

-- The settings page reads the host's effective mode and changes it through the theme service.
function settings.page(host: uiHost.Service, themeService: theme.Service): (props: any?) -> ui.Child
  return ui.component('GallerySettings', function(props: pluginManager.SettingsProps): ui.Child
    local c = ui.useComponents()
    local mode, setMode = ui.useState(host:theme().mode)
    if props.name ~= NAME then
      return nil
    end
    return c.Column {
      key = 'gallery',
      gap = 'sm',
      c.Text {
        key = 'about',
        text = 'The widget gallery shows every standard kind. The theme mode applies to every toolkit panel.',
        style = 'caption',
      },
      c.Segmented {
        key = 'mode',
        value = mode,
        options = { { id = 'dark', label = 'Dark' }, { id = 'light', label = 'Light' } },
        onChange = function(next: 'dark' | 'light')
          setMode(next)
          themeService:setMode(next)
        end,
      },
    }
  end)
end

return settings
