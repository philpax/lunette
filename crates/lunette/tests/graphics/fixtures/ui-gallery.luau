-- Renders every page of the widget gallery in both modes, for review and as a check that each page draws.

local testing = require '@testing'
local uiHost = require '@lunette-contracts/ui-host'
local uiComponents = require '@lunette-contracts/ui-components'
local ui = require '@lunette-plugins/ui/react'
local render = require './support/ui'
local host = require '@testing/host'

-- The gallery's pages live in the development configuration, which bare module names resolve against.
host.useConfiguration 'dev'
local pages = (require :: any) 'plugins/ui-gallery/pages'
local test = testing.suite()

for _, mode in { 'dark', 'light' } do
  for _, page in pages.PAGES do
    test(`the {page.id} page renders in {mode} mode`, function()
      local scene = render.boot(
        { require('@lunette-plugins/ui/standard').definition },
        { uiComponents.capability },
        function(context: any)
          local host = context:require(uiHost.capability)
          host:setMode(mode :: any)
          local panel = host:newPanel(context, {
            name = 'gallery',
            width = 0.56,
            height = 0.5,
            pose = lovr.math.newMat4(),
          })
          ui.mount(panel, pages.Gallery { host = host, page = page.id }, {
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
    { uiComponents.capability },
    function(context: any)
      local host = context:require(uiHost.capability)
      local panel =
        host:newPanel(context, { name = 'curved', width = 0.56, height = 0.5, curve = 1.6, pose = lovr.math.newMat4() })
      ui.mount(panel, pages.Gallery { host = host, page = 'choices' }, {
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

return test
