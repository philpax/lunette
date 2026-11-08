local exportName = {}

function exportName.unique(timestamp: string, files: { string }): string
  local occupied: { [string]: boolean } = {}
  for _, file in files do
    occupied[file] = true
  end
  for index = 1, #files + 1 do
    local name = string.format('frame-trace-%s-%03d.csv', timestamp, index)
    if not occupied[name] then
      return name
    end
  end
  error 'frame trace: could not choose an unused export name'
end

return exportName
