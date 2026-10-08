-- Restores a renderer's pass state and transform, including when rendering raises.
local passState = {}

function passState.withRestore(pass: Pass, render: () -> ()): ()
  local state, transform = false, false
  local ok, failure = pcall(function()
    pass:push 'state'
    state = true
    pass:push 'transform'
    transform = true
    render()
  end)
  -- Both inverses run; a rendering error takes precedence over a restoration error.
  if transform then
    local restored, problem = pcall(pass.pop, pass, 'transform')
    if ok and not restored then
      ok, failure = false, problem
    end
  end
  if state then
    local restored, problem = pcall(pass.pop, pass, 'state')
    if ok and not restored then
      ok, failure = false, problem
    end
  end
  if not ok then
    error(failure, 0)
  end
end

return passState
