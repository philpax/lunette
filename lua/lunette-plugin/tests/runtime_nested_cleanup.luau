-- Covers resource authority after nested explicit disposal.
local testing = require '@testing'
local expect = testing.expect
local plugin = require('@lunette').plugin

local test = testing.suite()

for _, loading in { false, true } do
  for _, broken in { false, true } do
    for _, depth in { 1, 3 } do
      local title = (if broken then 'a caught nested inverse failure' else 'a successful nested inverse')
        .. ' at depth '
        .. depth
        .. (if loading then ' during load' else ' after load')
      test(title, function()
        local runtime = plugin.runtime()
        local context
        local outer
        local inverseCalls = 0
        local remainingCalls = 0
        local acquisitions = 0
        local childLoads = 0
        local child = plugin.define({}, {}, function()
          childLoads += 1
          return {}
        end)
        local function disposeAndCheck(owner)
          outer:dispose()
          expect.equal(inverseCalls, depth + 1, 'each nested inverse runs once')
          expect.equal(owner:active(), not broken, 'the owner authority after nested disposal')
          if broken then
            expect.raises(function()
              owner:effect(function()
                acquisitions += 1
                return function() end
              end)
            end, nil, 'a quarantined owner acquires no resource')
            expect.raises(function()
              owner:child(child, {}):enable()
            end, nil, 'a quarantined owner creates no child')
            expect.raises(function()
              owner:checkOwner(owner)
            end, nil, 'a quarantined owner registers no caller-owned resource')
          else
            owner:effect(function()
              acquisitions += 1
              return function()
                acquisitions -= 1
              end
            end)
            owner:child(child, {}):enable()
          end
        end
        local instance = runtime:use(
          plugin.define({}, {}, function(owner)
            context = owner
            owner:effect(function()
              return function()
                remainingCalls += 1
              end
            end)
            local nested = owner:effect(function()
              return function()
                inverseCalls += 1
                if broken then
                  error 'nested inverse failure'
                end
              end
            end)
            for _ = 1, depth do
              local inner = nested
              nested = owner:effect(function()
                return function()
                  inverseCalls += 1
                  local ok, failure = pcall(function()
                    inner:dispose()
                  end)
                  if not ok then
                    expect.truthy(
                      string.find(tostring(failure), 'nested inverse failure', 1, true),
                      'the caught failure'
                    )
                  end
                end
              end)
            end
            outer = nested
            if loading then
              disposeAndCheck(owner)
            end
            return {}
          end),
          {}
        )
        instance:enable()
        if not loading then
          disposeAndCheck(context)
        end
        if broken then
          expect.equal(acquisitions, 0, 'no acquisition runs after nested failure')
          expect.equal(childLoads, 0, 'no child loads after nested failure')
          instance:disable()
          expect.equal(instance:state(), 'quarantined', 'the failed activation remains quarantined')
          expect.raises(function()
            instance:enable()
          end, nil, 'a quarantined instance cannot retry')
        else
          expect.equal(acquisitions, 1, 'successful nested disposal restores acquisition')
          expect.equal(childLoads, 1, 'successful nested disposal restores child creation')
        end
        runtime:close()
        expect.equal(inverseCalls, depth + 1, 'shutdown repeats no disposed inverse')
        expect.equal(remainingCalls, 1, 'shutdown releases the remaining inverse')
        expect.equal(acquisitions, 0, 'shutdown releases acquired resources')
        expect.equal(#testing.takeReports(), 0, 'caught explicit failures produce no reports')
      end)
    end
  end
end

return test
