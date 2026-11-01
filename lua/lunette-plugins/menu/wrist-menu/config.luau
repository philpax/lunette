local schema = require '@lunette-plugin/schema'

local positive = schema.number { positive = true }
local hand = schema.enum<<'left' | 'right'>> { 'left', 'right' }
local expanded = schema.object {
  width = schema.default(positive)(0.32),
  height = schema.default(positive)(0.4),
}
local angle = schema.number { minimum = 0, maximum = math.pi }
-- The menu fades as it turns away from the head, so it is not seen from behind or edge-on.
local facing = schema.refine(schema.object {
  -- Radians between the menu's face and the direction to the head within which it is fully opaque.
  visible = schema.default(angle)(1.25),
  -- Radians past which it is transparent and takes no input.
  hidden = schema.default(angle)(math.pi / 2),
})(function(value: { read visible: number, read hidden: number }): ()
  if value.hidden <= value.visible then
    error('hidden is not wider than visible', 0)
  end
end)
local descriptor = schema.object {
  hand = schema.default(hand) 'left',
  size = schema.default(positive)(0.115),
  offset = schema.default(schema.vector())(vector.pack(-0.03, -0.01, 0.125)),
  expanded = schema.default(expanded)(expanded.parse {}),
  -- Ids of menu actions shown as buttons above the closed menu button, top first. An action that is not registered
  -- shows no button.
  shortcuts = schema.default(schema.array(schema.string())) { 'desktop/panels/hide' },
  facing = schema.default(facing)(facing.parse {}),
}

export type Hand = schema.Output<typeof(hand)>
export type Config = schema.Input<typeof(descriptor)>
export type Settings = schema.Output<typeof(descriptor)>

return { schema = descriptor }
