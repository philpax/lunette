-- Drives the production consumer through a real runtime; only frame delivery and XR observations are local.

local testing = require '@testing'
local plugin = require '@lunette-plugin'
local frame = require '@lunette-contracts/frame'
local backdrop = require '@lunette-plugins/desktop/backdrop'
local model = require '@lunette-plugins/desktop/backdrop/model'
local cleanup = require '@lunette-plugins/lifecycle/cleanup'
local render = require './render'

local aurora = {}

export type Fixture = {
  session: testing.Session,
  factory: backdrop.Factory,
  state: model.State,
  context: plugin.Context,
  mainVisible: boolean,
  head: vector,
  updates: { { active: boolean, run: (number) -> () } },
  draws: { { active: boolean, run: (Pass) -> () } },
  texture: Texture,
  depth: Texture,
  pass: Pass,
}
local start: (backdrop.Config, { () -> () }) -> Fixture

function aurora.withFixture(options: backdrop.Config, run: (Fixture) -> ()): ()
  local previous = lovr.headset
  local current: Fixture? = nil
  local releases: { () -> () } = {}
  lovr.headset = {
    isMainSessionVisible = function(): boolean
      assert(current, 'frame observation before fixture setup')
      return current.mainVisible
    end,
    getPosition = function(_device: string): (number, number, number)
      assert(current, 'head observation before fixture setup')
      return vector.unpack(current.head)
    end,
    getDirection = function(_device: string): (number, number, number)
      return 0, 0, -1
    end,
  }
  local ok, failure = pcall(function(): ()
    current = start(options, releases)
    run(current)
  end)
  local closed, closeFailure = pcall(cleanup.run, 'aurora fixture', releases)
  lovr.headset = previous
  if not ok then
    error(tostring(failure) .. (if closed then '' else '\n' .. tostring(closeFailure)), 0)
  end
  assert(closed, closeFailure)
end

start = function(options: backdrop.Config, releases: { () -> () }): Fixture
  local current = {
    mainVisible = false,
    head = vector.pack(0, 0, 0),
    updates = {},
    draws = {},
  }
  local provider = plugin.provider<<{}, {}, frame.Service>> {
    name = 'graphics/frame',
    capability = frame.capability,
    build = function(context: plugin.Context): frame.Service
      return {
        onUpdate = function(_self: frame.Service, owner: plugin.Owner, handler: frame.UpdateHandler): plugin.Effect
          return context:acquire(owner, function(): () -> ()
            local entry = { active = true, run = handler.run }
            table.insert(current.updates, entry)
            return function(): ()
              entry.active = false
            end
          end)
        end,
        onDraw = function(_self: frame.Service, owner: plugin.Owner, handler: frame.DrawHandler): plugin.Effect
          testing.expect.equal(handler.phase, 'scene', 'production backdrop draw phase')
          testing.expect.equal(handler.order, -100, 'production backdrop precedes foreground')
          return context:acquire(owner, function(): () -> ()
            local entry = { active = true, run = handler.run }
            table.insert(current.draws, entry)
            return function(): ()
              entry.active = false
            end
          end)
        end,
      }
    end,
  }
  current.factory = backdrop.create(options, function(context: plugin.Context, state: model.State): ()
    current.state = state
    current.context = context
  end)
  current.session = testing.start {
    { id = 'graphics/frame', definition = provider.definition },
    { id = 'desktop/backdrop', definition = current.factory.definition },
  }
  table.insert(releases, function(): ()
    current.session:close()
  end)
  testing.expect.equal(current.session.instances['desktop/backdrop']:state(), 'active', 'production activation')
  current.texture = lovr.graphics.newTexture(192, 128, {
    format = 'rgba8',
    linear = true,
    samples = 1,
    mipmaps = false,
    usage = { 'render', 'transfer' },
  })
  table.insert(releases, function(): ()
    current.texture:release()
  end)
  current.depth = lovr.graphics.newTexture(192, 128, { format = 'd32f', usage = 'render', samples = 1 })
  table.insert(releases, function(): ()
    current.depth:release()
  end)
  current.pass = lovr.graphics.newPass { texture = current.texture, depth = current.depth, samples = 1 }
  table.insert(releases, function(): ()
    current.pass:release()
  end)
  return current
end

function aurora.update(current: Fixture, dt: number, mainVisible: boolean?): ()
  if mainVisible ~= nil then
    current.mainVisible = mainVisible
  end
  for _, entry in current.updates do
    if entry.active then
      entry.run(dt)
    end
  end
end

function aurora.prepare(current: Fixture): Pass
  local pass = current.pass
  pass:reset()
  pass:setCanvas { texture = current.texture, depth = current.depth, samples = 1 }
  pass:setClear(0, 0, 0, 0)
  -- LÖVR's default greater-or-equal depth test uses an infinite-far reverse-Z projection.
  pass:setProjection('perspective', math.rad(80), 192 / 128, 0.1, 0)
  pass:setViewPose(1, 0, 0, 0)
  return pass
end

function aurora.draw(current: Fixture, pass: Pass): ()
  for _, entry in current.draws do
    if entry.active then
      entry.run(pass)
    end
  end
end

function aurora.capture(current: Fixture): Image
  local pass = aurora.prepare(current)
  aurora.draw(current, pass)
  return render.read(current.texture, pass)
end

function aurora.settle(current: Fixture): ()
  aurora.update(current, 2, false)
end

function aurora.collect(): ()
  collectgarbage 'collect'
  lovr.graphics.submit()
  lovr.graphics.wait()
end

return aurora
