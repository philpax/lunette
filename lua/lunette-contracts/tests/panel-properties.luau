-- Covers lua/lunette-contracts/panel-properties.luau: the shared value and the store's identity encoding.

local testing = require '@testing'
local expect = testing.expect
local panelProperties = require '@lunette-contracts/panel-properties'

local test = testing.suite()

test('an identity round-trips through its map key', function()
  local ids: { panelProperties.PanelId } = {
    { kind = 'window', appId = 'org.example.Terminal', slot = 2 },
    { kind = 'monitor', key = 'Acme X24 on DP-1', slot = 1 },
    { kind = 'toolkit', name = 'desktop/decorations/window/7' },
  }
  for _, id in ids do
    local key = panelProperties.encodeId(id)
    local decoded = panelProperties.decodeId(key)
    expect.truthy(decoded, key)
    expect.equal(decoded.kind, id.kind, key)
    if id.kind == 'window' then
      expect.equal(decoded.appId, id.appId, key)
      expect.equal(decoded.slot, id.slot, key)
    elseif id.kind == 'monitor' then
      expect.equal(decoded.key, id.key, key)
      expect.equal(decoded.slot, id.slot, key)
    else
      expect.equal(decoded.name, id.name, key)
    end
  end
end)

test('separators in an identifier stay inside its segment', function()
  local key = panelProperties.encodeId { kind = 'window', appId = 'a/b:c@d#e%f', slot = 3 }
  expect.falsy(string.find(key, 'a/b', 1, true), key)
  local decoded = panelProperties.decodeId(key)
  expect.equal(decoded.appId, 'a/b:c@d#e%f', key)
end)

test('an unknown or malformed key names no panel', function()
  for _, key in { '', 'toolkit', 'window/name', 'window/name/0', 'window/name/1.5', 'desktop/name/1', 'toolkit/%ZZ' } do
    expect.falsy(panelProperties.decodeId(key), key)
  end
end)

test('the shared value copies each family read and compares by value', function()
  local value = panelProperties.propertiesOf {
    curve = 0.25,
    curveAxis = 0.5,
    inputLocked = true,
    transformLocked = false,
  }
  expect.equal(value.curve, 0.25, 'the curve')
  expect.equal(value.curveAxis, 0.5, 'the axis')
  expect.truthy(value.inputLocked, 'the input lock')
  expect.falsy(value.transformLocked, 'the transform lock')
  expect.truthy(panelProperties.equal(value, panelProperties.propertiesOf(value)), 'the same value')
  expect.falsy(
    panelProperties.equal(
      value,
      panelProperties.propertiesOf {
        curve = 0.25,
        curveAxis = 0.5,
        inputLocked = true,
        transformLocked = true,
      }
    ),
    'a different lock'
  )
end)

return test
