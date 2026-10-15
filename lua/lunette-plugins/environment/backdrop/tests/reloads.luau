-- Exercises backdrop lifetimes through real providers, source reloads, and public VR controls.
local testing = require '@testing'
local expect = testing.expect
local lunette = require '@lunette'
local vrUi = require '@testing/vr-ui'
local lifetimes = require './support/lifetimes'
local backdrop = require '../'
local audio = require '@lunette-contracts/audio'
local frame = require '@lunette-contracts/frame'
local menu = require '@lunette-contracts/menu'
local ui = require '@lunette-contracts/ui'
local render = require '@testing/render'

type Services = lifetimes.Services
type Totals = {
  audio: number,
  meshes: number,
  shaders: number,
  frame: number,
  menu: number,
  ui: number,
  panels: number,
  surfaces: number,
}

local test = testing.suite()
local panelName = 'desktop/backdrop/controls'
local backdropName = 'desktop/backdrop'
local system = { kind = 'system' }
local driver

local function popup(ui: ui.Service, control: string): ()
  local geometry, description = driver:discover(ui, panelName, control)
  local bounds = description.bounds
  driver:click(geometry, bounds.x + bounds.width / 2, bounds.y + 16)
end

local function choose(ui: ui.Service, control: string, item: string): ()
  popup(ui, control)
  driver:clickControl(ui, panelName, control, 'right', item)
end

local function live(list: { any }, released: string?): number
  local count = 0
  for _, handle in list do
    if not handle[released or 'dead'] then
      count += 1
    end
  end
  return count
end

local function instance(snapshot: lunette.PluginRuntimeSnapshot, name: string): lunette.PluginInstanceSnapshot?
  for _, entry in snapshot.instances do
    if entry.name == name and not entry.retired then
      return entry
    end
  end
  return nil
end

local function registrations(service: frame.Service | menu.Service | ui.Service, kind: string?, name: string?): number
  local count = 0
  for _, entry in service:inspect().registrations do
    if entry.live and (kind == nil or entry.kind == kind) and (name == nil or entry.name == name) then
      count += 1
    end
  end
  return count
end

local function selected(ui: ui.Service, control: string): string?
  if control ~= 'applications' then
    popup(ui, control)
  end
  local chosen
  for _, entry in ui:inspect().registrations do
    if
      entry.live
      and entry.kind == 'item'
      and entry.details.panel == panelName
      and entry.details.control == control
      and entry.details.selected
    then
      chosen = entry.name
    end
  end
  if control ~= 'applications' then
    popup(ui, control)
  end
  return chosen
end

local function step(native: testing.Native, source: audio.Source?, state: audio.State?, pcm: buffer?): ()
  if source then
    native.setAudioState(source, state or { kind = 'active', provenance = 'pipewire-client' })
    if pcm then
      native.pushAudio(source, pcm)
    end
  end
  native.advanceFrame(0.1)
  lovr.update(0.1)
end

local function tone(): buffer
  local pcm = buffer.create(4096 * 8)
  for frame = 0, 4095 do
    local sample = 0.2 * math.sin(2 * math.pi * 220 * frame / 48000)
    buffer.writef32(pcm, frame * 8, sample)
    buffer.writef32(pcm, frame * 8 + 4, sample)
  end
  return pcm
end

local function open(services: Services): ()
  expect.equal(
    services.menu:invoke('desktop/backdrop/open').kind,
    'invoked',
    'the public Backdrop action opens controls'
  )
end

local function textContains(native: testing.Native, needle: string): boolean
  for _, call in native.events.draw do
    if call[1] == 'text' and type(call[2]) == 'string' and string.find(call[2], needle, 1, true) then
      return true
    end
  end
  return false
end

local function defaults(services: Services): ()
  expect.equal(selected(services.ui, 'enabled'), 'on', 'configuration restores enabled')
  expect.equal(selected(services.ui, 'reactive'), 'on', 'configuration restores reactivity')
  expect.equal(selected(services.ui, 'source-mode'), 'system', 'configuration restores the system mix')
  expect.equal(selected(services.ui, 'response'), '1', 'configuration restores response')
  expect.equal(selected(services.ui, 'motion'), '1', 'configuration restores motion')
  expect.equal(selected(services.ui, 'applications'), nil, 'configuration forgets the pinned application')
end

local function totals(native: testing.Native, services: Services): Totals
  return {
    audio = live(native.events.audio),
    meshes = live(native.events.render.meshAcquisitions, 'released'),
    shaders = live(native.events.render.shaderAcquisitions, 'released'),
    frame = registrations(services.frame),
    menu = registrations(services.menu),
    ui = registrations(services.ui),
    panels = registrations(services.ui, 'panel'),
    surfaces = #services.surfaces:all(),
  }
end

local function sameTotals(native: testing.Native, services: Services, expected: Totals, label: string): ()
  for name, count in totals(native, services) do
    expect.equal(count, expected[name], label .. ' keeps the live ' .. name .. ' count')
  end
end

local function children(
  snapshot: lunette.PluginRuntimeSnapshot
): (lunette.PluginInstanceSnapshot, { [string]: lunette.PluginInstanceSnapshot })
  local result = {}
  local parent = assert(instance(snapshot, backdropName), 'the backdrop parent is present')
  for _, entry in snapshot.instances do
    if entry.parentId == parent.id and not entry.retired then
      result[entry.name] = entry
    end
  end
  return parent, result
end

local function shaderGenerationReleased(native: testing.Native, meshes: { render.Mesh }, shaders: { render.Shader }): ()
  for _, handle in meshes do
    expect.equal(handle.released, true, 'the previous backdrop mesh is released')
  end
  for _, handle in shaders do
    expect.equal(handle.released, true, 'the previous backdrop shader is released')
  end
  expect.equal(
    native.events.audioOpened - native.events.audioClosed,
    live(native.events.audio),
    'native reader accounting'
  )
  expect.equal(native.events.audioStreamsOpened - native.events.audioStreamsClosed, 1, 'one source stream remains')
end

local function tenSourceReloads()
  local ok, failure = pcall(function()
    local native = testing.native()
    native.events.mainSessionVisible = false
    local process = native.newProcess(41, { 'fixture-player' })
    local pcm = tone()
    testing.host.useConfiguration 'lua/lunette-plugins/environment/backdrop/tests/support/source-reload'
    require 'main'
    lovr.load()
    local fixture = vrUi.hands(native)
    driver = fixture
    local baseline
    local subscriptions = {}
    for name in native.events.subscriptions do
      subscriptions[name] = native.subscriptionCount(name)
    end
    for reload = 1, 10 do
      local services = assert(_G.backdropReloadServices, 'the reload configuration exposes live public services')
      step(native, system, nil, pcm)
      step(native, system, nil, pcm)
      expect.equal(lovr.draw(native.events.pass), false, 'the backdrop draws without vetoing submission')
      expect.truthy(native.events.audioCopies > 0, 'synthetic PCM reaches real audio analysis')
      open(services)
      defaults(services)
      lovr.draw(native.events.pass)
      baseline = baseline or totals(native, services)
      sameTotals(native, services, baseline, 'source generation ' .. reload)
      local beforeParent, beforeChildren = children(services.composition:snapshot())
      expect.equal(beforeParent.state, 'active', 'the renderer is active')
      for _, name in { 'response', 'attention', 'controls' } do
        expect.equal(
          assert(beforeChildren[backdropName .. '/' .. name], 'the ' .. name .. ' child exists').state,
          'active',
          'the child is active'
        )
      end
      fixture:clickControl(services.ui, panelName, 'applications', 'right', 'application-1')
      choose(services.ui, 'response', '0.25')
      choose(services.ui, 'motion', '1')
      step(native, { kind = 'process', process = process }, nil, pcm)
      expect.equal(selected(services.ui, 'source-mode'), 'application', 'the VR list pins an application')
      expect.equal(selected(services.ui, 'applications'), 'application-1', 'the live process handle is selected')

      services.composition:disable(backdropName)
      expect.equal(live(native.events.audio), 0, 'plugin disable closes native-owned readers')
      expect.equal(registrations(services.ui, 'panel', panelName), 0, 'plugin disable removes controls')
      services.composition:enable(backdropName)
      step(native, { kind = 'process', process = process }, nil, pcm)
      open(services)
      expect.equal(selected(services.ui, 'source-mode'), 'application', 'reactivation retains the factory mode')
      expect.equal(selected(services.ui, 'applications'), 'application-1', 'reactivation retains the factory process')
      expect.equal(selected(services.ui, 'response'), '0.25', 'reactivation retains response')
      expect.equal(selected(services.ui, 'motion'), '1', 'reactivation retains motion')
      choose(services.ui, 'enabled', 'off')
      choose(services.ui, 'reactive', 'off')
      local oldUi = services.ui
      local meshes = table.clone(native.events.render.meshAcquisitions)
      local shaders = table.clone(native.events.render.shaderAcquisitions)
      local loaded, failure = lunette.reload()
      expect.truthy(loaded, tostring(failure))
      expect.falsy(
        pcall(function()
          oldUi:inspect()
        end),
        'source reload withdraws the previous UI service'
      )
      local current = assert(_G.backdropReloadServices, 'the next source generation loads')
      step(native, system, nil, pcm)
      step(native, system, nil, pcm)
      expect.equal(lovr.draw(native.events.pass), false, 'the next generation renders')
      shaderGenerationReleased(native, meshes, shaders)
      open(current)
      defaults(current)
      lovr.draw(native.events.pass)
      sameTotals(native, current, baseline, 'reload ' .. reload)
      expect.equal(#testing.takeReports(), 0, 'reload leaves no plugin failure report')
      expect.equal(#native.events.reported, 0, 'reload leaves no frame failure report')
      for name in native.events.subscriptions do
        expect.equal(
          native.subscriptionCount(name),
          subscriptions[name] or 0,
          'reload preserves the native subscription count for ' .. name
        )
      end
      open(current)
    end
    expect.equal(lovr.quit(), false, 'quit does not veto')
    expect.equal(#testing.host.shutdown(), 0, 'source-reloaded runtimes shut down cleanly')
    native.assertResourcesReleased()
  end)
  if not ok then
    if lovr.quit then
      lovr.quit()
    end
    testing.host.shutdown()
    error(failure, 0)
  end
end

test('provider outages withdraw only dependent backdrop children and recover without duplicate resources', function()
  local factory = backdrop.create()
  local session = testing.boot(lifetimes.entries(factory))
  local native = session.native
  local process = native.newProcess(51)
  local source = { kind = 'process', process = process }
  factory.choice:setMode 'attention'
  factory.choice:attend(process)
  factory.choice:setResponse(0.25)
  native.events.mainSessionVisible = false
  local observed = lifetimes.observe(session)
  local function services(): Services
    local result = {}
    for name, observer in observed do
      if observer.instance:state() == 'active' then
        result[name] = observer.service
      end
    end
    return result
  end
  local pcm = tone()
  step(native, source, nil, pcm)
  step(native, source, nil, pcm)
  session:draw()
  open(services())
  session:draw()
  local baseline = totals(native, services())
  local initialParent, initialChildren = children(session.runtime:snapshot())
  for _, name in { 'response', 'attention', 'controls' } do
    expect.equal(
      assert(initialChildren[backdropName .. '/' .. name], 'the ' .. name .. ' child exists').state,
      'active',
      'child is active before outages'
    )
  end
  local cases = {
    {
      provider = 'audio',
      unavailable = { response = true, ['process-status'] = true },
      readers = 0,
      status = 'audio provider unavailable',
    },
    {
      provider = 'audio-analysis',
      unavailable = { response = true },
      readers = 0,
      status = 'audio provider unavailable',
    },
    {
      provider = 'panels',
      unavailable = { attention = true },
      readers = baseline.audio,
      status = 'Attention unavailable',
    },
    {
      provider = 'surfaces',
      unavailable = { attention = true, controls = true },
      readers = baseline.audio,
    },
    { provider = 'menu', unavailable = { controls = true }, readers = baseline.audio },
    { provider = 'ui', unavailable = { controls = true }, readers = baseline.audio },
  }
  for _, case in cases do
    local beforeParent, beforeChildren = children(session.runtime:snapshot())
    expect.equal(factory.choice.frozen, true, 'open controls freeze attention before withdrawal')
    session.instances[case.provider]:disable()
    session.runtime:drain()
    local parent, current = children(session.runtime:snapshot())
    expect.equal(parent.state, 'active', case.provider .. ' outage leaves the frame-only parent active')
    expect.equal(
      parent.activationId,
      beforeParent.activationId,
      case.provider .. ' outage does not replace the renderer'
    )
    for name, previous in beforeChildren do
      local suffix = string.sub(name, #backdropName + 2)
      local child = assert(current[name], 'the dependent child remains recoverable')
      if case.unavailable[suffix] then
        expect.truthy(child.state ~= 'active', case.provider .. ' withdraws ' .. suffix)
      else
        expect.equal(child.state, 'active', case.provider .. ' leaves ' .. suffix .. ' active')
        expect.equal(child.activationId, previous.activationId, case.provider .. ' keeps ' .. suffix .. ' activation')
      end
    end
    expect.equal(
      live(native.events.audio),
      case.readers,
      case.provider .. ' outage keeps only the expected native readers'
    )
    expect.equal(factory.choice.attended, process, case.provider .. ' outage retains the attended process')
    expect.equal(factory.choice.frozen, not case.unavailable.controls, 'controls cleanup releases its attention freeze')
    local currentServices = services()
    if currentServices.menu then
      local actionCount = 0
      for _, action in currentServices.menu:list() do
        if action.id == 'desktop/backdrop/open' then
          actionCount += 1
        end
      end
      expect.equal(actionCount, if case.unavailable.controls then 0 else 1, 'controls own exactly their menu action')
    end
    if currentServices.ui then
      expect.equal(
        registrations(currentServices.ui, 'panel', panelName),
        if case.unavailable.controls then 0 else 1,
        'controls own exactly their UI panel'
      )
    end
    native.events.draw = {}
    step(native)
    expect.equal(
      #factory.choice.processStatuses,
      if case.provider == 'audio' then 0 else 1,
      'raw status is independent of analysis'
    )
    expect.equal(session:draw(), false, 'the renderer draws through the provider outage')
    expect.truthy(live(native.events.render.shaderAcquisitions, 'released') == 3, 'the renderer keeps its shaders')
    if case.status then
      expect.truthy(textContains(native, case.status), 'the control panel reports the missing provider')
    end
    session.instances[case.provider]:enable()
    session.runtime:drain()
    step(native, source, nil, pcm)
    step(native, source, nil, pcm)
    local recovered = services()
    expect.equal(factory.choice.attended, process, case.provider .. ' recovery retains the attended process')
    expect.equal(factory.choice.response, 0.25, 'child reactivation retains response choices')
    if case.unavailable.controls then
      expect.equal(vrUi.describe(recovered.ui, panelName).visible, false, 'recovered controls start closed')
      open(recovered)
    end
    session:draw()
    sameTotals(native, recovered, baseline, case.provider .. ' recovery')
    expect.equal(#testing.takeReports(), 0, 'provider recovery leaves no plugin failure')
  end

  local meshes = table.clone(native.events.render.meshAcquisitions)
  local shaders = table.clone(native.events.render.shaderAcquisitions)
  session.instances.frame:disable()
  session.runtime:drain()
  expect.truthy(session.instances[backdropName]:state() ~= 'active', 'a frame outage withdraws the renderer itself')
  expect.equal(live(native.events.audio), 0, 'a frame outage releases both raw and analysis readers')
  for _, handle in meshes do
    expect.equal(handle.released, true, 'a frame outage releases mesh resources')
  end
  for _, handle in shaders do
    expect.equal(handle.released, true, 'a frame outage releases shader resources')
  end
  session.instances.frame:enable()
  session.runtime:drain()
  step(native, source, nil, pcm)
  step(native, source, nil, pcm)
  open(services())
  session:draw()
  sameTotals(native, services(), baseline, 'frame recovery')
  local parent = children(session.runtime:snapshot())
  expect.truthy(parent.activationId ~= initialParent.activationId, 'frame recovery creates a fresh renderer activation')
  local frameErrors: { string } = {}
  for _, report in native.events.reported do
    frameErrors[#frameErrors + 1] = report.message .. '\n' .. report.traceback
  end
  expect.equal(#frameErrors, 0, 'outages leave no frame errors: ' .. table.concat(frameErrors, '\n'))
  session:close()
  native.assertResourcesReleased()
end)

-- Source reload starts a new contract epoch, so no later case uses the previous module fixtures.
test(
  'ten production source reloads release backdrop generations and reset only source-reloaded choices',
  tenSourceReloads
)

return test
