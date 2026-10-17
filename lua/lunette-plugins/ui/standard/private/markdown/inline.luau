-- Parses Markdown inline content into spans and flattens spans into styled runs. The block parser calls it for
-- headings, paragraphs, and table cells. `parse.luau` states the supported syntax and its limitations.

local inline = {}

export type Inline =
  { read kind: 'text', read text: string }
  | { read kind: 'code', read text: string }
  | { read kind: 'emphasis', read children: { read [number]: Inline } }
  | { read kind: 'strong', read children: { read [number]: Inline } }
  | { read kind: 'link', read target: string, read children: { read [number]: Inline } }
  | { read kind: 'break' }

export type Content = { read [number]: Inline }

-- A span of text in one combination of styles, for a renderer that draws one style per node. A break is a run
-- whose text is a newline.
export type Run = {
  read text: string,
  read strong: boolean,
  read emphasis: boolean,
  read code: boolean,
  read link: string?,
}

type Style = { strong: boolean, emphasis: boolean, code: boolean, link: string? }

-- Links parse their text as inline content.
local parseInline: (text: string) -> { Inline }
local flattenRuns: (content: Content, style: Style, into: { Run }) -> ()

-- Parses inline content. Line endings inside the text are soft breaks, or hard breaks after two spaces or a
-- backslash.
function inline.parse(text: string): { Inline }
  return parseInline(text)
end

-- Flattens spans into runs, merging neighbours of the same style.
function inline.runs(content: Content): { Run }
  local list: { Run } = {}
  flattenRuns(content, { strong = false, emphasis = false, code = false, link = nil }, list)
  return list
end

-- The text content of spans, with a break as a newline.
function inline.text(content: Content): string
  local parts: { string } = {}
  for _, run in inline.runs(content) do
    table.insert(parts, run.text)
  end
  return table.concat(parts)
end

-- An item of the parser's working list: finished spans, literal text, and emphasis delimiter runs.
type Delimiter = {
  kind: 'delimiter',
  char: string,
  count: number,
  original: number,
  canOpen: boolean,
  canClose: boolean,
}
type Piece = { kind: 'span', span: Inline } | { kind: 'literal', text: string } | Delimiter

local function skipSpace(text: string, index: number): number
  return index + #(string.match(text, '^[ \t\n]*', index) :: string)
end

local function isSpace(char: string): boolean
  return char == '' or string.find(char, '%s') ~= nil
end

local function isPunctuation(char: string): boolean
  return char ~= '' and string.find(char, '%p') ~= nil
end

-- A code span runs to the next backtick run of the same length. Without one, the opening run is literal.
local function codeSpan(text: string, start: number): (Inline?, number)
  local run = string.match(text, '^`+', start) :: string
  local searchFrom = start + #run
  while true do
    local first, last = string.find(text, '`+', searchFrom)
    if not first or not last then
      return nil, start + #run
    end
    if last - first + 1 == #run then
      local content = string.gsub(string.sub(text, start + #run, first - 1), '\n', ' ')
      if string.find(content, '^ .* $') and not string.find(content, '^ +$') then
        content = string.sub(content, 2, -2)
      end
      return { kind = 'code', text = content }, last + 1
    end
    searchFrom = last + 1
  end
end

local function autolink(text: string, start: number): (Inline?, number)
  local uri = string.match(text, '^<(%a[%w+.%-]+:[^%s<>]*)>', start)
  if uri and #(string.match(uri, '^[^:]*') :: string) <= 32 then
    local span: Inline = { kind = 'link', target = uri, children = { { kind = 'text', text = uri } } }
    return span, start + #uri + 2
  end
  local email = string.match(text, "^<([%w.!#$%%&'*+/=?^_`{|}~%-]+@[%w%-]+%.[%w.%-]+)>", start)
  if email then
    local span: Inline = { kind = 'link', target = 'mailto:' .. email, children = { { kind = 'text', text = email } } }
    return span, start + #email + 2
  end
  return nil, start
end

local function unescape(text: string): string
  return (string.gsub(text, '\\(%p)', '%1'))
end

-- The closing bracket of a link's text, skipping escapes and code spans and counting nested brackets.
local function matchingBracket(text: string, start: number): number?
  local depth = 0
  local index = start
  while index <= #text do
    local char = string.sub(text, index, index)
    if char == '\\' then
      index += 2
    elseif char == '`' then
      local span, after = codeSpan(text, index)
      index = if span then after else index + #(string.match(text, '^`+', index) :: string)
    else
      if char == '[' then
        depth += 1
      elseif char == ']' then
        depth -= 1
        if depth == 0 then
          return index
        end
      end
      index += 1
    end
  end
  return nil
end

-- Links cannot contain links, so a nested link keeps its text and loses its target.
local function withoutLinks(content: Content): { Inline }
  local list: { Inline } = {}
  for _, span in content do
    if span.kind == 'link' then
      for _, child in withoutLinks(span.children) do
        list[#list + 1] = child
      end
    elseif span.kind == 'emphasis' then
      local copy: Inline = { kind = 'emphasis', children = withoutLinks(span.children) }
      list[#list + 1] = copy
    elseif span.kind == 'strong' then
      local copy: Inline = { kind = 'strong', children = withoutLinks(span.children) }
      list[#list + 1] = copy
    else
      list[#list + 1] = span
    end
  end
  return list
end

-- The destination of an inline link, from just inside its parenthesis: angle-bracketed, or a run without spaces
-- whose parentheses balance. Returns the index after it.
local function destination(text: string, start: number): (string?, number)
  if string.sub(text, start, start) == '<' then
    local inside = string.match(text, '^<([^<>\n]*)>', start)
    if not inside then
      return nil, start
    end
    return inside, start + #inside + 2
  end
  local index = start
  local depth = 0
  while index <= #text do
    local char = string.sub(text, index, index)
    if char == '\\' and isPunctuation(string.sub(text, index + 1, index + 1)) then
      index += 2
    elseif isSpace(char) then
      break
    elseif char == '(' then
      depth += 1
      index += 1
    elseif char == ')' then
      if depth == 0 then
        break
      end
      depth -= 1
      index += 1
    else
      index += 1
    end
  end
  return string.sub(text, start, index - 1), index
end

-- An inline link: bracketed text followed directly by a parenthesised destination and an optional title.
local function link(text: string, start: number): (Inline?, number)
  local close = matchingBracket(text, start)
  if not close or string.sub(text, close + 1, close + 1) ~= '(' then
    return nil, start
  end
  local target, index = destination(text, skipSpace(text, close + 2))
  if not target then
    return nil, start
  end
  local after = skipSpace(text, index)
  local quote = string.sub(text, after, after)
  if after > index and (quote == '"' or quote == "'" or quote == '(') then
    local titleEnd = string.find(text, if quote == '(' then ')' else quote, after + 1, true)
    if not titleEnd then
      return nil, start
    end
    after = skipSpace(text, titleEnd + 1)
  end
  if string.sub(text, after, after) ~= ')' then
    return nil, start
  end
  local label = string.sub(text, start + 1, close - 1)
  local span: Inline = { kind = 'link', target = unescape(target), children = withoutLinks(parseInline(label)) }
  return span, after + 1
end

-- Classifies a delimiter run by the characters around it, as CommonMark's flanking rules do.
local function delimiterRun(text: string, start: number, count: number, char: string): Delimiter
  local before = string.sub(text, start - 1, start - 1)
  local after = string.sub(text, start + count, start + count)
  local left = not isSpace(after) and (not isPunctuation(after) or isSpace(before) or isPunctuation(before))
  local right = not isSpace(before) and (not isPunctuation(before) or isSpace(after) or isPunctuation(after))
  local canOpen, canClose = left, right
  if char == '_' then
    canOpen = left and (not right or isPunctuation(before))
    canClose = right and (not left or isPunctuation(after))
  end
  return {
    kind = 'delimiter',
    char = char,
    count = count,
    original = count,
    canOpen = canOpen,
    canClose = canClose,
  }
end

-- Converts a range of pieces to spans, turning unmatched delimiters into text and merging neighbouring text.
local function toInlines(pieces: { Piece }, first: number, last: number): { Inline }
  local list: { Inline } = {}
  local function text(value: string): ()
    if value == '' then
      return
    end
    local previous = list[#list]
    local merged: Inline = if previous and previous.kind == 'text'
      then { kind = 'text', text = previous.text .. value }
      else { kind = 'text', text = value }
    list[if previous and previous.kind == 'text' then #list else #list + 1] = merged
  end
  for index = first, last do
    local piece = pieces[index]
    if piece.kind == 'literal' then
      text(piece.text)
    elseif piece.kind == 'delimiter' then
      text(string.rep(piece.char, piece.count))
    else
      local span = piece.span
      if span.kind == 'text' then
        text(span.text)
      else
        list[#list + 1] = span
      end
    end
  end
  return list
end

local function findOpener(pieces: { Piece }, closerIndex: number, closer: Delimiter): number?
  for index = closerIndex - 1, 1, -1 do
    local opener = pieces[index]
    if opener.kind == 'delimiter' and opener.char == closer.char and opener.canOpen and opener.count > 0 then
      -- The rule of three: a run that can both open and close does not pair with another when their combined
      -- length is a multiple of three, unless both lengths are.
      local both = opener.canClose or closer.canOpen
      local sum = opener.original + closer.original
      if not both or sum % 3 ~= 0 or (opener.original % 3 == 0 and closer.original % 3 == 0) then
        return index
      end
    end
  end
  return nil
end

-- Pairs delimiter runs into emphasis and strong spans, as CommonMark's process-emphasis procedure does.
local function processEmphasis(pieces: { Piece }): ()
  local index = 1
  while index <= #pieces do
    local closer = pieces[index]
    local openerIndex = if closer.kind == 'delimiter'
        and closer.canClose
        and closer.count > 0
      then findOpener(pieces, index, closer)
      else nil
    if openerIndex and closer.kind == 'delimiter' then
      local opener = pieces[openerIndex] :: Delimiter
      local used = if opener.count >= 2 and closer.count >= 2 then 2 else 1
      opener.count -= used
      closer.count -= used
      local children = toInlines(pieces, openerIndex + 1, index - 1)
      for _ = openerIndex + 1, index - 1 do
        table.remove(pieces, openerIndex + 1)
      end
      local span: Inline = if used == 2
        then { kind = 'strong', children = children }
        else { kind = 'emphasis', children = children }
      local piece: Piece = { kind = 'span', span = span }
      table.insert(pieces, openerIndex + 1, piece)
      -- The closer follows the new span; it is visited again while it has delimiters left.
      index = openerIndex + 2
      if opener.count == 0 then
        table.remove(pieces, openerIndex)
        index -= 1
      end
      if closer.count == 0 then
        table.remove(pieces, index)
      end
    else
      index += 1
    end
  end
end

-- Ends a line of literal text, removing its trailing spaces. Returns whether they made a hard break.
local function lineEnding(plain: { string }): boolean
  local text = table.concat(plain)
  table.clear(plain)
  plain[1] = (string.gsub(text, ' +$', ''))
  return string.find(text, '  $') ~= nil
end

function parseInline(text: string): { Inline }
  local pieces: { Piece } = {}
  local plain: { string } = {}
  local function flush(): ()
    if #plain > 0 then
      local piece: Piece = { kind = 'literal', text = table.concat(plain) }
      pieces[#pieces + 1] = piece
      table.clear(plain)
    end
  end
  local function span(value: Inline): ()
    flush()
    local piece: Piece = { kind = 'span', span = value }
    pieces[#pieces + 1] = piece
  end
  local index = 1
  while index <= #text do
    local char = string.sub(text, index, index)
    local nextChar = string.sub(text, index + 1, index + 1)
    if char == '\\' and nextChar == '\n' then
      span { kind = 'break' }
      index = skipSpace(text, index + 2)
    elseif char == '\\' and isPunctuation(nextChar) then
      table.insert(plain, nextChar)
      index += 2
    elseif char == '\n' then
      if lineEnding(plain) then
        span { kind = 'break' }
      else
        table.insert(plain, ' ')
      end
      index = skipSpace(text, index + 1)
    elseif char == '`' then
      local found, after = codeSpan(text, index)
      if found then
        span(found)
      else
        table.insert(plain, string.sub(text, index, after - 1))
      end
      index = after
    elseif char == '<' or char == '[' then
      local found, after = (if char == '<' then autolink else link)(text, index)
      if found then
        span(found)
        index = after
      else
        table.insert(plain, char)
        index += 1
      end
    elseif char == '*' or char == '_' then
      flush()
      local run = string.match(text, '^%' .. char .. '+', index) :: string
      pieces[#pieces + 1] = delimiterRun(text, index, #run, char)
      index += #run
    else
      table.insert(plain, char)
      index += 1
    end
  end
  flush()
  processEmphasis(pieces)
  return toInlines(pieces, 1, #pieces)
end

local function addRun(into: { Run }, text: string, style: Style): ()
  if text == '' then
    return
  end
  local previous = into[#into]
  if
    previous
    and previous.text ~= '\n'
    and previous.strong == style.strong
    and previous.emphasis == style.emphasis
    and previous.code == style.code
    and previous.link == style.link
  then
    text = previous.text .. text
    table.remove(into)
  end
  into[#into + 1] = {
    text = text,
    strong = style.strong,
    emphasis = style.emphasis,
    code = style.code,
    link = style.link,
  }
end

function flattenRuns(content: Content, style: Style, into: { Run }): ()
  for _, span in content do
    if span.kind == 'text' then
      addRun(into, span.text, style)
    elseif span.kind == 'code' then
      addRun(into, span.text, { strong = style.strong, emphasis = style.emphasis, code = true, link = style.link })
    elseif span.kind == 'break' then
      into[#into + 1] = { text = '\n', strong = false, emphasis = false, code = false, link = nil }
    else
      local inner: Style = {
        strong = style.strong or span.kind == 'strong',
        emphasis = style.emphasis or span.kind == 'emphasis',
        code = false,
        link = if span.kind == 'link' then span.target else style.link,
      }
      flattenRuns(span.children, inner, into)
    end
  end
end

return inline
