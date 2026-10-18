-- Parses Markdown into a tree of blocks whose text is inline spans. The parser is pure: it reads only its argument.
--
-- The supported subset follows CommonMark and the GitHub table extension: ATX and setext headings, paragraphs with
-- hard breaks, block quotes with lazy continuation, bullet and ordered lists nested by indentation, fenced and
-- indented code blocks, thematic breaks, and tables. Inline content, which `inline.luau` parses, has emphasis and
-- strong emphasis under the CommonMark delimiter rules, code spans, inline links, autolinks, and backslash escapes.
--
-- Limitations: HTML blocks and inline HTML are kept as literal text. Entity and numeric character references, such
-- as `&amp;`, are not decoded. Reference-style links and link reference definitions are not recognised and stay
-- literal. Images are not recognised: `![alt](src)` reads as a `!` followed by a link to the source. Strikethrough,
-- task list markers, and footnotes are literal text. List looseness is not recorded. Tabs in a line's leading
-- whitespace and after a list marker expand to the next multiple of four columns; tabs elsewhere are kept. Table
-- cells past the header's width are kept rather than dropped as GitHub does. No construct drops text: anything the
-- parser does not recognise remains in the tree as text.

local inline = require './inline'

local parse = {}

export type Inline = inline.Inline
export type Content = inline.Content
export type Run = inline.Run
export type Alignment = 'none' | 'left' | 'center' | 'right'

export type Block =
  { read kind: 'heading', read level: number, read content: Content }
  | { read kind: 'paragraph', read content: Content }
  | { read kind: 'quote', read blocks: { read [number]: Block } }
  | {
    read kind: 'list',
    read ordered: boolean,
    read start: number,
    read items: { read [number]: { read [number]: Block } },
  }
  | { read kind: 'code', read info: string, read text: string }
  | { read kind: 'rule' }
  | {
    read kind: 'table',
    read alignments: { read [number]: Alignment },
    read header: { read [number]: Content },
    read rows: { read [number]: { read [number]: Content } },
  }

-- Quotes and list items parse their content as blocks.
local blocks: (source: { string }) -> { Block }
local lines: (source: string) -> { string }

-- Parses a whole document.
function parse.document(source: string): { Block }
  return blocks(lines(source))
end

-- Flattens inline spans into runs, merging neighbours of the same style.
parse.runs = inline.runs

-- The text content of inline spans, with a break as a newline.
parse.inlineText = inline.text

-- Lines.

local function trim(text: string): string
  return (string.gsub(string.gsub(text, '^%s+', ''), '%s+$', ''))
end

-- Spaces for whitespace that starts at a column, with tabs advanced to the next multiple of four.
local function spacesFor(whitespace: string, column: number): string
  local width = 0
  for index = 1, #whitespace do
    if string.sub(whitespace, index, index) == '\t' then
      width += 4 - (column + width) % 4
    else
      width += 1
    end
  end
  return string.rep(' ', width)
end

local function expandTabs(line: string): string
  local leading = string.match(line, '^[ \t]*') :: string
  if not string.find(leading, '\t', 1, true) then
    return line
  end
  return spacesFor(leading, 0) .. string.sub(line, #leading + 1)
end

local function indentOf(line: string): number
  return #(string.match(line, '^ *') :: string)
end

local function isBlank(line: string): boolean
  return string.find(line, '^%s*$') ~= nil
end

-- Removes up to `count` columns of leading spaces.
local function dedent(line: string, count: number): string
  return string.sub(line, math.min(indentOf(line), count) + 1)
end

-- Splits the source into lines, normalising CRLF and CR line endings and expanding tabs in leading whitespace.
function lines(source: string): { string }
  local normal = string.gsub(string.gsub(source, '\r\n', '\n'), '\r', '\n')
  local list: { string } = {}
  for line in string.gmatch(normal .. '\n', '([^\n]*)\n') do
    table.insert(list, expandTabs(line))
  end
  -- The final newline of a file ends its last line rather than starting an empty one.
  if string.sub(normal, -1) == '\n' then
    table.remove(list)
  end
  return list
end

-- Block starts.

type Fence = { char: string, length: number, indent: number, info: string }

local function fenceWith(line: string, pattern: string): Fence?
  local indent, marks, info = string.match(line, pattern)
  if not indent or not marks or not info then
    return nil
  end
  -- A backtick fence's info string cannot contain a backtick, so a code span at the start of a line is not a fence.
  if string.sub(marks, 1, 1) == '`' and string.find(info, '`', 1, true) then
    return nil
  end
  return { char = string.sub(marks, 1, 1), length = #marks, indent = #indent, info = trim(info) }
end

local function fenceOf(line: string): Fence?
  return fenceWith(line, '^( ? ? ?)(```+)(.*)$') or fenceWith(line, '^( ? ? ?)(~~~+)(.*)$')
end

local function closesFence(line: string, fence: Fence): boolean
  local marks = string.match(line, '^ ? ? ?([`~]+)%s*$')
  if not marks then
    return false
  end
  local other = if fence.char == '`' then '~' else '`'
  return string.sub(marks, 1, 1) == fence.char and not string.find(marks, other, 1, true) and #marks >= fence.length
end

type Heading = { level: number, text: string }

local function headingOf(line: string): Heading?
  local marks, rest = string.match(line, '^ ? ? ?(#+)(.*)$')
  if not marks or not rest or #marks > 6 then
    return nil
  end
  if rest ~= '' and not string.find(rest, '^[ \t]') then
    return nil
  end
  local text = trim(rest)
  -- A closing sequence of hashes is removed when a space precedes it or it is the whole content.
  if string.find(text, '^#+$') then
    text = ''
  else
    text = string.gsub(text, '[ \t]+#+$', '')
  end
  return { level = #marks, text = text }
end

local function isRule(line: string): boolean
  if indentOf(line) > 3 then
    return false
  end
  local compact = string.gsub(line, '[ \t]', '')
  if #compact < 3 then
    return false
  end
  return string.find(compact, '^%*+$') ~= nil
    or string.find(compact, '^%-+$') ~= nil
    or string.find(compact, '^_+$') ~= nil
end

local function quoteOf(line: string): string?
  local prefix, rest = string.match(line, '^( ? ? ?>)(.*)$')
  if not prefix or not rest then
    return nil
  end
  -- Tabs after the marker expand from their own column, and one optional space after the marker belongs to it.
  local leading = string.match(rest, '^[ \t]*') :: string
  local expanded = spacesFor(leading, #prefix) .. string.sub(rest, #leading + 1)
  if string.sub(expanded, 1, 1) == ' ' then
    return string.sub(expanded, 2)
  end
  return expanded
end

type Item = {
  -- The bullet character, or the ordered delimiter, which the items of one list share.
  marker: string,
  ordered: boolean,
  number: number,
  -- The column at which the item's content starts.
  content: number,
  first: string,
}

type Marker = { indent: string, label: string, marker: string, gap: string, rest: string, ordered: boolean }

local function markerOf(line: string): Marker?
  local indent, label, gap, rest = string.match(line, '^( ? ? ?)([-*+])([ \t]*)(.*)$')
  if indent and label and gap and rest then
    return { indent = indent, label = label, marker = label, gap = gap, rest = rest, ordered = false }
  end
  local digits, delimiter
  indent, digits, delimiter, gap, rest = string.match(line, '^( ? ? ?)(%d%d?%d?%d?%d?%d?%d?%d?%d?)([.)])([ \t]*)(.*)$')
  if indent and digits and delimiter and gap and rest then
    return { indent = indent, label = digits, marker = delimiter, gap = gap, rest = rest, ordered = true }
  end
  return nil
end

local function itemOf(line: string): Item?
  local found = markerOf(line)
  -- The marker is followed by whitespace or ends the line.
  if not found or (found.gap == '' and found.rest ~= '') then
    return nil
  end
  local number = if found.ordered then tonumber(found.label) :: number else 1
  local width = #found.indent + #found.label + (if found.ordered then 1 else 0)
  local spaces = spacesFor(found.gap, width)
  local item =
    { marker = found.marker, ordered = found.ordered, number = number, content = width + #spaces, first = found.rest }
  if found.rest == '' then
    item.content = width + 1
  elseif #spaces > 4 then
    -- Five or more spaces after the marker start indented code inside the item, so the content starts after one.
    item.content = width + 1
    item.first = string.rep(' ', #spaces - 1) .. found.rest
  end
  return item
end

-- Splits a table row at unescaped pipes, dropping the optional outer pipes. An escaped pipe becomes a pipe.
local function cellsOf(line: string): { string }
  local text = trim(line)
  local cells: { string } = {}
  local current: { string } = {}
  local index = if string.sub(text, 1, 1) == '|' then 2 else 1
  local closed = false
  while index <= #text do
    local char = string.sub(text, index, index)
    if char == '\\' and string.sub(text, index + 1, index + 1) == '|' then
      table.insert(current, '|')
      closed = false
      index += 2
    else
      if char == '|' then
        table.insert(cells, trim(table.concat(current)))
        current = {}
        closed = index == #text
      else
        table.insert(current, char)
        closed = false
      end
      index += 1
    end
  end
  if not closed then
    table.insert(cells, trim(table.concat(current)))
  end
  return cells
end

type TableStart = { header: { string }, alignments: { Alignment } }

-- A table starts with a header row and a delimiter row of the same width. Both contain a pipe, so a setext
-- underline or a rule under a paragraph is not a delimiter row.
local function tableOf(line: string, next: string?): TableStart?
  if not next or indentOf(line) > 3 or not string.find(line, '|', 1, true) or not string.find(next, '|', 1, true) then
    return nil
  end
  local alignments: { Alignment } = {}
  for index, cell in cellsOf(next) do
    if not string.find(cell, '^:?%-+:?$') then
      return nil
    end
    local left = string.sub(cell, 1, 1) == ':'
    local right = string.sub(cell, -1) == ':'
    alignments[index] = if left and right then 'center' elseif left then 'left' elseif right then 'right' else 'none'
  end
  local header = cellsOf(line)
  if #alignments == 0 or #header ~= #alignments then
    return nil
  end
  return { header = header, alignments = alignments }
end

-- Whether a line starts a block that ends a paragraph. A list item interrupts a paragraph only when it has content
-- and, if ordered, starts at one.
local function interrupts(line: string, next: string?): boolean
  if indentOf(line) > 3 then
    return false
  end
  if headingOf(line) or fenceOf(line) or quoteOf(line) or isRule(line) or tableOf(line, next) then
    return true
  end
  local item = itemOf(line)
  return item ~= nil and not isBlank(item.first) and (not item.ordered or item.number == 1)
end

-- Blocks.

local function indentedCode(source: { string }, start: number, into: { Block }): number
  local body: { string } = {}
  local index = start
  while index <= #source and (isBlank(source[index]) or indentOf(source[index]) >= 4) do
    table.insert(body, dedent(source[index], 4))
    index += 1
  end
  while #body > 0 and isBlank(body[#body]) do
    table.remove(body)
  end
  local block: Block = { kind = 'code', info = '', text = table.concat(body, '\n') }
  into[#into + 1] = block
  return index
end

-- An unclosed fence runs to the end of its container.
local function fencedCode(source: { string }, start: number, fence: Fence, into: { Block }): number
  local body: { string } = {}
  local index = start + 1
  while index <= #source do
    local line = source[index]
    index += 1
    if closesFence(line, fence) then
      break
    end
    table.insert(body, dedent(line, fence.indent))
  end
  local block: Block = { kind = 'code', info = fence.info, text = table.concat(body, '\n') }
  into[#into + 1] = block
  return index
end

local function blockQuote(source: { string }, start: number, into: { Block }): number
  local body: { string } = {}
  local index = start
  local lazy = false
  while index <= #source do
    local line = source[index]
    local content = quoteOf(line)
    if content ~= nil then
      table.insert(body, content)
      lazy = not isBlank(content) and indentOf(content) < 4 and fenceOf(content) == nil
    elseif lazy and not isBlank(line) and not interrupts(line, source[index + 1]) then
      -- A lazy continuation line continues the quoted paragraph without its marker.
      table.insert(body, line)
    else
      break
    end
    index += 1
  end
  local block: Block = { kind = 'quote', blocks = blocks(body) }
  into[#into + 1] = block
  return index
end

-- Collects the lines of one list item after its first, dedented to its content column. Returns the index after
-- them.
local function itemBody(source: { string }, start: number, item: Item, body: { string }): number
  local index = start
  local lazy = not isBlank(item.first)
  while index <= #source do
    local line = source[index]
    if isBlank(line) then
      -- A blank line belongs to the item only if indented content follows it.
      local after = index + 1
      while after <= #source and isBlank(source[after]) do
        after += 1
      end
      if after > #source or indentOf(source[after]) < item.content then
        break
      end
      table.insert(body, '')
      lazy = false
    elseif indentOf(line) >= item.content then
      table.insert(body, dedent(line, item.content))
      lazy = true
    elseif lazy and not interrupts(line, source[index + 1]) and not itemOf(line) then
      table.insert(body, line)
    else
      break
    end
    index += 1
  end
  return index
end

local function listBlock(source: { string }, start: number, first: Item, into: { Block }): number
  local items: { { Block } } = {}
  local index = start
  local item: Item? = first
  while item do
    local body: { string } = { item.first }
    index = itemBody(source, index + 1, item, body)
    table.insert(items, blocks(body))
    -- Blank lines between items keep the list going.
    local after = index
    while after <= #source and isBlank(source[after]) do
      after += 1
    end
    local candidate = if after <= #source and not isRule(source[after]) then itemOf(source[after]) else nil
    if candidate and candidate.marker == first.marker and candidate.ordered == first.ordered then
      index = after
      item = candidate
    else
      item = nil
    end
  end
  local block: Block = { kind = 'list', ordered = first.ordered, start = first.number, items = items }
  into[#into + 1] = block
  return index
end

local function tableBlock(source: { string }, start: number, header: TableStart, into: { Block }): number
  local rows: { { Content } } = {}
  local width = #header.alignments
  local index = start + 2
  while index <= #source do
    local line = source[index]
    if isBlank(line) or interrupts(line, source[index + 1]) then
      break
    end
    local row: { Content } = {}
    for column, cell in cellsOf(line) do
      row[column] = inline.parse(cell)
    end
    width = math.max(width, #row)
    table.insert(rows, row)
    index += 1
  end
  local alignments: { Alignment } = table.clone(header.alignments)
  local headerCells: { Content } = {}
  for column = 1, width do
    alignments[column] = alignments[column] or 'none'
    headerCells[column] = inline.parse(header.header[column] or '')
  end
  for _, row in rows do
    for column = #row + 1, width do
      row[column] = {}
    end
  end
  local block: Block = { kind = 'table', alignments = alignments, header = headerCells, rows = rows }
  into[#into + 1] = block
  return index
end

local function setextLevel(line: string): number?
  if indentOf(line) > 3 then
    return nil
  end
  if string.find(line, '^ *=+[ \t]*$') then
    return 1
  end
  if string.find(line, '^ *%-+[ \t]*$') then
    return 2
  end
  return nil
end

local function paragraph(source: { string }, start: number, into: { Block }): number
  local text: { string } = {}
  local index = start
  while index <= #source do
    local line = source[index]
    if isBlank(line) then
      break
    end
    if #text > 0 then
      local level = setextLevel(line)
      if level then
        local block: Block = { kind = 'heading', level = level, content = inline.parse(trim(table.concat(text, '\n'))) }
        into[#into + 1] = block
        return index + 1
      end
      if interrupts(line, source[index + 1]) then
        break
      end
    end
    table.insert(text, (string.gsub(line, '^ +', '')))
    index += 1
  end
  -- Trailing spaces on the last line are not a hard break.
  local joined = string.gsub(table.concat(text, '\n'), '[ \t]+$', '')
  local block: Block = { kind = 'paragraph', content = inline.parse(joined) }
  into[#into + 1] = block
  return index
end

function blocks(source: { string }): { Block }
  local list: { Block } = {}
  local index = 1
  while index <= #source do
    local line = source[index]
    local fence = fenceOf(line)
    local heading = headingOf(line)
    local item = itemOf(line)
    local tableStart = tableOf(line, source[index + 1])
    if isBlank(line) then
      index += 1
    elseif indentOf(line) >= 4 then
      index = indentedCode(source, index, list)
    elseif fence then
      index = fencedCode(source, index, fence, list)
    elseif heading then
      local block: Block = { kind = 'heading', level = heading.level, content = inline.parse(heading.text) }
      list[#list + 1] = block
      index += 1
    elseif quoteOf(line) then
      index = blockQuote(source, index, list)
    elseif isRule(line) then
      local block: Block = { kind = 'rule' }
      list[#list + 1] = block
      index += 1
    elseif item then
      index = listBlock(source, index, item, list)
    elseif tableStart then
      index = tableBlock(source, index, tableStart, list)
    else
      index = paragraph(source, index, list)
    end
  end
  return list
end

return parse
