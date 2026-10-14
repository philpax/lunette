-- Restores a renderer's pass state and transform, including when rendering raises.
local passState = {}

-- The pops cannot raise: each matches a push made here, so the stack is balanced.
function passState.withRestore(pass: Pass, render: () -> ()): ()
  pass:push 'state'
  pass:push 'transform'
  local ok, failure = pcall(render)
  pass:pop 'transform'
  pass:pop 'state'
  if not ok then
    error(failure, 0)
  end
end

return passState
