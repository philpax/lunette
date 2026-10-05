local testing = require '@testing'
local lunette = require '@lunette'
local expect = testing.expect
local test = testing.suite()

test('the real native text boundaries helper survives the graphics and input test boundary', function()
  local boundaries = lunette.textBoundaries
  expect.equal(type(boundaries), 'function', 'the real Lua state bootstrap installs the public helper')
  expect.equal(
    table.concat(boundaries 'é👩🏽‍💻🇳🇿', ','),
    '1,4,19,27',
    'native extended grapheme offsets'
  )
  testing.native()
  expect.equal(lunette.textBoundaries, boundaries, 'the unmanaged test boundary does not replace segmentation')
  expect.equal(
    table.concat(lunette.textBoundaries 'é👩🏽‍💻🇳🇿', ','),
    '1,4,19,27',
    'real helper remains callable'
  )
  expect.equal(table.concat(lunette.textBoundaries '', ','), '1', 'empty input has the terminal offset')
  expect.raises(function()
    lunette.textBoundaries(string.char(255))
  end, 'UTF%-8', 'invalid byte strings fail natively')
end)

return test
