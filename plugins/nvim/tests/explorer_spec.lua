-- The thread explorer.
--
-- Driven as a user would: open it, move the selection, press the filter keys,
-- type in the search box. What is asserted is what the panes actually contain --
-- the list rows, and a detail pane holding the anchored code followed by the
-- conversation as boxed bubbles.

local T = _G.T
local explorer = require("incomm.ui.explorer")
local service = require("incomm.service")
local incomm = require("incomm")

local SOURCE = {
  "package main",
  "",
  "// entrypoint",
  "func main() {",
  '\tprintln("hi")',
  "}",
}

---@param dir string
---@return incomm.Service, table
local function fixture(dir)
  service.reset()
  vim.fn.mkdir(dir .. "/src", "p")
  vim.fn.writefile(SOURCE, dir .. "/src/main.go")
  vim.fn.mkdir(dir .. "/.git", "p")
  vim.fn.writefile({ "ref: refs/heads/main" }, dir .. "/.git/HEAD")
  vim.fn.writefile({ "[user]", "\tname = Fixture User" }, dir .. "/.git/config")
  vim.cmd("silent! %bwipeout!")
  vim.cmd.cd(dir)
  incomm.setup({ watch = false })
  local svc = service.for_root(dir)

  local open = svc:add_note("src/main.go", 4, 4, "Hey, this is crazy :D")
  svc:add_reply(open.id, "Fixed - it streams the file now.", "agent", "Opus 5")
  local done = svc:add_note("src/main.go", 5, 5, "resolved thread")
  svc:set_resolved(done.id, true)
  local lost = svc:add_note("src/main.go", 1, 1, "orphaned thread")
  svc:mutate(lost.id, function(note)
    note.orphaned = true
  end)
  return svc, { open = open, done = done, lost = lost }
end

---@param name string
---@return string[]
local function pane(name)
  local self = explorer.current()
  return vim.api.nvim_buf_get_lines(self.bufs[name], 0, -1, false)
end

---@param name string
---@return string
local function text(name)
  return table.concat(pane(name), "\n")
end

---@param keys string
local function feed(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end

--- Let the scheduled redraw run: a mutation publishes a change, and the
--- explorer refreshes itself on the next tick rather than inside the keymap.
--- Waits for the condition rather than for a fixed slice of time -- a busy
--- machine is exactly when a fixed sleep becomes a flaky test.
---@param done? fun(): boolean
local function settle(done)
  vim.wait(2000, done or function()
    return false
  end, 10)
end

local function close()
  if explorer.current() then
    explorer.close(explorer.current())
  end
end

T.test("the explorer opens four panes and lists the threads", function()
  T.with_tmpdir(function(dir)
    local svc = fixture(dir)
    explorer.filters = { open = true, resolved = false, orphaned = true }
    explorer.open(svc)

    local self = explorer.current()
    T.ok(self, "an explorer is on screen")
    for _, name in ipairs({ "search", "filters", "list", "detail" }) do
      T.ok(vim.api.nvim_win_is_valid(self.wins[name]), name .. " window")
    end

    -- Two rows per thread -- the comment, then its reply count and location --
    -- ordered by file and line, so the orphaned note (floated to line 1) leads.
    local list = pane("list")
    T.ok(list[1]:find("orphaned thread", 1, true), "row 1: " .. list[1])
    -- Trimmed to the pane's width, with an ellipsis -- the list is an index,
    -- the detail pane is where a thread is read.
    T.ok(list[3]:find("Hey, this", 1, true), "row 3: " .. list[3])
    T.ok(list[4]:find("1 reply", 1, true), "its second line counts replies: " .. list[4])
    T.ok(list[4]:find("main.go:4", 1, true), "and names the file and line, not the whole path")
    T.ok(not list[4]:find("src/", 1, true), "the path is shortened in the list")
    close()
  end)
end)

T.test("the bar down a row is the thread's state, on both of its lines", function()
  T.with_tmpdir(function(dir)
    local svc = fixture(dir)
    explorer.filters = { open = true, resolved = true, orphaned = true }
    explorer.open(svc)

    -- Sorted by line: orphaned (L1), open (L4), resolved (L5).
    local expected = { "IncommStateOrphaned", "IncommStateOpen", "IncommStateResolved" }
    local self = explorer.current()
    for i, group in ipairs(expected) do
      local row = (i - 1) * 2
      for offset = 0, 1 do
        -- The bar is what tells one state from another at a glance, and a
        -- thread is two lines high, so both of them carry it -- otherwise the
        -- left border of an entry stops halfway down it.
        local marks = vim.api.nvim_buf_get_extmarks(
          self.bufs.list,
          explorer.ns,
          { row + offset, 0 },
          { row + offset, 1 },
          { details = true }
        )
        local found
        for _, m in ipairs(marks) do
          if m[3] == 0 and m[4].hl_group == group then
            found = true
          end
        end
        T.ok(found, group .. " on line " .. (row + offset + 1) .. " of the list")
      end
    end

    explorer.filters = { open = true, resolved = false, orphaned = true }
    close()
  end)
end)

T.test("selecting a row does not repaint its bar", function()
  T.with_tmpdir(function(dir)
    local svc = fixture(dir)
    explorer.filters = { open = true, resolved = true, orphaned = true }
    explorer.open(svc)

    local self = explorer.current()
    local bar = #require("incomm.config").options.explorer.icon
    local marks = vim.api.nvim_buf_get_extmarks(self.bufs.list, explorer.ns, 0, -1, { details = true })
    local selected = 0
    for _, m in ipairs(marks) do
      if m[4].hl_group == "IncommSelection" or m[4].line_hl_group == "IncommSelection" then
        selected = selected + 1
        -- The bar is the only colour in the list that carries meaning, so the
        -- selection starts after it: a selected thread's state reads exactly
        -- like an unselected one's.
        T.eq(m[3], bar, "the selection starts after the bar")
      end
    end
    T.eq(selected, 2, "both lines of the selected row")

    -- And it reaches the pane's edge: the rows are padded, so the selection is
    -- a block rather than a highlight that stops with the text.
    for _, line in ipairs(vim.api.nvim_buf_get_lines(self.bufs.list, 0, -1, false)) do
      T.ok(vim.fn.strdisplaywidth(line) >= self.geom.list_w, "row padded to the pane: " .. vim.inspect(line))
    end

    explorer.filters = { open = true, resolved = false, orphaned = true }
    close()
  end)
end)

T.test("the cursor is hidden in the list and restored on the way out", function()
  T.with_tmpdir(function(dir)
    local svc = fixture(dir)
    local before = vim.o.guicursor
    explorer.open(svc)
    -- The block cursor parks on the selected row's first column, which is the
    -- bar: a whole inverted cell over the one mark in the list that means
    -- something. There is nothing to type in the list, so it goes away.
    T.eq(vim.o.guicursor, "a:IncommHiddenCursor", "hidden while the list has focus")

    local self = explorer.current()
    vim.api.nvim_set_current_win(self.wins.search)
    T.eq(vim.o.guicursor, before, "back in the search box, where you type")

    vim.api.nvim_set_current_win(self.wins.list)
    T.eq(vim.o.guicursor, "a:IncommHiddenCursor", "and hidden again on the way back")
    close()
    T.eq(vim.o.guicursor, before, "closing the explorer restores it")
  end)
end)

T.test("the editor behind the explorer is shaded, and the shade goes with it", function()
  T.with_tmpdir(function(dir)
    local svc = fixture(dir)
    local saved = vim.o.termguicolors
    vim.o.termguicolors = true -- no 24-bit colour, no blend, no backdrop
    explorer.open(svc)

    local self = explorer.current()
    local backdrop = self.wins.backdrop
    T.ok(backdrop and vim.api.nvim_win_is_valid(backdrop), "a backdrop window is open")
    local cfg = vim.api.nvim_win_get_config(backdrop)
    T.eq(cfg.width, vim.o.columns, "it covers the whole editor")
    T.ok(cfg.zindex < 50, "and sits under the panes")
    T.eq(vim.wo[backdrop].winblend, 60, "shading rather than hiding what is behind it")

    close()
    T.ok(not vim.api.nvim_win_is_valid(backdrop), "closing the explorer takes it away")
    vim.o.termguicolors = saved
  end)
end)

T.test("the detail pane shows the anchored code and then the conversation", function()
  T.with_tmpdir(function(dir)
    local svc = fixture(dir)
    explorer.filters = { open = true, resolved = false, orphaned = true }
    explorer.open(svc)
    feed("j") -- onto the open thread; the orphaned one sorts first

    local detail = text("detail")
    T.ok(detail:find("src/main.go:4", 1, true), "the header names where the thread lives")
    T.ok(detail:find("open", 1, true), "and its state")
    -- Single-line thread: the line with one line of context either side.
    T.ok(detail:find("// entrypoint", 1, true), "context line above")
    T.ok(detail:find("func main() {", 1, true), "the anchored line")
    T.ok(detail:find('println("hi")', 1, true), "context line below")
    -- Then the discussion, rendered rather than summarised.
    T.ok(detail:find("Fixture User", 1, true), "the comment's author")
    T.ok(detail:find("Hey, this is crazy :D", 1, true), "the comment")
    T.ok(detail:find("Agent (Opus 5)", 1, true), "the reply's author")
    T.ok(detail:find("Fixed - it streams the file now.", 1, true), "the reply")
    T.ok(detail:find("╭", 1, true) and detail:find("╰", 1, true), "each message in its own box")
    close()
  end)
end)

T.test("j and k move the selection and the detail follows", function()
  T.with_tmpdir(function(dir)
    local svc, notes = fixture(dir)
    explorer.filters = { open = true, resolved = false, orphaned = true }
    explorer.open(svc)

    T.eq(explorer.current().items[explorer.current().index].id, notes.lost.id, "starts on the first row")
    feed("j")
    T.eq(explorer.current().index, 2)
    T.ok(text("detail"):find("Hey, this is crazy :D", 1, true), "the detail pane followed")
    feed("k")
    T.eq(explorer.current().index, 1)
    close()
  end)
end)

T.test("the filter keys toggle the three states, checkboxes and all", function()
  T.with_tmpdir(function(dir)
    local svc = fixture(dir)
    explorer.filters = { open = true, resolved = false, orphaned = true }
    explorer.open(svc)

    T.eq(#explorer.current().items, 2, "open + orphaned")
    T.ok(text("filters"):find("✔ open", 1, true), "open is ticked")
    T.ok(text("filters"):find("☐ resolved", 1, true), "resolved is not")

    feed("<C-r>") -- include resolved
    T.eq(#explorer.current().items, 3)
    T.ok(text("filters"):find("✔ resolved", 1, true), "the checkbox followed")

    feed("<C-x>") -- drop orphaned
    T.eq(#explorer.current().items, 2)
    feed("<C-o>") -- drop open
    T.eq(#explorer.current().items, 1, "only the resolved one is left")
    T.eq(explorer.current().items[1].resolved, true)

    explorer.filters = { open = true, resolved = false, orphaned = true }
    close()
  end)
end)

T.test("typing in the search box narrows the list", function()
  T.with_tmpdir(function(dir)
    local svc = fixture(dir)
    explorer.filters = { open = true, resolved = true, orphaned = true }
    explorer.open(svc)
    T.eq(#explorer.current().items, 3)

    local self = explorer.current()
    vim.api.nvim_buf_set_lines(self.bufs.search, 0, -1, false, { "crazy" })
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = self.bufs.search })
    T.eq(#explorer.current().items, 1, "one thread says 'crazy'")
    T.ok(explorer.current().items[1].content:find("crazy", 1, true))

    -- The search also reaches into replies, which is where half a thread lives.
    vim.api.nvim_buf_set_lines(self.bufs.search, 0, -1, false, { "streams" })
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = self.bufs.search })
    T.eq(#explorer.current().items, 1, "matched on the agent's reply")

    explorer.filters = { open = true, resolved = false, orphaned = true }
    close()
  end)
end)

T.test("the gaps between the filter checkboxes carry no highlight", function()
  T.with_tmpdir(function(dir)
    local svc = fixture(dir)
    explorer.open(svc)
    local self = explorer.current()
    local line = vim.api.nvim_buf_get_lines(self.bufs.filters, 0, 1, false)[1]
    local marks = vim.api.nvim_buf_get_extmarks(self.bufs.filters, explorer.ns, 0, -1, { details = true })

    -- Every highlighted range must be a checkbox or a label, never one of the
    -- separators -- a group there paints its own background over the float's
    -- and shows up as a block between the states.
    for _, m in ipairs(marks) do
      local text = line:sub(m[2] + 1, m[4].end_col)
      T.ok(vim.trim(text) ~= "", "highlighted range is not blank: " .. vim.inspect(text))
    end
    close()
  end)
end)

T.test("the search box starts empty, with no placeholder in it", function()
  T.with_tmpdir(function(dir)
    local svc = fixture(dir)
    explorer.open(svc)
    local self = explorer.current()
    T.eq(vim.api.nvim_buf_get_lines(self.bufs.search, 0, -1, false), { "" })
    T.eq(#vim.api.nvim_buf_get_extmarks(self.bufs.search, explorer.ns, 0, -1, {}), 0, "nothing drawn in it")
    close()
  end)
end)

T.test("the code preview's syntax highlights land on the right columns", function()
  T.with_tmpdir(function(dir)
    local svc = fixture(dir)
    svc:clear_all()
    svc:add_note("src/main.go", 4, 4, "about main")
    explorer.open(svc)

    local self = explorer.current()
    local lines = vim.api.nvim_buf_get_lines(self.bufs.detail, 0, -1, false)
    local marks = vim.api.nvim_buf_get_extmarks(self.bufs.detail, explorer.ns, 0, -1, { details = true })
    local captures = 0
    for _, m in ipairs(marks) do
      local group = m[4].hl_group or ""
      if group:match("^@") then
        captures = captures + 1
        local text = (lines[m[2] + 1] or ""):sub(m[3] + 1, m[4].end_col)
        -- The snippet is written with a two-column gutter; before that was
        -- accounted for, every capture landed two cells to its left and the
        -- preview looked like confetti.
        T.ok(m[3] >= 2, "a capture never starts inside the gutter")
        T.ok(vim.trim(text) ~= "", "and never covers blank space: " .. vim.inspect(text))
      end
    end
    if captures == 0 then
      -- No Go parser in this environment; the offset is still asserted above
      -- whenever one is present.
      T.ok(true, "no treesitter parser for go, nothing to check")
    end
    close()
  end)
end)

T.test("a reply from the explorer opens centred, above the floats", function()
  T.with_tmpdir(function(dir)
    local svc = fixture(dir)
    explorer.open(svc)
    feed("r")
    local composer_win
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.b[vim.api.nvim_win_get_buf(win)].incomm_composer then
        composer_win = win
      end
    end
    T.ok(composer_win, "the composer opened")
    local cfg = vim.api.nvim_win_get_config(composer_win)
    T.eq(cfg.relative, "editor", "centred on the editor, not parked at the cursor")
    T.ok(cfg.zindex > 50, "and above the explorer's own floats")
    -- Centred within a column of the editor.
    local expected_col = math.floor((vim.o.columns - cfg.width) / 2)
    T.ok(math.abs(cfg.col - expected_col) <= 1, "horizontally centred")
    vim.api.nvim_win_close(composer_win, true)
    close()
  end)
end)

T.test("resolving and deleting from the list update it in place", function()
  T.with_tmpdir(function(dir)
    local svc, notes = fixture(dir)
    explorer.filters = { open = true, resolved = false, orphaned = true }
    explorer.open(svc)
    feed("j") -- the open thread
    T.eq(explorer.current().items[explorer.current().index].id, notes.open.id)

    feed("x") -- resolve it
    settle(function()
      return #explorer.current().items == 1
    end)
    T.eq(svc:find(notes.open.id).resolved, true)
    T.eq(#explorer.current().items, 1, "it left the list, since resolved is filtered out")

    feed("d") -- delete what is left
    settle(function()
      return #explorer.current().items == 0
    end)
    T.eq(svc:find(notes.lost.id), nil)
    T.eq(#explorer.current().items, 0, "and the list is empty")
    close()
  end)
end)

T.test("a multi-line thread previews its range instead of one line", function()
  T.with_tmpdir(function(dir)
    local svc = fixture(dir)
    svc:clear_all()
    svc:add_note("src/main.go", 3, 6, "the whole function")
    explorer.filters = { open = true, resolved = false, orphaned = true }
    explorer.open(svc)

    local detail = text("detail")
    T.ok(detail:find("src/main.go:3", 1, true), "header")
    T.ok(detail:find("// entrypoint", 1, true) and detail:find("}", 1, true), "the range itself")
    close()
  end)
end)

T.test("? opens the key list, and closing it returns to the list", function()
  T.with_tmpdir(function(dir)
    local svc = fixture(dir)
    explorer.open(svc)
    local before = vim.api.nvim_get_current_win()
    feed("?")
    local help_win = vim.api.nvim_get_current_win()
    T.ok(help_win ~= before, "the help float took focus")
    local help = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    T.ok(help:find("go to the code", 1, true), "it lists the keys")
    T.ok(help:find("resolve / reopen", 1, true))
    feed("q")
    T.eq(vim.api.nvim_get_current_win(), before, "back on the list")
    close()
  end)
end)

T.test("closing one pane closes the whole explorer", function()
  T.with_tmpdir(function(dir)
    local svc = fixture(dir)
    explorer.open(svc)
    local self = explorer.current()
    local wins = vim.tbl_values(self.wins)
    vim.api.nvim_win_close(self.wins.detail, true)
    T.eq(explorer.current(), nil, "no explorer left behind")
    for _, win in ipairs(wins) do
      T.ok(not vim.api.nvim_win_is_valid(win), "every float is gone")
    end
  end)
end)

T.test("the file-scoped explorer only lists that file's threads", function()
  T.with_tmpdir(function(dir)
    local svc = fixture(dir)
    svc:add_note("src/other.go", 1, 1, "elsewhere")
    explorer.filters = { open = true, resolved = true, orphaned = true }
    explorer.open(svc, "src/other.go")
    T.eq(#explorer.current().items, 1)
    T.eq(explorer.current().items[1].content, "elsewhere")
    explorer.filters = { open = true, resolved = false, orphaned = true }
    close()
  end)
end)

close()
service.reset()
