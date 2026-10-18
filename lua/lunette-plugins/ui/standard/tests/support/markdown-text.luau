-- Extracts parsed content for the Markdown parser's content-preservation properties.
local parse = require '../../private/markdown/parse'

local text = {}
local collect: (tree: { read [number]: parse.Block }, into: { string }) -> ()

function text.document(tree: { read [number]: parse.Block }): string
  local parts: { string } = {}
  collect(tree, parts)
  return table.concat(parts, '\n')
end

local function row(cells: { read [number]: parse.Content }): string
  local parts: { string } = {}
  for _, cell in cells do
    table.insert(parts, parse.inlineText(cell))
  end
  return table.concat(parts, ' ')
end

function collect(tree: { read [number]: parse.Block }, into: { string }): ()
  for _, block in tree do
    if block.kind == 'heading' or block.kind == 'paragraph' then
      table.insert(into, parse.inlineText(block.content))
    elseif block.kind == 'quote' then
      collect(block.blocks, into)
    elseif block.kind == 'list' then
      for _, item in block.items do
        collect(item, into)
      end
    elseif block.kind == 'code' then
      table.insert(into, block.text)
    elseif block.kind == 'table' then
      table.insert(into, row(block.header))
      for _, cells in block.rows do
        table.insert(into, row(cells))
      end
    end
  end
end

return text
