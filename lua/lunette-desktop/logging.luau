-- Reports through LÖVR's log, independently of the optional error stream.
local logging = {}

function logging.report(message: string, level: string): ()
  local log = lovr.log
  if log then
    log(message, level, 'lunette.desktop')
  else
    print('lunette: ' .. message)
  end
end

return logging
