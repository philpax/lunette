local testing = require '@testing'
local renderer = require '../private/rendering/renderer'
local expect = testing.expect
local test = testing.suite()

-- The resources the glyph lookup reads, with an atlas that counts its calls.
local function resources(answers: { [number]: any }): (any, { number }, { string })
  local calls: { number } = {}
  local reports: { string } = {}
  local atlas = {
    glyph = function(_self: any, face: number, id: number): (any, string?, boolean)
      table.insert(calls, face * 1000 + id)
      local answer = answers[id]
      if answer == 'pending' then
        return nil, nil, true
      end
      if type(answer) == 'string' then
        return nil, answer, false
      end
      return answer, nil, false
    end,
  }
  return {
    atlas = atlas,
    placements = {},
    report = function(message: string)
      table.insert(reports, message)
    end,
  },
    calls,
    reports
end

test('a glyph crosses into the atlas once, and a failure is reported once', function()
  local placement = { page = 1, u0 = 0, v0 = 0, u1 = 0.1, v1 = 0.1, left = 0, top = 0.7, width = 0.5, height = 0.8 }
  local held, calls, reports = resources { [1] = placement, [2] = nil, [3] = 'glyph atlas: too large' }
  local lookup = renderer.glyphs(held)
  for _ = 1, 3 do
    expect.equal(lookup(0, 1), placement, 'the placement')
    expect.equal(lookup(0, 2), nil, 'a glyph with no outline')
    expect.equal(lookup(0, 3), nil, 'a failed glyph draws nothing')
  end
  expect.equal(#calls, 3, 'each glyph is asked for once')
  expect.equal(#reports, 1, 'the failure is reported once')
  expect.equal(reports[1], 'glyph atlas: too large')
  expect.equal(lookup(1, 1), placement, 'another face is a separate glyph')
  expect.equal(#calls, 4)
end)

test('a glyph still generating is asked for again until it is placed', function()
  local placement = { page = 1, u0 = 0, v0 = 0, u1 = 0.1, v1 = 0.1, left = 0, top = 0.7, width = 0.5, height = 0.8 }
  local answers: { [number]: any } = { [1] = 'pending' }
  local held, calls, reports = resources(answers)
  local lookup = renderer.glyphs(held)
  expect.equal(lookup(0, 1), nil, 'a pending glyph draws nothing')
  expect.equal(lookup(0, 1), nil, 'and still draws nothing')
  expect.equal(#calls, 2, 'a pending glyph is asked for each time')
  answers[1] = placement
  expect.equal(lookup(0, 1), placement, 'the placed glyph')
  expect.equal(lookup(0, 1), placement)
  expect.equal(#calls, 3, 'a placed glyph is remembered')
  expect.equal(#reports, 0, 'waiting is not a failure')
end)

test('a cleared atlas page makes placed glyphs be asked for again', function()
  local placement = { page = 1, u0 = 0, v0 = 0, u1 = 0.1, v1 = 0.1, left = 0, top = 0.7, width = 0.5, height = 0.8 }
  local held, calls = resources { [1] = placement }
  local atlas = held.atlas :: any
  atlas.epoch = 0
  atlas.update = function() end
  held.epoch = 0
  local lookup = renderer.glyphs(held)
  lookup(0, 1)
  renderer.beginFrame(held)
  lookup(0, 1)
  expect.equal(#calls, 1, 'a placed glyph is remembered across frames')
  atlas.epoch = 1
  renderer.beginFrame(held)
  lookup(0, 1)
  expect.equal(#calls, 2, 'after a page is cleared, the glyph is asked for again')
end)

return test
