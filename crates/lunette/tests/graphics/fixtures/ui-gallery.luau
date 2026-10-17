-- Renders every page of the widget gallery in both modes, for review and as a check that each page draws.

local testing = require '@testing'
local uiHost = require '@lunette-contracts/ui-host'
local theme = require '@lunette-contracts/theme'
local uiComponents = require '@lunette-contracts/ui-components'
local ui = require '@lunette-plugins/ui/react'
local render = require './support/ui'
local host = require '@testing/host'

-- The gallery's pages live in the development configuration, which bare module names resolve against.
host.useConfiguration 'dev'
local pages = (require :: any) 'plugins/ui-gallery/pages'
local settings = (require :: any) 'plugins/ui-gallery/settings'
local pluginManager = require '@lunette-contracts/plugin-manager'
local adapter = require '@lunette-plugin/adapter'
local test = testing.suite()

for _, mode in { 'dark', 'light' } do
  for _, page in pages.PAGES do
    test(`the {page.id} page renders in {mode} mode`, function()
      local scene = render.boot(
        { require('@lunette-plugins/ui/standard').definition },
        { uiComponents.capability, theme.capability },
        function(context: any)
          local host = context:require(uiHost.capability)
          local themeService = context:require(theme.capability)
          themeService:setMode(mode :: any)
          local panel = host:newPanel(context, {
            name = 'gallery',
            width = 0.56,
            height = 0.5,
            pose = lovr.math.newMat4(),
          })
          ui.mount(panel, pages.Gallery { host = host, theme = themeService, page = page.id }, {
            components = context:require(uiComponents.capability),
            owner = context,
          })
        end
      )
      scene.fixture:step()
      local image = render.render(scene, 900, 800, vector.pack(0, 0, 0.78), vector.pack(0, 0, 0))
      render.snapshot(`gallery-{page.id}-{mode}`, image)
      scene.fixture:close()
    end)
  end
end

test('a gallery page renders bent on a curved panel', function()
  local scene = render.boot(
    { require('@lunette-plugins/ui/standard').definition },
    { uiComponents.capability, theme.capability },
    function(context: any)
      local host = context:require(uiHost.capability)
      local themeService = context:require(theme.capability)
      local panel =
        host:newPanel(context, { name = 'curved', width = 0.56, height = 0.5, curve = 1.6, pose = lovr.math.newMat4() })
      ui.mount(panel, pages.Gallery { host = host, theme = themeService, page = 'choices' }, {
        components = context:require(uiComponents.capability),
        owner = context,
      })
    end
  )
  scene.fixture:step()
  render.snapshot('gallery-curved-front', render.render(scene, 900, 800, vector.pack(0, 0, 0.62), vector.pack(0, 0, 0)))
  render.snapshot(
    'gallery-curved-angled',
    render.render(scene, 900, 800, vector.pack(0.35, 0.12, 0.5), vector.pack(0, 0, 0))
  )
  scene.fixture:close()
end)

test('the gallery settings page renders in an attributed outlet frame', function()
  -- The contribution comes from a plugin named as the gallery, so the frame names it.
  local gallery = adapter.define {
    name = 'dev/ui-gallery',
    requires = { uiHost.capability, theme.capability, uiComponents.capability },
    init = function(context: adapter.Context)
      local host = context:require(uiHost.capability)
      local themeService = context:require(theme.capability)
      ui.contribute(context, pluginManager.settings, settings.page(host, themeService), {
        components = context:require(uiComponents.capability),
      })
    end,
  }
  local scene = render.boot(
    { require('@lunette-plugins/ui/standard').definition, gallery },
    { uiComponents.capability, theme.capability },
    function(context: any)
      local host = context:require(uiHost.capability)
      local c = context:require(uiComponents.capability)
      local panel =
        host:newPanel(context, { name = 'settings', width = 0.36, height = 0.2, pose = lovr.math.newMat4() })
      panel.root:bind {
        render = function()
          panel.root:submit(c.Panel {
            c.Body {
              key = 'body',
              c.Text { key = 'title', text = 'Configure', style = 'section' },
              c.Outlet {
                key = 'settings',
                outlet = pluginManager.settings,
                props = { entry = 'dev/ui-gallery', name = 'dev/ui-gallery' },
                maxHeight = 0.12,
              },
            },
          })
        end,
      }
    end
  )
  scene.fixture:step()
  render.snapshot('outlet-attributed', render.render(scene, 640, 360, vector.pack(0, 0, 0.42), vector.pack(0, 0, 0)))
  scene.fixture:close()
end)

return test
