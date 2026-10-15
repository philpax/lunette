-- Opt-in diagnostics acquire owner-scoped readers and report public metadata without a GPU or XR dependency.
local plugin = require '@lunette-plugin'
local schema = require '@lunette-plugin/schema'
local frame = require '@lunette-contracts/frame'
local audio = require '@lunette-contracts/audio'
local analysis = require '@lunette-contracts/audio-analysis'
local logging = require '@lunette-plugins/diagnostics/desktop-logging'
local readout = require '@self/readout'
local history = require '@self/history'

local function system(): audio.Source
  return { kind = 'system' }
end

local descriptor = schema.object {
  enabled = schema.default(schema.boolean())(false),
  interval = schema.default(schema.number { minimum = 0.1, maximum = 60 })(1),
  source = schema.default(schema.callback(system))(system),
}
export type Config = schema.Input<typeof(descriptor)>
export type Settings = schema.Output<typeof(descriptor)>

return plugin.consumer<<Config, Settings>> {
  name = 'dev/audio-diagnostics',
  requires = { frame.capability, audio.capability, analysis.capability },
  schema = descriptor,
  init = function(context: plugin.Context, settings: Settings): ()
    if not settings.enabled then
      return
    end
    local source = settings.source()
    local raw = context:require(audio.capability):open(context, source)
    local result = context:require(analysis.capability):open(context, source)
    local features: analysis.Reader? = nil
    if result.kind == 'success' then
      features = result.reader
    else
      logging.report('audio diagnostics analysis: ' .. result.kind .. ': ' .. result.detail, 'warn')
    end
    local elapsed = settings.interval
    local pending = history.new()
    context:require(frame.capability):onUpdate(context, {
      phase = 'input',
      run = function(dt: number): ()
        local reader = features
        local snapshot = raw:snapshot()
        local featureSnapshot = if reader then reader:snapshot() else nil
        history.observe(pending, snapshot, featureSnapshot)
        elapsed += dt
        if elapsed < settings.interval then
          return
        end
        elapsed = 0
        logging.report(readout.format(snapshot, featureSnapshot) .. '\n' .. history.take(pending), 'info')
      end,
    })
  end,
}
