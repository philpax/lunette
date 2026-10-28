local testing = require '@testing'
local plugin = require '@lunette-plugin'
local config = require '../config'
local draw = require '../private/rendering/draw'
local model = require '../private/rendering/model'
local shader = require '../private/rendering/shader'
local test = testing.suite()
local expect = testing.expect

for _, miniature in { false, true } do
  test(
    (if miniature then 'miniature' else 'scene') .. ' draws refresh band ends after dense and empty frames',
    function()
      local session = testing.boot {}
      local settings = config.schema.parse {}
      local renderer
      session:use(plugin.consumer({
        name = 'testing/backdrop-renderer',
        init = function(context: plugin.Context)
          renderer = draw.new(context, settings, function(): 'none'
            return 'none'
          end)
        end,
      }).definition)
      local recorder = session.native.events.render
      local pass = recorder.pass
      local state = model.new(settings)
      local bands = { 'treble', 'mid', 'bass', 'treble', 'bass', 'mid', 'mid' }
      for _, count in { model.MAX_WAVES, 0, 7, 1, 0 } do
        table.clear(state.waves)
        local expected = { bass = 0, mid = 0, treble = 0 }
        for index = 1, count do
          local band = bands[(index - 1) % #bands + 1]
          state.waves[index] = {
            age = 0.08,
            strength = 0.7,
            position = index / (model.MAX_WAVES + 1),
            band = band,
            lifetime = model.waveLifetimes[band],
            frequency = index / model.MAX_WAVES,
          }
          expected[band] += 1
        end
        local frame = table.clone(state:update(0, false))
        frame.visibility = 1
        table.clear(recorder.calls)
        local checkpoint = recorder:checkpoint()
        if miniature then
          renderer.miniature(pass, frame, 0.5, nil, 0.7)
        else
          renderer.render(pass, frame, vector.zero)
        end
        recorder:assertRestored(checkpoint)
        local sent, current, endsSends, curtains, draws = {}, nil, 0, 0, 0
        for _, call in recorder.calls do
          if call[1] == 'setShader' then
            current = call[2]
          elseif call[1] == 'send' then
            sent[call[2]] = call[3]
            if call[2] == 'backdropWaveEnds' then
              endsSends += 1
            end
          elseif call[1] == 'draw' then
            draws += 1
            if current.fragment == shader.curtainFragment then
              curtains += 1
              expect.equal(endsSends, 1, 'the ends are supplied again before any curtain draw')
              expect.equal(sent.backdropWaveCount, count, 'the live count reaches every curtain layer')
              for lane, value in { expected.bass, expected.bass + expected.mid, count, 0 } do
                expect.equal(sent.backdropWaveEnds[lane], value, 'the cumulative end reaches every curtain layer')
              end
              for index = count + 1, model.MAX_WAVES do
                for lane = 1, 4 do
                  expect.equal(sent.backdropWaves[index][lane], 0, 'inactive wave rows do not survive a dense frame')
                  expect.equal(
                    sent.backdropWaveDetail[index][lane],
                    0,
                    'inactive detail rows do not survive a dense frame'
                  )
                end
              end
            end
          end
        end
        expect.equal(curtains, 3, 'all curtain layers receive the fresh ends')
        expect.equal(draws, 5, 'the optimization does not add draws')
      end
      session:close()
      recorder:assertResourcesReleased()
    end
  )
end

return test
