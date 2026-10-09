-- Manual file-font readers and draw hooks exercise retention through mutation and error unwind.
local plugin = require '@lunette-plugin'
local theme = require '@lunette-contracts/theme'
local ui = require '@lunette-contracts/ui'
local frame = require '@lunette-contracts/frame'
local session = require './session'

local fonts = {}

function fonts.install(demo: session.Session, widgets: ui.Service, frames: frame.Service): ()
  local themes = demo.themes
  -- A distinct size prevents the desktop's Arcade face from masking this reader's retirement.
  local file: theme.FileFontSpec = {
    kind = 'file',
    file = '@lunette-plugins/theme/fonts/SpaceMono-Regular.ttf',
    size = 37,
    spread = 4,
  }
  local missing: theme.FileFontSpec = {
    kind = 'file',
    file = 'theme-registration-missing-font.ttf',
    size = 37,
    spread = 4,
  }
  local selection: theme.Registration? = nil
  local selectionChild, readerChild: session.Child? = nil, nil
  local readerOwner: plugin.Context? = nil
  local lease: theme.FontLease? = nil
  local prior: theme.Snapshot? = nil
  local selectionLive, readerLive = false, false
  local function endReader(): ()
    if lease then
      lease:dispose()
    end
    if readerChild and readerChild.instance:state() ~= 'removed' then
      readerChild.instance:dispose()
    end
    readerLive = false
  end
  local function endSelection(): ()
    if selection then
      selection:dispose()
    end
    if selectionChild and selectionChild.instance:state() ~= 'removed' then
      selectionChild.instance:dispose()
    end
    selectionLive = false
  end
  local function acquireReader(): ()
    endReader()
    readerChild = demo.child('font-reader', function(owner: plugin.Context): ()
      readerOwner = owner
      lease = themes:acquireFont(owner, file)
      readerLive = true
    end)
    demo.log 'File reader acquired; selection and reader have distinct child owners'
  end
  local function readerRegistration(): (boolean, number)
    for _, entry in themes:inspect().registrations do
      if entry.kind == 'hold' and entry.owner == readerOwner then
        local count = entry.details.invocations
        return entry.live, if type(count) == 'number' then count else 0
      end
    end
    return false, 0
  end
  local function afterReader(): ()
    local live, count = readerRegistration()
    demo.check(not live and count == 0, 'Ended reader has no live lease or invocation after unwind')
    demo.check(demo.invocations() == 0, 'All public reader invocation counts return to zero')
  end
  demo.action('file-select', '16. Select file font', function(): ()
    endReader()
    endSelection()
    prior = themes:current()
    selectionChild = demo.child('file-selection', function(owner: plugin.Context): ()
      selection = themes:select(owner, { typography = { font = file } })
      selectionLive = true
    end)
    demo.check(themes:current().theme.typography.font.kind == 'file', 'File selection is live')
  end)
  demo.action('file-reader', '17. Acquire distinct file reader', function(): ()
    assert(selectionLive, 'Select the file font first')
    acquireReader()
    assert(lease):withFont(function(font: Font): ()
      demo.log(
        'Reader width=' .. tostring(font:getWidth 'Retained file face') .. ' height=' .. tostring(font:getHeight())
      )
    end)
  end)
  local saved: theme.FontLease? = nil
  demo.action('fail-reader-refresh', '18. Failed reader refresh (error)', function(): ()
    assert(readerLive, 'Acquire a file reader first')
    saved = lease
    local replacement = themes:acquireFont(assert(readerOwner), missing)
    local previous = assert(lease)
    lease = replacement
    previous:dispose()
    error('theme registration example: missing reader font unexpectedly loads', 0)
  end, function(): ()
    if saved then
      demo.check(lease == saved, 'Failed replacement acquisition preserves the previous reader lease')
      endSelection()
      demo.log 'Failed refresh also disposes the selection; the independent reader remains live'
      saved:withFont(function(font: Font): ()
        demo.check(font:getWidth 'Still usable after failed refresh' > 0, 'Preserved file reader measures text')
      end)
    end
  end)
  demo.action('file-dispose-selection', '19. Dispose file selection; measure reader', function(): ()
    assert(readerLive and prior, 'Select the file font and acquire its reader first')
    endSelection()
    demo.check(themes:current().theme == assert(prior).theme, 'File selection teardown restores its predecessor')
    assert(lease):withFont(function(font: Font): ()
      demo.check(
        font:getHeight() > 0 and font:getWidth 'Reader outlives selection' > 0,
        'Explicit reader keeps the retired file face usable'
      )
    end)
  end)
  demo.action('reader-default', '20. Replace reader with default; inspect', function(): ()
    assert(readerLive and not selectionLive, 'Dispose the file selection while keeping its reader first')
    local replacement = themes:acquireFont(assert(readerOwner), { kind = 'default' })
    local previous = assert(lease)
    lease = replacement
    previous:dispose()
    demo.check(lease.spec.kind == 'default', 'Successful replacement acquires before retiring the old lease')
    for _, entry in themes:inspect().registrations do
      if entry.owner == readerOwner then
        demo.log('Reader: ' .. demo.metadata(entry.details))
        demo.check(entry.details.font == 'default', 'Reader metadata no longer retains the retired file face')
      end
    end
    demo.log 'Observation UI may retain a default lease; no global empty-cache assertion is required'
  end)
  demo.action('reader-cleanup', '21. End file reader and selection owners', function(): ()
    endReader()
    endSelection()
    afterReader()
  end)

  demo.action('reader-prepare-end', '22. Acquire file reader for owner ending', function(): ()
    endSelection()
    acquireReader()
  end)
  local function ending(raise: boolean): ()
    assert(readerLive, 'Acquire the file reader for owner ending first')
    assert(lease):withFont(function(font: Font): ()
      local live, count = readerRegistration()
      demo.check(live and count == 1, 'Entering withFont acquires one invocation hold')
      assert(readerChild).instance:disable()
      readerLive = false
      live, count = readerRegistration()
      demo.check(not live and count == 1, 'Child disable ends the lease but preserves the active invocation')
      demo.check(
        font:getWidth 'Owner ends inside withFont' > 0 and font:getHeight() > 0,
        'Font remains valid after reader owner ends inside callback'
      )
      if raise then
        error('theme registration example: reader owner-ending error', 0)
      end
    end)
  end
  demo.action('reader-end', '23. End reader inside withFont', function(): ()
    ending(false)
  end, afterReader)
  demo.action('reader-disposed-entry', '24. Enter ended reader (error)', function(): ()
    assert(not readerLive and lease, 'End the reader inside withFont first')
    lease:withFont(function(_font: Font): ()
      error('theme registration example: disposed reader callback unexpectedly enters', 0)
    end)
  end, afterReader)
  demo.action('reader-end-error', '25. Repeat owner ending with error', function(): ()
    endSelection()
    acquireReader()
    ending(true)
  end, afterReader)

  local drawMode: ('swap' | 'error')? = nil
  local recovering = false
  local probe: ui.Panel? = nil
  local function prepareDraw(mode: 'swap' | 'error'): ()
    assert(drawMode == nil and not recovering, 'Wait for the pending draw and recovery before arming again')
    endReader()
    endSelection()
    selectionChild = demo.child('draw-file-selection', function(owner: plugin.Context): ()
      selection = themes:select(owner, { typography = { font = file } })
      selectionLive = true
    end)
    if not probe then
      probe = widgets:newPanel(demo.context, {
        name = 'example/ui/theme-registration/font-probe',
        pose = lovr.math.newMat4():translate(vector.pack(0.78, 1.35, -1.5)),
        width = 0.5,
        height = 0.3,
        logicalWidth = 360,
        logicalHeight = 216,
        visible = true,
        grabbable = true,
        draw = function(pass: Pass, visual: ui.Visual, base: ui.Renderer): ()
          local mode = drawMode
          if visual.kind ~= 'panel' or not mode then
            base(pass, visual)
            return
          end
          drawMode = nil
          local oldFont = visual.theme.font
          demo.check(themes:current().theme.typography.font.kind == 'file', 'Hook captures the selected file font')
          assert(selection):update { typography = { font = { kind = 'default' } } }
          demo.check(
            themes:current().theme.typography.font.kind == 'default',
            'Hook publishes the default-font selection'
          )
          demo.check(
            oldFont:getWidth 'Old visual survives selection swap' > 0 and oldFont:getHeight() > 0,
            'Captured old visual font remains usable until the hook returns'
          )
          demo.log 'Base called with old visual; UI revision guard suppresses stale rendering'
          base(pass, visual)
          recovering = true
          if mode == 'error' then
            pass:translate(200, 100, 0)
            pass:setColor(1, 0, 0, 1)
            error('theme registration example: draw hook original error', 0)
          end
        end,
      })
      assert(probe):region(demo.context, {
        id = 'font-recovery',
        label = 'Normal draw after swap/error',
        bounds = { x = 12, y = 12, width = 336, height = 192 },
        draw = function(pass: Pass, visual: ui.Visual, base: ui.Renderer): ()
          base(pass, visual)
          if recovering then
            demo.check(
              visual.theme.font:getWidth 'Next draw uses the live font' > 0,
              'Next draw succeeds with live font'
            )
            recovering = false
          end
        end,
      })
    end
    assert(probe):setVisible(true)
    drawMode = mode
    demo.log 'One-shot hook armed; no error occurs until the next probe draw'
  end
  demo.action('draw-swap', '26. Arm UI font swap', function(): ()
    prepareDraw 'swap'
  end)
  demo.action('draw-error', '27. Arm UI font swap with draw error', function(): ()
    prepareDraw 'error'
  end)
  demo.action('draw-cleanup', '28. Close probe and restore preceding theme', function(): ()
    drawMode, recovering = nil, false
    if probe and not probe.dead then
      probe:destroy()
    end
    probe = nil
    endReader()
    endSelection()
    demo.check(demo.invocations() == 0, 'Probe cleanup leaves no invocation holds')
  end)
  frames:onDraw(demo.context, {
    phase = 'overlay',
    run = function(pass: Pass): ()
      local panel = probe
      if not demo.context:active() or not panel or panel.dead then
        return
      end
      local wasArmed = drawMode ~= nil
      local ok, failure = pcall(function(): ()
        panel:draw(pass)
      end)
      if wasArmed then
        demo.check(demo.invocations() == 0, 'Draw invocation counts return to zero after hook unwind')
        demo.log 'Check pass restoration visually: probe and observation panel stay in place on the next draw'
      end
      if not ok then
        demo.log('Draw reports original error: ' .. tostring(failure))
        error(failure, 0)
      end
    end,
  })
end

return fonts
