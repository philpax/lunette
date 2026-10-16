-- The standard kinds' constructors, which the standard kinds provider publishes. Consumers obtain them through
-- `context:require` and pass them to the React-like library's mount, where `ui.useComponents` reads them.
-- Lengths that accept a token name, such as a gap of 'md', also accept metres.

local plugin = require '@lunette-plugin'
local uiHost = require '@lunette-contracts/ui-host'

local uiComponents = {}

export type Constructor = uiHost.Constructor

-- A choice among options, as a segmented control, a radio group, a dropdown, or tabs shows it.
export type Option = {
  read id: string,
  read label: string,
  read disabledReason: string?,
}

-- A named level on a slider; the slider snaps to it when released near it.
export type Detent = { read value: number, read label: string }

export type Column = { read id: string, read label: string, read width: number? }
export type TableRow = { read id: string, read cells: { read [number]: string } }

export type Service = {
  -- Structure.
  read Panel: Constructor,
  read Header: Constructor,
  read Body: Constructor,
  read Section: Constructor,
  read Column: Constructor,
  read Row: Constructor,
  read Card: Constructor,
  read Separator: Constructor,
  read Spacer: Constructor,
  read ScrollBox: Constructor,
  read Tabs: Constructor,
  -- Display.
  read Text: Constructor,
  read Progress: Constructor,
  -- Actions.
  read Button: Constructor,
  read Chip: Constructor,
  -- Choices.
  read Toggle: Constructor,
  read Checkbox: Constructor,
  read RadioGroup: Constructor,
  read Segmented: Constructor,
  read Dropdown: Constructor,
  -- Values.
  read Slider: Constructor,
  -- Collections.
  read List: Constructor,
  read ListRow: Constructor,
  read Table: Constructor,
  -- Text input.
  read TextField: Constructor,
  -- Overlays: the content of dialog and follow panels.
  read Dialog: Constructor,
  read Toast: Constructor,
}

export type Capability = plugin.Capability<Service>

uiComponents.capability = plugin.capability<<Service>> { name = 'lunette/ui-components', version = 1 }

return uiComponents
