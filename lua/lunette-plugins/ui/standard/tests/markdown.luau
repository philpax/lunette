local testing = require '@testing'
local parse = require '../private/markdown/parse'
local expect = testing.expect
local test = testing.suite()

-- A compact description of a tree, so a case states the whole expected structure in one string.
local describeBlocks: (tree: { read [number]: parse.Block }) -> string

local function describeInline(content: parse.Content): string
  local parts: { string } = {}
  for _, span in content do
    if span.kind == 'text' then
      table.insert(parts, span.text)
    elseif span.kind == 'code' then
      table.insert(parts, `\{code:{span.text}}`)
    elseif span.kind == 'emphasis' then
      table.insert(parts, `\{em:{describeInline(span.children)}}`)
    elseif span.kind == 'strong' then
      table.insert(parts, `\{strong:{describeInline(span.children)}}`)
    elseif span.kind == 'link' then
      table.insert(parts, `\{link {span.target}:{describeInline(span.children)}}`)
    else
      table.insert(parts, '{br}')
    end
  end
  return table.concat(parts)
end

local function describeRow(cells: { read [number]: parse.Content }): string
  local parts: { string } = {}
  for _, cell in cells do
    table.insert(parts, describeInline(cell))
  end
  return `({table.concat(parts, '|')})`
end

local function describeBlock(block: parse.Block): string
  if block.kind == 'heading' then
    return `h{block.level}({describeInline(block.content)})`
  elseif block.kind == 'paragraph' then
    return `p({describeInline(block.content)})`
  elseif block.kind == 'quote' then
    return `quote[{describeBlocks(block.blocks)}]`
  elseif block.kind == 'list' then
    local items: { string } = {}
    for _, item in block.items do
      table.insert(items, describeBlocks(item))
    end
    local name = if block.ordered then `ol{block.start}` else 'ul'
    return `{name}[{table.concat(items, '; ')}]`
  elseif block.kind == 'code' then
    return `code<{block.info}>({block.text})`
  elseif block.kind == 'table' then
    local rows = { describeRow(block.header) }
    for _, row in block.rows do
      table.insert(rows, describeRow(row))
    end
    return `table<{table.concat(block.alignments :: { string }, ',')}>{table.concat(rows)}`
  end
  return 'hr'
end

function describeBlocks(tree: { read [number]: parse.Block }): string
  local parts: { string } = {}
  for _, block in tree do
    table.insert(parts, describeBlock(block))
  end
  return table.concat(parts, ' ')
end

local function check(source: string, wanted: string, context: string?): ()
  expect.equal(describeBlocks(parse.document(source)), wanted, context or source)
end

test('empty and whitespace-only input give no blocks', function()
  check('', '')
  check('   \n\t\n  ', '')
  check('\r\n\r\n', '')
end)

test('ATX headings take one to six hashes and drop a closing sequence', function()
  check('# One', 'h1(One)')
  check('###### Six ######', 'h6(Six)')
  check('####### Seven', 'p(####### Seven)')
  check('#NoSpace', 'p(#NoSpace)')
  check('## Title #hash', 'h2(Title #hash)')
  check('#', 'h1()')
end)

test('setext underlines make headings of the paragraph above them', function()
  check('Title\n=====', 'h1(Title)')
  check('Sub\ntitle\n---', 'h2(Sub title)')
  check('---', 'hr')
end)

test('paragraph lines join with spaces, and blank lines separate paragraphs', function()
  check('one\ntwo\n\nthree', 'p(one two) p(three)')
end)

test('two trailing spaces or a backslash make a hard break', function()
  check('one  \ntwo\\\nthree', 'p(one{br}two{br}three)')
  check('trailing  ', 'p(trailing)')
end)

test('block quotes nest and continue lazily', function()
  check('> quoted\nlazy\n\n> > inner', 'quote[p(quoted lazy)] quote[quote[p(inner)]]')
  check('> # Heading\n> text', 'quote[h1(Heading) p(text)]')
end)

test('bullet lists group items by marker and nest by indentation', function()
  check('- one\n- two\n  - nested\n- three', 'ul[p(one); p(two) ul[p(nested)]; p(three)]')
  check('* a\n+ b', 'ul[p(a)] ul[p(b)]')
  check('- a\n\n- b', 'ul[p(a); p(b)]')
  check('- a\ncontinued', 'ul[p(a continued)]')
end)

test('ordered lists keep their start number and delimiter', function()
  check('3. three\n4. four', 'ol3[p(three); p(four)]')
  check('1) a\n2) b\n1. c', 'ol1[p(a); p(b)] ol1[p(c)]')
  check('1. outer\n   1. inner\n   2. second', 'ol1[p(outer) ol1[p(inner); p(second)]]')
end)

test('an ordered item interrupts a paragraph only when it starts at one', function()
  check('text\n2. not a list', 'p(text 2. not a list)')
  check('text\n1. a list', 'p(text) ol1[p(a list)]')
end)

test('a list item holds code and paragraphs separated by blank lines', function()
  check('- item\n\n  more\n\n      code', 'ul[p(item) p(more) code<>(code)]')
end)

test('fenced code keeps its content verbatim and reads an info string', function()
  check('```lua\nlocal x = *1*\n\n# not a heading\n```', 'code<lua>(local x = *1*\n\n# not a heading)')
  check('~~~\n```\n~~~', 'code<>(```)')
  check('````\n```\n````', 'code<>(```)')
end)

test('an unclosed fence runs to the end of the document', function()
  check('text\n```\ncode\nmore', 'p(text) code<>(code\nmore)')
end)

test('indented code keeps interior blank lines and drops trailing ones', function()
  check('    one\n\n    two\n\n\nafter', 'code<>(one\n\ntwo) p(after)')
end)

test('indented lines continue a paragraph rather than starting code', function()
  check('text\n    still text', 'p(text still text)')
end)

test('thematic breaks take three or more of one character', function()
  check('***\n- - -\n___', 'hr hr hr')
  check('**', 'p(**)')
end)

test('tables read alignments, header cells, and body rows', function()
  check(
    '| Name | Size | Kind |\n|:-----|-----:|:----:|\n| a | 1 | x |\n| b | 2 |',
    'table<left,right,center>(Name|Size|Kind)(a|1|x)(b|2|)'
  )
end)

test('a table without body rows is a header alone', function()
  check('a | b\n--|--', 'table<none,none>(a|b)')
end)

test('table cells keep escaped pipes, inline styles, and extra cells', function()
  check('a | b\n-|-\n`x\\|y` | **z** | extra', 'table<none,none,none>(a|b|)({code:x|y}|{strong:z}|extra)')
end)

test('a delimiter row of a different width is not a table', function()
  check('a | b\n-|-|-', 'p(a | b -|-|-)')
end)

test('emphasis and strong emphasis follow the delimiter rules', function()
  check('*em* _em_ **strong** __strong__', 'p({em:em} {em:em} {strong:strong} {strong:strong})')
  check('***both***', 'p({em:{strong:both}})')
  check('*nested **strong** inside*', 'p({em:nested {strong:strong} inside})')
  check('snake_case_word', 'p(snake_case_word)')
  check('2 * 3 * 4', 'p(2 * 3 * 4)')
end)

test('emphasis that does not close stays literal', function()
  check('*open', 'p(*open)')
  check('**open *em*', 'p(**open {em:em})')
  check('closed* only', 'p(closed* only)')
end)

test('code spans take matching backtick runs and are literal inside', function()
  check('`*not em*`', 'p({code:*not em*})')
  check('`` a ` b ``', 'p({code:a ` b})')
  check('`unclosed', 'p(`unclosed)')
end)

test('links take text, a destination, and an optional title', function()
  check('[the docs](https://example.org/a_(b))', 'p({link https://example.org/a_(b):the docs})')
  check('[**bold** text](<with space> "Title")', 'p({link with space:{strong:bold} text})')
  check('[unclosed](nowhere', 'p([unclosed](nowhere)')
  check('[reference][label]', 'p([reference][label])')
end)

test('autolinks take a URI or an email address', function()
  check('<https://example.org>', 'p({link https://example.org:https://example.org})')
  check('<someone@example.org>', 'p({link mailto:someone@example.org:someone@example.org})')
  check('<not a link>', 'p(<not a link>)')
end)

test('backslash escapes make syntax characters literal', function()
  check('\\*not em\\* \\# \\[x\\](y)', 'p(*not em* # [x](y))')
  check('\\a stays', 'p(\\a stays)')
end)

test('CRLF and CR line endings read as line feeds', function()
  check('# Head\r\n\r\npara\r\nline\rend', 'h1(Head) p(para line end)')
end)

test('tabs in leading whitespace expand to four columns', function()
  check('\tcode', 'code<>(code)')
  check('-\titem\n\tnested', 'ul[p(item nested)]')
  check('> \tquoted', 'quote[p(quoted)]')
  check('>\t\tcode', 'quote[code<>(  code)]')
end)

test('runs merge neighbouring text of the same style and keep breaks apart', function()
  local runs = parse.runs(parse.document('a *b* c `d` [e](f)  \ng')[1].content :: parse.Content)
  local described: { string } = {}
  for _, run in runs do
    local flags = (if run.emphasis then 'e' else '') .. (if run.code then 'c' else '') .. (run.link or '')
    table.insert(described, `{run.text}/{flags}`)
  end
  expect.equal(table.concat(described, ' '), 'a / b/e  c / d/c  / e/f \n/ g/')
end)

-- A small deterministic generator, so the property's cases are reproducible.
local function generator(seed: number): (number) -> number
  local state = seed
  return function(limit: number): number
    state = (state * 1103515245 + 12345) % 2147483648
    return state % limit + 1
  end
end

local WORDS = { 'alpha', 'bravo', 'charlie', 'delta', 'echo', 'foxtrot', 'golf', 'hotel', 'india', 'juliet' }

-- Builds a random document from content words wrapped in syntax, and records every content word it uses.
local function document(random: (number) -> number, used: { string }): string
  local function word(): string
    local chosen = WORDS[random(#WORDS)] .. tostring(#used + 1)
    table.insert(used, chosen)
    return chosen
  end
  local function phrase(): string
    local parts: { string } = {}
    for _ = 1, random(4) do
      local choice = random(8)
      local text = word()
      if choice == 1 then
        text = `*{text}*`
      elseif choice == 2 then
        text = `**{text}**`
      elseif choice == 3 then
        text = `\`{text}\``
      elseif choice == 4 then
        text = `[{text}](https://example.org/target)`
      elseif choice == 5 then
        text = `_{text}`
      end
      table.insert(parts, text)
    end
    return table.concat(parts, ' ')
  end
  local blocks: { string } = {}
  for _ = 1, random(6) do
    local choice = random(9)
    if choice == 1 then
      table.insert(blocks, `{string.rep('#', random(6))} {phrase()}`)
    elseif choice == 2 then
      table.insert(blocks, `> {phrase()}\n{phrase()}`)
    elseif choice == 3 then
      table.insert(blocks, `- {phrase()}\n  - {phrase()}\n- {phrase()}`)
    elseif choice == 4 then
      table.insert(blocks, `1. {phrase()}\n2) {phrase()}`)
    elseif choice == 5 then
      table.insert(blocks, `\`\`\`info\n{phrase()}\n\`\`\``)
    elseif choice == 6 then
      table.insert(blocks, `| {phrase()} | {phrase()} |\n|---|:-:|\n| {phrase()} | {phrase()} |`)
    elseif choice == 7 then
      table.insert(blocks, `{phrase()}\n---`)
    elseif choice == 8 then
      table.insert(blocks, `    {phrase()}`)
    else
      table.insert(blocks, `{phrase()}  \n{phrase()}\t\n{phrase()}`)
    end
  end
  local separator = if random(2) == 1 then '\n\n' else '\r\n\r\n'
  return table.concat(blocks, separator)
end

test('the plain text of a parse contains every content word of the input', function()
  for seed = 1, 200 do
    local used: { string } = {}
    local source = document(generator(seed), used)
    local text = parse.plainText(parse.document(source))
    for _, word in used do
      expect.truthy(string.find(text, '%f[%w]' .. word .. '%f[%W]'), `seed {seed}: '{word}' is in the text of {source}`)
    end
  end
end)

test('parsing arbitrary bytes does not raise and keeps every letter', function()
  local alphabet = { 'a', 'b', ' ', '\n', '*', '_', '`', '[', ']', '(', ')', '<', '>', '#', '-', '|', '\\', '\t', '1.' }
  for seed = 1, 300 do
    local random = generator(seed)
    local parts: { string } = {}
    for _ = 1, random(40) do
      table.insert(parts, alphabet[random(#alphabet)])
    end
    local source = table.concat(parts)
    local text = parse.plainText(parse.document(source))
    local _, wanted = string.gsub(source, '[ab]', '')
    local _, found = string.gsub(text, '[ab]', '')
    expect.equal(found, wanted, `the letters of {string.format('%q', source)}`)
  end
end)

return test
