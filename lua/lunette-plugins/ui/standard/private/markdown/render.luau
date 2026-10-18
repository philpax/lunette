-- Maps a parsed Markdown tree to elements of the standard kinds and the Markdown view's own kinds.
--
-- A paragraph whose text has one style is one text node. A paragraph with styled spans is a column of lines, split
-- at hard breaks, and each line is a wrapping flow of words, one text node per word, so the words of a link wrap
-- with the words around them. A code span is one piece and wraps within itself. A word that changes style partway,
-- such as `**bold**,`, is a row of its pieces with no gap between them. The text kinds draw one style per node, so
-- emphasis is drawn as plain text, strong text takes the label role's heavier weight in body text, code spans take
-- the mono role on a sunken box, and links take the accent colour and call the view's `onLink`. Table cells and
-- headings use the same inline rendering. Keys are block, line, word, and piece indices, so a re-render of the same
-- source keeps every node.

local uiHost = require '@lunette-contracts/ui-host'
local parse = require './parse'

local render = {}

local element = uiHost.element

export type LinkHandler = (target: string) -> ()

-- The type role and colour role of text in its context, and its alignment.
type Tone = { style: string, color: string?, align: ('start' | 'center' | 'end')? }

local renderBlocks: (tree: { read [number]: parse.Block }, tone: Tone, onLink: LinkHandler, depth: number) -> { uiHost.Element }

-- The elements of a document, keyed by block index.
function render.document(tree: { read [number]: parse.Block }, onLink: LinkHandler): { uiHost.Element }
  return renderBlocks(tree, { style = 'body' }, onLink, 0)
end

-- Inline content.

type Piece = { text: string, run: parse.Run }

local function plain(runs: { parse.Run }): boolean
  for _, run in runs do
    if run.strong or run.emphasis or run.code or run.link then
      return false
    end
  end
  return true
end

-- Splits runs into lines at breaks, and lines into words at whitespace. A word is the pieces of runs between
-- whitespace, so it can span a change of style.
local function linesOf(runs: { parse.Run }): { { { Piece } } }
  local lines: { { { Piece } } } = { {} }
  local word: { Piece }? = nil
  local function close(): ()
    if word then
      table.insert(lines[#lines], word)
      word = nil
    end
  end
  for _, run in runs do
    if run.text == '\n' then
      close()
      local line: { { Piece } } = {}
      table.insert(lines, line)
    elseif run.code then
      -- A code span stays one piece, so its sunken box is not broken at its spaces.
      local current = word or {}
      table.insert(current, { text = run.text, run = run })
      word = current
    else
      local index = 1
      while index <= #run.text do
        local first, last = string.find(run.text, '%s+', index)
        local segment = string.sub(run.text, index, (first or #run.text + 1) - 1)
        if segment ~= '' then
          local current = word or {}
          table.insert(current, { text = segment, run = run })
          word = current
        end
        if first and last then
          close()
          index = last + 1
        else
          index = #run.text + 1
        end
      end
    end
  end
  close()
  return lines
end

local function pieceElement(piece: Piece, key: string, tone: Tone, onLink: LinkHandler): uiHost.Element
  local run = piece.run
  local target = run.link
  local style = if run.code then 'mono' elseif run.strong and tone.style == 'body' then 'label' else tone.style
  return element('lunette/markdown-span', {
    key = key,
    text = piece.text,
    style = style,
    color = if target then 'accent' else tone.color,
    code = run.code,
    onActivate = if target
      then function()
        onLink(target)
      end
      else nil,
  })
end

local function wordElement(word: { Piece }, key: string, tone: Tone, onLink: LinkHandler): uiHost.Element
  if #word == 1 then
    return pieceElement(word[1], key, tone, onLink)
  end
  local pieces: { uiHost.Element } = {}
  for index, piece in word do
    pieces[index] = pieceElement(piece, tostring(index), tone, onLink)
  end
  return element('lunette/row', { key = key, align = 'baseline', pieces })
end

local function flowElement(words: { { Piece } }, key: string, tone: Tone, onLink: LinkHandler): uiHost.Element
  local children: { uiHost.Element } = {}
  for index, word in words do
    children[index] = wordElement(word, tostring(index), tone, onLink)
  end
  return element('lunette/markdown-flow', { key = key, style = tone.style, align = tone.align, children })
end

local function inlineElement(content: parse.Content, key: string, tone: Tone, onLink: LinkHandler): uiHost.Element
  local runs = parse.runs(content)
  if plain(runs) then
    return element('lunette/text', {
      key = key,
      text = parse.inlineText(content),
      style = tone.style,
      color = tone.color,
      align = tone.align,
    })
  end
  local lines = linesOf(runs)
  if #lines == 1 then
    return flowElement(lines[1], key, tone, onLink)
  end
  local children: { uiHost.Element } = {}
  for index, words in lines do
    children[index] = flowElement(words, tostring(index), tone, onLink)
  end
  return element('lunette/column', { key = key, children })
end

-- Blocks.

local HEADING_STYLES = { 'title', 'heading' }
local BULLETS = { '•', '–' }
local ALIGN: { [parse.Alignment]: ('start' | 'center' | 'end')? } = { left = 'start', center = 'center', right = 'end' }

local function listElement(
  block: {
    read ordered: boolean,
    read start: number,
    read items: { read [number]: { read [number]: parse.Block } },
  },
  key: string,
  tone: Tone,
  onLink: LinkHandler,
  depth: number
): uiHost.Element
  local last = block.start + #block.items - 1
  -- The marker column fits the widest number, so the items' text lines up.
  local markerWidth = if block.ordered then (#tostring(last) + 1) * 0.0075 else 0.01
  local rows: { uiHost.Element } = {}
  for index, item in block.items do
    local marker = if block.ordered then `{block.start + index - 1}.` else BULLETS[(depth % #BULLETS) + 1]
    rows[index] = element('lunette/row', {
      key = tostring(index),
      gap = 'sm',
      align = 'start',
      element('lunette/text', {
        key = 'marker',
        text = marker,
        style = 'body',
        color = 'muted',
        align = if block.ordered then 'end' else 'start',
        basis = markerWidth,
        shrink = 0,
        wrap = false,
      }),
      element('lunette/column', {
        key = 'content',
        grow = 1,
        shrink = 1,
        gap = 'sm',
        renderBlocks(item, tone, onLink, depth + 1),
      }),
    })
  end
  return element('lunette/column', { key = key, gap = 'xs', rows })
end

local function tableElement(
  block: {
    read alignments: { read [number]: parse.Alignment },
    read header: { read [number]: parse.Content },
    read rows: { read [number]: { read [number]: parse.Content } },
  },
  key: string,
  onLink: LinkHandler
): uiHost.Element
  local function cells(row: { read [number]: parse.Content }, tone: Tone): { uiHost.Element }
    local list: { uiHost.Element } = {}
    for column, content in row do
      local cellTone: Tone = { style = tone.style, color = tone.color, align = ALIGN[block.alignments[column]] }
      list[column] = element('lunette/markdown-cell', {
        key = tostring(column),
        inlineElement(content, 'content', cellTone, onLink),
      })
    end
    return list
  end
  local rows: { uiHost.Element } = {}
  for index, row in block.rows do
    rows[index] = element('lunette/markdown-table-row', { key = tostring(index), cells(row, { style = 'body' }) })
  end
  return element('lunette/column', {
    key = key,
    gap = 'xs',
    element('lunette/table-header', {
      key = 'header',
      cells(block.header, { style = 'label', color = 'sectionInk' }),
    }),
    element('lunette/column', { key = 'rows', rows }),
  })
end

local function blockElement(
  block: parse.Block,
  key: string,
  tone: Tone,
  onLink: LinkHandler,
  depth: number
): uiHost.Element
  if block.kind == 'heading' then
    local headingTone: Tone = { style = HEADING_STYLES[block.level] or 'label', color = tone.color }
    return inlineElement(block.content, key, headingTone, onLink)
  elseif block.kind == 'paragraph' then
    return inlineElement(block.content, key, tone, onLink)
  elseif block.kind == 'quote' then
    local quoted: Tone = { style = tone.style, color = 'muted' }
    return element('lunette/markdown-quote', { key = key, renderBlocks(block.blocks, quoted, onLink, depth) })
  elseif block.kind == 'list' then
    return listElement(block, key, tone, onLink, depth)
  elseif block.kind == 'code' then
    return element('lunette/markdown-code', {
      key = key,
      element('lunette/text', { key = 'text', text = block.text, style = 'mono' }),
    })
  elseif block.kind == 'table' then
    return tableElement(block, key, onLink)
  end
  return element('lunette/separator', { key = key })
end

function renderBlocks(
  tree: { read [number]: parse.Block },
  tone: Tone,
  onLink: LinkHandler,
  depth: number
): { uiHost.Element }
  local list: { uiHost.Element } = {}
  for index, block in tree do
    list[index] = blockElement(block, tostring(index), tone, onLink, depth)
  end
  return list
end

return render
