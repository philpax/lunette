local testing = require '@testing'
local render = require '@testing/render'
local backdrop = require '@lunette-plugins/desktop/backdrop'

export type Factory = backdrop.Factory

local fixture = {}

export type Environment = {
  session: testing.Session,
  native: testing.Native,
  recorder: render.Recorder,
  pass: render.Pass,
  uniforms: { [string]: unknown },
  drawn: { { uniforms: { [string]: unknown }, transform: Mat4 } },
}

function fixture.boot(factory: backdrop.Factory): Environment
  local session = testing.boot { 'frame', { id = 'desktop/backdrop', definition = factory.definition } }
  local native = session.native
  local recorder = native.events.render
  local pass = native.events.pass
  local uniforms, drawn = {}, {}
  if not pass.origin then
    function pass.origin()
      recorder._transform:identity()
    end
  end
  local originalSend = pass.send
  function pass.send(self: render.Pass, name: string, value: unknown): ()
    uniforms[name] = value
    if originalSend then
      originalSend(self, name, value)
    end
  end
  local originalDraw = pass.draw
  function pass.draw(self: render.Pass, ...: any): ()
    drawn[#drawn + 1] = {
      uniforms = table.clone(uniforms),
      transform = lovr.math.newMat4(recorder._transform),
    }
    originalDraw(self, ...)
  end
  return { session = session, native = native, recorder = recorder, pass = pass, uniforms = uniforms, drawn = drawn }
end

return fixture
