local testing = require '@testing'
local expect = testing.expect
local fixture = require './support/display'
local test = testing.suite()

for _, name in { 'built-in', 'tiny', 'split', 'rounded' } do
  test(name .. ' reuses one keyboard and publishes the same display transitions', function()
    local entry = 'keyboard'
    if name ~= 'built-in' then
      testing.host.useConfiguration 'examples/keyboard'
      entry = { id = 'keyboard', definition = require(name) }
    end
    local env = fixture.start { keyboard = entry }
    local changes = {}
    env.display.service:onChanged(env.display.context, {
      run = function(change)
        changes[#changes + 1] = change
      end,
    })
    expect.truthy(env.first:focus())
    local board = fixture.shown(env)
    expect.truthy(board)
    expect.truthy(board:typeText '!')
    expect.equal(env.first:value(), 'draft!')
    expect.truthy(env.second:focus())
    expect.equal(fixture.shown(env), board)
    expect.equal(#changes, 1, 'a field change does not duplicate the visibility notification')
    expect.truthy(env.display.service:hide())
    expect.equal(env.focus:focused(), nil)
    expect.truthy(env.display.service:show())
    expect.equal(fixture.shown(env), board)
    expect.equal(fixture.boardCount(env), 1)
    expect.equal(changes[1].reason, 'show')
    expect.equal(changes[2].reason, 'hide')
    expect.equal(changes[3].reason, 'show')
    expect.truthy(changes[3].revision > changes[2].revision)
    env.session:update()
    env.session:draw()
    env.session:close()
  end)
end

return test
