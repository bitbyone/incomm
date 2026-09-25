-- The editor layer: extmark tracking, cards, signs and the actions.
--
-- The counterpart of `EditorIntegrationTest.kt`. Everything runs in a real
-- (headless) Neovim against a real buffer, so what is asserted here is what the
-- user sees: marks that move with the text, cards drawn above the right line,
-- a note that floats to line 1 when it orphans, and positions that reach disk.

local T = _G.T
local incomm = require("incomm")
local service = require("incomm.service")
local track = require("incomm.track")
local render = require("incomm.ui.render")
local ui_state = require("incomm.ui.state")
local actions = require("incomm.actions")

local SOURCE = {
  "package main",
  "",
  "// entrypoint",
  "func main() {",
  '\tprintln("hi")',
  "}",
}

---@param dir string
local function make_repo(dir)
  vim.fn.mkdir(dir .. "/src", "p")
  vim.fn.writefile(SOURCE, dir .. "/src/main.go")
  vim.fn.mkdir(dir .. "/.git", "p")
  vim.fn.writefile({ "ref: refs/heads/main" }, dir .. "/.git/HEAD")
  vim.fn.writefile({ "[user]", "\tname = Fixture User" }, dir .. "/.git/config")
end

--- Open the fixture file in a fresh, tracked buffer.
---@param dir string
---@return integer bufnr, incomm.Service
local function open_fixture(dir)
  service.reset()
  ui_state.reset()
  make_repo(dir)
  vim.cmd("silent! %bwipeout!")
  vim.cmd.cd(dir)
  incomm.setup({ watch = false, reanchor_delay = 10 })
  vim.cmd.edit(dir .. "/src/main.go")
  local bufnr = vim.api.nvim_get_current_buf()
  local t = track.attach(bufnr)
  T.ok(t, "buffer is tracked")
  return bufnr, t.svc
end

---@param bufnr integer
---@param ns integer
---@return table[]
local function marks(bufnr, ns)
  return vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
end

T.test("a new thread draws a sign and a card above its line", function()
  T.with_tmpdir(function(dir)
    local bufnr, svc = open_fixture(dir)
    svc:add_note("src/main.go", 4, 5, "needs error handling")
    track.refresh(bufnr)

    local ui = marks(bufnr, render.ns)
    T.eq(#ui, 2, "the thread's icon, plus the band over the rest of its range")
    T.eq(ui[1][2], 3, "anchored to line 4 (0-based row 3)")
    T.eq(ui[2][2], 4, "the band covers line 5")
    T.ok(ui[1][4].sign_text ~= nil, "has a sign")
    T.ok(ui[1][4].virt_lines and #ui[1][4].virt_lines >= 3, "card has a header and a bubble")

    local card = ui[1][4].virt_lines
    local header = table.concat(vim.tbl_map(function(chunk)
      return chunk[1]
    end, card[1]))
    T.ok(header:find("L4-5", 1, true), "header shows the range: " .. header)
    T.ok(header:find("open", 1, true), "and the state")
    local body = table.concat(vim.tbl_map(function(line)
      return table.concat(vim.tbl_map(function(chunk)
        return chunk[1]
      end, line))
    end, card), "\n")
    T.ok(body:find("Fixture User", 1, true), "author line: " .. body)
    T.ok(body:find("needs error handling", 1, true), "content")
  end)
end)

T.test("every bubble is boxed and exactly the configured width", function()
  T.with_tmpdir(function(dir)
    local bufnr, svc = open_fixture(dir)
    require("incomm.config").options.card.width = 50 -- fits the test window
    local note = svc:add_note("src/main.go", 4, 4, "short")
    svc:add_reply(note.id, "a reply long enough to wrap across more than one line inside its own box", "agent", "Opus 5")
    track.refresh(bufnr)

    local card = marks(bufnr, render.ns)[1][4].virt_lines
    local width = require("incomm.config").options.card.width
    local indent = require("incomm.config").options.card.reply_indent

    local texts = {}
    for _, line in ipairs(card) do
      local text = ""
      for _, chunk in ipairs(line) do
        text = text .. chunk[1]
      end
      texts[#texts + 1] = text
    end

    -- Row 1 is the header; everything after it belongs to a box.
    T.ok(texts[1]:find("L4", 1, true) and texts[1]:find("open", 1, true), "header: " .. texts[1])
    T.eq(texts[2]:sub(1, 3), "╭", "the comment opens a box")
    T.eq(vim.fn.strdisplaywidth(texts[2]), width, "boxed to the configured width")

    -- A short comment is padded out rather than hugging its text, so a file
    -- full of threads keeps one straight edge.
    for i = 2, #texts do
      local w = vim.fn.strdisplaywidth(texts[i])
      T.eq(w, width, "row " .. i .. " is " .. w .. ", want " .. width)
    end

    -- The reply is a box of its own, indented inside the thread.
    local reply_top
    for i = 3, #texts do
      if texts[i]:match("^%s+╭") then
        reply_top = i
        break
      end
    end
    T.ok(reply_top, "the reply opens its own box")
    T.eq(texts[reply_top]:match("^(%s*)"), string.rep(" ", indent), "indented under the comment")
    T.ok(texts[#texts]:match("╯%s*$"), "and the card ends by closing it: " .. texts[#texts])
    require("incomm.config").options.card.width = require("incomm.config").defaults.card.width
  end)
end)

T.test("a bubble narrower than the window still fills its own box", function()
  T.with_tmpdir(function(dir)
    local bufnr, svc = open_fixture(dir)
    require("incomm.config").options.card.width = 50
    svc:add_note("src/main.go", 4, 4, "hi")
    track.refresh(bufnr)
    local card = marks(bufnr, render.ns)[1][4].virt_lines
    local author_row = ""
    for _, chunk in ipairs(card[3]) do
      author_row = author_row .. chunk[1]
    end
    T.eq(vim.fn.strdisplaywidth(author_row), 50)
    T.ok(author_row:match("^│"), "starts with the box's left edge")
    T.ok(author_row:match("│$"), "and ends with its right edge")
    require("incomm.config").options.card.width = require("incomm.config").defaults.card.width
  end)
end)

T.test("a card too wide for the window is clamped, not truncated", function()
  T.with_tmpdir(function(dir)
    local bufnr, svc = open_fixture(dir)
    svc:add_note("src/main.go", 4, 4, "the default width is wider than this test window")
    track.refresh(bufnr)

    local card = marks(bufnr, render.ns)[1][4].virt_lines
    local widths = {}
    for i = 2, #card do
      local width = 0
      for _, chunk in ipairs(card[i]) do
        width = width + vim.fn.strdisplaywidth(chunk[1])
      end
      widths[#widths + 1] = width
    end
    for i = 2, #widths do
      T.eq(widths[i], widths[1], "still one straight edge")
    end
    T.ok(widths[1] <= vim.api.nvim_win_get_width(0), "and it fits the window")
  end)
end)

T.test("the card hangs over the first non-blank column of its own line", function()
  T.with_tmpdir(function(dir)
    local bufnr, svc = open_fixture(dir)
    require("incomm.config").options.card.width = 40
    -- Line 5 is `\tprintln("hi")`; line 4 has no indent at all.
    local indented = svc:add_note("src/main.go", 5, 5, "indented code")
    svc:add_reply(indented.id, "a reply", "agent", "Opus 5")
    svc:add_note("src/main.go", 4, 4, "flush code")
    track.refresh(bufnr)

    local by_row = {}
    for _, m in ipairs(marks(bufnr, render.ns)) do
      if m[4].virt_lines then
        by_row[m[2]] = m[4].virt_lines
      end
    end

    ---@param rows table[][]
    ---@return string
    local function lead_of(rows)
      local text = ""
      for _, chunk in ipairs(rows[2]) do -- row 2 opens the comment's box
        text = text .. chunk[1]
      end
      return text:match("^(%s*)")
    end

    local tabstop = vim.bo[bufnr].tabstop
    T.eq(#lead_of(by_row[4]), tabstop, "over a tab-indented line, the card starts at the code")
    T.eq(#lead_of(by_row[3]), 0, "over an unindented line, it starts at the margin")

    -- The reply keeps its own nesting on top of the card's offset.
    local reply_top
    for i = 3, #by_row[4] do
      local text = ""
      for _, chunk in ipairs(by_row[4][i]) do
        text = text .. chunk[1]
      end
      if text:match("^%s*╭") then
        reply_top = text
        break
      end
    end
    T.ok(reply_top, "the reply opens its own box")
    T.eq(#reply_top:match("^(%s*)"), tabstop + require("incomm.config").options.card.reply_indent)
    require("incomm.config").options.card.width = require("incomm.config").defaults.card.width
  end)
end)

T.test("card.offset shifts a card right, for margins incomm cannot see", function()
  T.with_tmpdir(function(dir)
    local bufnr, svc = open_fixture(dir)
    local config = require("incomm.config")
    config.options.card.width = 40
    svc:add_note("src/main.go", 4, 4, "over a centred column")
    track.refresh(bufnr)

    ---@return integer
    local function lead()
      local card = marks(bufnr, render.ns)[1][4].virt_lines
      local text = ""
      for _, chunk in ipairs(card[2]) do -- the box's top edge
        text = text .. chunk[1]
      end
      return #(text:match("^(%s*)"))
    end
    T.eq(lead(), 0, "no offset by default")

    -- A plain number...
    config.options.card.offset = 12
    track.render_buf(bufnr)
    T.eq(lead(), 12)

    -- ...or a function, which is how a centring plugin plugs in: it is handed
    -- the window showing the buffer.
    local saw_win, saw_buf
    config.options.card.offset = function(win, buf)
      saw_win, saw_buf = win, buf
      return 7
    end
    track.render_buf(bufnr)
    T.eq(lead(), 7)
    T.eq(saw_buf, bufnr, "the buffer is passed through")
    T.ok(saw_win and vim.api.nvim_win_is_valid(saw_win), "so is a window showing it")

    -- A hook that throws must not take the cards down with it.
    config.options.card.offset = function()
      error("boom")
    end
    track.render_buf(bufnr)
    T.eq(lead(), 0, "a failing offset falls back to none")

    -- And a change of answer is picked up without a model change.
    local value = 5
    config.options.card.offset = function()
      return value
    end
    track.render_buf(bufnr)
    T.eq(lead(), 5)
    value = 9
    track.check_offset(bufnr)
    T.eq(lead(), 9, "the cheap check redrew it")

    config.options.card.offset = config.defaults.card.offset
    config.options.card.width = config.defaults.card.width
  end)
end)

T.test("the palette is derived from the colourscheme, not hard-coded", function()
  local hl = require("incomm.ui.highlights")
  local saved = vim.o.termguicolors
  vim.o.termguicolors = true
  vim.api.nvim_set_hl(0, "Normal", { fg = 0xd1d1d1, bg = 0x252224 })
  vim.api.nvim_set_hl(0, "DiagnosticInfo", { fg = 0x8b9bba })
  vim.api.nvim_set_hl(0, "DiagnosticOk", { fg = 0x7bc4a3 })
  hl.setup()

  local function of(name, attr)
    return vim.api.nvim_get_hl(0, { name = name, link = false })[attr]
  end

  -- The border is what says who wrote a message, so the two authors' boxes
  -- must not be the same colour.
  local user_border, agent_border = of("IncommBorderUser", "fg"), of("IncommBorderAgent", "fg")
  T.ok(user_border and agent_border, "both borders are coloured")
  T.ok(user_border ~= agent_border, "and the human's differs from the agent's")

  -- Nothing inside a bubble is filled -- that seam along the border is exactly
  -- what the fills were removed for.
  for _, name in ipairs({ "IncommNameUser", "IncommTimeUser", "IncommTextUser", "IncommBorderAgent" }) do
    T.eq(of(name, "bg"), nil, name .. " has no background")
  end
  -- The one exception: the header tab naming the line and the state.
  T.ok(of("IncommCard", "bg") ~= nil, "the header tab is filled")
  T.ok(of("IncommCardStateOpen", "bg") ~= nil, "and the state word sits on it")

  -- A three-step ladder: the code is brightest, a comment's text sits below it,
  -- and the timestamp below that -- without the body text sinking as far as a
  -- code comment, which would make a thread hard to read.
  local function lum(v)
    local r, g, b = math.floor(v / 65536) % 256, math.floor(v / 256) % 256, v % 256
    return 0.2126 * r + 0.7152 * g + 0.0722 * b
  end
  vim.api.nvim_set_hl(0, "Comment", { fg = 0x8d7a5f })
  hl.derive()
  local code, body = lum(0xd1d1d1), lum(of("IncommTextUser", "fg"))
  local comment, time = lum(0x8d7a5f), lum(of("IncommTimeUser", "fg"))
  T.ok(body < code, "the comment's text is dimmer than the code")
  T.ok(body > comment, "but brighter than a code comment")
  T.ok(time < body, "and the timestamp is quieter still")
  T.ok(
    of("IncommCardStateOpen", "fg") ~= of("IncommCardStateResolved", "fg"),
    "open and resolved stay tellable apart"
  )

  -- Overriding a base group moves everything derived from it.
  vim.api.nvim_set_hl(0, "IncommUser", { fg = 0xff00ff })
  hl.derive()
  T.ok(of("IncommBorderUser", "fg") ~= user_border, "a redefined IncommUser repaints the box")
  vim.api.nvim_set_hl(0, "IncommUser", { link = "DiagnosticInfo" })
  vim.o.termguicolors = saved
  hl.setup()
end)

T.test("the header tab is padded on both sides of the state", function()
  T.with_tmpdir(function(dir)
    local bufnr, svc = open_fixture(dir)
    svc:add_note("src/main.go", 4, 4, "a thread")
    track.refresh(bufnr)

    local header = marks(bufnr, render.ns)[1][4].virt_lines[1]
    local text = ""
    for _, chunk in ipairs(header) do
      text = text .. chunk[1]
    end
    T.eq(text, " L4  open ", "leading and trailing pad: " .. vim.inspect(text))
    -- Line 4 has no indent, so the tab starts at the margin.
    T.eq(header[#header][2], "IncommCard", "the trailing space carries the tab's background")
  end)
end)

T.test("nothing inside a bubble is painted with a background group", function()
  T.with_tmpdir(function(dir)
    local bufnr, svc = open_fixture(dir)
    local note = svc:add_note("src/main.go", 4, 4, "a thread")
    svc:add_reply(note.id, "an answer", "agent", "Opus 5")
    track.refresh(bufnr)

    local card = marks(bufnr, render.ns)[1][4].virt_lines
    for i = 2, #card do -- row 1 is the header tab
      for _, chunk in ipairs(card[i]) do
        local group = chunk[2]
        if group then
          T.ok(
            group:match("^IncommBorder") or group:match("^IncommName") or group:match("^IncommTime") or group:match("^IncommText")
              or group:match("^IncommBadge"),
            "row " .. i .. " uses " .. group .. ", which should be a border, a text or a badge group"
          )
        end
      end
    end
  end)
end)

T.test("editing above a thread moves it, and the move reaches disk", function()
  T.with_tmpdir(function(dir)
    local bufnr, svc = open_fixture(dir)
    local note = svc:add_note("src/main.go", 5, 5, "about the println")
    track.refresh(bufnr)

    -- Two lines inserted at the top, as if typed.
    vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "// header", "// header" })
    T.eq(track.live_positions(bufnr)[note.id][1], 7, "the extmark followed the text")

    track.flush(bufnr)
    T.eq(svc:find(note.id).startLine, 7, "the model caught up")
    T.eq(svc:find(note.id).anchor.startPrefix, 'println("hi")', "the anchor still describes the same code")

    local on_disk = svc.store:load()
    T.eq(require("incomm.model").find(on_disk, note.id).startLine, 7, "and so did the file")

    -- The card header follows too.
    track.render_buf(bufnr)
    local header = table.concat(vim.tbl_map(function(chunk)
      return chunk[1]
    end, marks(bufnr, render.ns)[1][4].virt_lines[1]))
    T.ok(header:find("L7", 1, true), "header updated: " .. header)
  end)
end)

T.test("deleting the anchored lines orphans the thread and floats it to line 1", function()
  T.with_tmpdir(function(dir)
    local bufnr, svc = open_fixture(dir)
    local note = svc:add_note("src/main.go", 5, 5, "about the println")
    track.refresh(bufnr)

    -- Delete line 5 outright: the extmark is invalidated, so the service falls
    -- back to a text re-anchor, which cannot find the line either.
    vim.api.nvim_buf_set_lines(bufnr, 4, 5, false, {})
    track.flush(bufnr)

    T.eq(svc:find(note.id).orphaned, true, "orphaned")
    track.refresh(bufnr)
    local ui = marks(bufnr, render.ns)
    T.eq(#ui, 1)
    T.eq(ui[1][2], 0, "floated to line 1")
    local header = table.concat(vim.tbl_map(function(chunk)
      return chunk[1]
    end, ui[1][4].virt_lines[1]))
    T.ok(header:find("orphaned", 1, true), "and says so: " .. header)

    -- Typing the line back heals it, exactly as the CLI's reanchor would.
    vim.api.nvim_buf_set_lines(bufnr, 4, 4, false, { '\tprintln("hi")' })
    track.flush(bufnr)
    T.eq(svc:find(note.id).orphaned, false, "self-healed")
    T.eq(svc:find(note.id).startLine, 5)
  end)
end)

T.test("a card on line 1 hangs below it, where Neovim will actually draw it", function()
  T.with_tmpdir(function(dir)
    local bufnr, svc = open_fixture(dir)
    svc:add_note("src/main.go", 1, 1, "about the package clause")
    svc:add_note("src/main.go", 4, 4, "about main")
    track.refresh(bufnr)

    local by_row = {}
    for _, m in ipairs(marks(bufnr, render.ns)) do
      by_row[m[2]] = m[4]
    end
    T.eq(by_row[0].virt_lines_above, false, "line 1: below, since nothing renders above it")
    T.ok(by_row[0].virt_lines ~= nil, "and the card is still there")
    T.eq(by_row[3].virt_lines_above, true, "every other line: above the code")
  end)
end)

T.test("an orphaned and resolved thread is not drawn at all", function()
  T.with_tmpdir(function(dir)
    local bufnr, svc = open_fixture(dir)
    local note = svc:add_note("src/main.go", 5, 5, "gone")
    vim.api.nvim_buf_set_lines(bufnr, 4, 5, false, {})
    track.flush(bufnr)
    svc:set_resolved(note.id, true)
    track.refresh(bufnr)
    T.eq(#marks(bufnr, render.ns), 0)
  end)
end)

T.test("toggling one thread hides its card but keeps the sign", function()
  T.with_tmpdir(function(dir)
    local bufnr, svc = open_fixture(dir)
    svc:add_note("src/main.go", 4, 4, "a thread")
    track.refresh(bufnr)
    vim.api.nvim_win_set_cursor(0, { 4, 0 })

    actions.toggle_thread()
    local details = marks(bufnr, render.ns)[1][4]
    T.eq(details.virt_lines, nil, "card gone")
    T.ok(details.sign_text ~= nil, "sign stays")

    actions.toggle_thread()
    T.ok(marks(bufnr, render.ns)[1][4].virt_lines ~= nil, "back again")
  end)
end)

T.test("hide-all is per-thread, so one thread can still be revealed after it", function()
  T.with_tmpdir(function(dir)
    local bufnr, svc = open_fixture(dir)
    local a = svc:add_note("src/main.go", 4, 4, "one")
    local b = svc:add_note("src/main.go", 5, 5, "two")
    track.refresh(bufnr)

    actions.toggle_all()
    T.eq(ui_state.is_hidden(a.id), true)
    T.eq(ui_state.is_hidden(b.id), true)

    vim.api.nvim_win_set_cursor(0, { 5, 0 })
    actions.toggle_thread()
    T.eq(ui_state.is_hidden(b.id), false, "revealed on its own")
    T.eq(ui_state.is_hidden(a.id), true, "the other stayed hidden")
  end)
end)

T.test("resolving collapses the card, reopening brings it back", function()
  T.with_tmpdir(function(dir)
    local bufnr, svc = open_fixture(dir)
    local note = svc:add_note("src/main.go", 4, 4, "a thread")
    track.refresh(bufnr)
    vim.api.nvim_win_set_cursor(0, { 4, 0 })

    actions.resolve()
    T.eq(svc:find(note.id).resolved, true)
    T.eq(ui_state.is_hidden(note.id), true, "resolve also hides, as in the IDE")

    actions.resolve()
    T.eq(svc:find(note.id).resolved, false)
    T.eq(ui_state.is_hidden(note.id), false)
  end)
end)

T.test("show/hide resolved touches only resolved threads", function()
  T.with_tmpdir(function(dir)
    local bufnr, svc = open_fixture(dir)
    local open_note = svc:add_note("src/main.go", 4, 4, "open")
    local done = svc:add_note("src/main.go", 5, 5, "done")
    svc:set_resolved(done.id, true)
    ui_state.set_hidden(done.id, false)
    track.refresh(bufnr)

    actions.toggle_resolved()
    T.eq(ui_state.is_hidden(done.id), true)
    T.eq(ui_state.is_hidden(open_note.id), false, "the open thread is untouched")
  end)
end)

T.test("hide_resolved collapses resolved threads on sight, once", function()
  T.with_tmpdir(function(dir)
    local bufnr, svc = open_fixture(dir)
    require("incomm.config").options.hide_resolved = true
    local note = svc:add_note("src/main.go", 4, 4, "already handled")
    svc:set_resolved(note.id, true)
    track.refresh(bufnr)
    T.eq(ui_state.is_hidden(note.id), true, "hidden without being asked")

    -- But a deliberate toggle afterwards still wins: the default is applied
    -- once per thread, not re-applied on every redraw.
    ui_state.set_hidden(note.id, false)
    track.refresh(bufnr)
    T.eq(ui_state.is_hidden(note.id), false, "stays shown once revealed")
    require("incomm.config").options.hide_resolved = false
  end)
end)

T.test("author_title from the config wins over git user.name", function()
  T.with_tmpdir(function(dir)
    local _, svc = open_fixture(dir)
    require("incomm.config").options.author_title = "Someone Else"
    svc.author_title = nil
    local note = svc:add_note("src/main.go", 4, 4, "mine")
    T.eq(note.authorTitle, "Someone Else")
    require("incomm.config").options.author_title = nil
  end)
end)

T.test("the cursor lands in the thread under it, innermost first", function()
  T.with_tmpdir(function(dir)
    local bufnr, svc = open_fixture(dir)
    svc:add_note("src/main.go", 3, 6, "the whole function")
    local inner = svc:add_note("src/main.go", 5, 5, "this line")
    track.refresh(bufnr)

    vim.api.nvim_win_set_cursor(0, { 5, 0 })
    T.eq(track.note_at_cursor(bufnr).id, inner.id)
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    T.eq(track.note_at_cursor(bufnr).content, "the whole function")
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    T.eq(track.note_at_cursor(bufnr), nil)
  end)
end)

T.test("a thread's extent is shown in the gutter, never on the lines", function()
  T.with_tmpdir(function(dir)
    local bufnr, svc = open_fixture(dir)
    svc:add_note("src/main.go", 4, 6, "three lines")
    track.refresh(bufnr)
    vim.api.nvim_win_set_cursor(0, { 5, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = bufnr })

    -- The icon plus the band that continues it: one sign per anchored line.
    local signs = 0
    for _, m in ipairs(marks(bufnr, render.ns)) do
      if m[4].sign_text then
        signs = signs + 1
      end
      -- Nothing may colour the code itself. The lines under a thread are the
      -- file's, and painting them (in the caret-row colour, no less) read as
      -- "the cursor is here" everywhere the thread reached.
      T.eq(m[4].line_hl_group, nil, "no line highlight on row " .. m[2])
    end
    T.eq(signs, 3, "one sign per line of the range")
  end)
end)

T.test("next/prev thread walk the file and wrap", function()
  T.with_tmpdir(function(dir)
    local bufnr, svc = open_fixture(dir)
    svc:add_note("src/main.go", 2, 2, "first")
    svc:add_note("src/main.go", 5, 5, "second")
    track.refresh(bufnr)

    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    actions.goto_thread(1)
    T.eq(vim.api.nvim_win_get_cursor(0)[1], 2)
    actions.goto_thread(1)
    T.eq(vim.api.nvim_win_get_cursor(0)[1], 5)
    actions.goto_thread(1)
    T.eq(vim.api.nvim_win_get_cursor(0)[1], 2, "wrapped")
    actions.goto_thread(-1)
    T.eq(vim.api.nvim_win_get_cursor(0)[1], 5, "wrapped backwards")
  end)
end)

T.test("a thread added from outside appears without touching the buffer", function()
  T.with_tmpdir(function(dir)
    local bufnr, svc = open_fixture(dir)
    -- The agent writes straight into the notes file.
    local disk = svc.store:load()
    table.insert(disk.notes, {
      id = "agentxyz",
      file = "src/main.go",
      startLine = 4,
      endLine = 4,
      anchor = require("incomm.anchor").compute(SOURCE, 4, 4),
      content = "agent was here",
      resolved = false,
      orphaned = false,
      author = "agent",
      authorTitle = "Opus 5",
      createdAt = require("incomm.model").now_utc(),
      updatedAt = require("incomm.model").now_utc(),
      replies = {},
    })
    svc.store:save(disk)

    svc:reload()
    track.refresh(bufnr)
    local ui = marks(bufnr, render.ns)
    T.eq(#ui, 1)
    local body = table.concat(vim.tbl_map(function(line)
      return table.concat(vim.tbl_map(function(chunk)
        return chunk[1]
      end, line))
    end, ui[1][4].virt_lines), "\n")
    T.ok(body:find("Agent (Opus 5)", 1, true), "rendered as an agent bubble: " .. body)
  end)
end)

T.test("the debounced re-anchor fires on its own after an edit", function()
  T.with_tmpdir(function(dir)
    local bufnr, svc = open_fixture(dir)
    local note = svc:add_note("src/main.go", 5, 5, "about the println")
    track.refresh(bufnr)

    vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "// added" })
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = bufnr })
    vim.wait(2000, function()
      return svc:find(note.id).startLine == 6
    end, 10)
    T.eq(svc:find(note.id).startLine, 6, "the timer flushed without an explicit call")
  end)
end)

T.test("threads are per file", function()
  T.with_tmpdir(function(dir)
    local bufnr, svc = open_fixture(dir)
    svc:add_note("src/main.go", 4, 4, "here")
    svc:add_note("src/other.go", 1, 1, "elsewhere")
    track.refresh(bufnr)
    T.eq(#marks(bufnr, render.ns), 1, "only this file's thread is drawn")
    T.eq(#svc:notes_for_file("src/other.go"), 1)
  end)
end)

service.reset()
