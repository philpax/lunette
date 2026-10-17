-- The file that keeps a session's saved settings: an override of configuration fields for each entry id, which the
-- plugin runtime applies over the configuration and records as the user changes it. A file from a newer version is
-- reported, applies nothing, and is never overwritten.

local protected = require '@lunette-plugins/diagnostics/protected-call'
local versionedFile = require '@lunette-plugins/storage/versioned-file'

local savedSettings = {}

local VERSION = 1
local LABEL = 'saved settings'

export type Saved = {
  read overrides: { [string]: { [string]: unknown } },
  read write: () -> (),
  read report: (string) -> (),
  read storable: (unknown) -> boolean,
}

local function report(message: string): ()
  protected.call(LABEL, function(): ()
    error(message, 0)
  end)
end

-- Opens the file in LÖVR's save directory, reporting a file that cannot be read.
function savedSettings.open(name: string): Saved
  local overrides: { [string]: { [string]: unknown } } = {}
  local writable = true
  local loaded = versionedFile.read(name, VERSION)
  if loaded.kind == 'data' then
    local entries = loaded.data.entries
    for id, override in if type(entries) == 'table' then entries else {} do
      if type(id) == 'string' and type(override) == 'table' then
        overrides[id] = override
      end
    end
  elseif loaded.kind == 'fromTheFuture' then
    writable = false
    report(`the file has version {loaded.found}, newer than this version reads; it applies nothing and is kept`)
  elseif loaded.kind == 'broken' then
    report(`the file could not be read, so no saved settings apply until one changes: {loaded.message}`)
  end
  return table.freeze {
    overrides = overrides,
    write = function(): ()
      if not writable then
        return
      end
      local ok, failure = pcall(versionedFile.write, name, VERSION, { entries = overrides })
      if not ok then
        report(`the settings could not be saved to {name}: {tostring(failure)}`)
      end
    end,
    report = report,
    storable = versionedFile.literal,
  }
end

return savedSettings
