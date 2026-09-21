-- The thread explorer: a search box, three state filters, a list of threads and
-- a detail pane that shows the code a thread is anchored to followed by the
-- conversation itself.
--
-- This is a hand-built float layout rather than a picker, because a picker's
-- preview shows a *file* and what is wanted here is a *thread*: a few lines of
-- the code it hangs on, then the discussion rendered as bubbles, exactly the
-- shape `ui/NotesExplorerPopup.kt` + `ui/NoteThreadComponent.kt` give in the
-- IDE. It also means no plugin dependency -- the explorer works in a bare
-- Neovim.
--
-- Layout (all floats):
--
--   ┌ search ─────────┐┌ open / resolved / orphaned ─────────────────┐
--   └─────────────────┘└─────────────────────────────────────────────┘
--   ┌ threads ────────┐┌ thread ─────────────────────────────────────┐
--   │ Hey, this is …  ││ src/app/Main.kt:27   open                   │
--   │ 1 reply  Main…  ││   class A : X {            ← the anchored    │
--   │                 ││       override fun x() {     code           │
--   │                 ││   ╭───────────────────────╮                 │
--   │                 ││   │ Jan Tobola  7m ago    │ ← the thread    │
--   │                 ││   ╰───────────────────────╯                 │
--   └─────────────────┘└─────────────────────────────────────────────┘

local bubble = require("incomm.ui.bubble")
local composer = require("incomm.ui.composer")
local config = require("incomm.config")
local format = require("incomm.ui.format")
local hl = require("incomm.ui.highlights")

local M = {}

M.ns = vim.api.nvim_create_namespace("incomm_explorer")

--- Which states are listed. Persisted across openings; the defaults are the
--- IDE's -- open and orphaned in, resolved out.
M.filters = { open = true, resolved = false, orphaned = true }

---@type table? the explorer currently on screen
local current

-- ---------------------------------------------------------------------------
-- model
-- ---------------------------------------------------------------------------

---@param note incomm.Note
---@return "open"|"resolved"|"orphaned"
local function state_of(note)
  if note.orphaned then
    return "orphaned"
  elseif note.resolved then
    return "resolved"
  end
  return "open"
end

--- Threads matching the filters and the search text.
---@param self table
---@return incomm.Note[]
local function collect(self)
  local out = {}
  for _, note in ipairs(self.svc:all_notes()) do
    local keep = (not self.rel or note.file == self.rel)
      -- A note can be several things at once (resolved *and* orphaned); it is
      -- listed when any of the states it is in is enabled.
      and (
        (note.orphaned and M.filters.orphaned)
        or (note.resolved and M.filters.resolved)
        or (not note.orphaned and not note.resolved and M.filters.open)
      )
    if keep then
      out[#out + 1] = note
    end
  end
  table.sort(out, function(a, b)
    if a.file ~= b.file then
      return a.file < b.file
    end
    return a.startLine < b.startLine
  end)

  if self.query ~= "" then
    -- Everything worth matching on: the comment, the replies, who wrote them,
    -- and where the thread lives.
    local haystacks = {}
    for i, note in ipairs(out) do
      local parts = { note.file, note.content, note.authorTitle or "" }
      for _, reply in ipairs(note.replies) do
        parts[#parts + 1] = reply.content
        parts[#parts + 1] = reply.authorTitle or ""
      end
      haystacks[i] = table.concat(parts, " "):gsub("\n", " ")
    end
    local matched = vim.fn.matchfuzzy(haystacks, self.query)
    local wanted = {}
    for _, text in ipairs(matched) do
      for i, h in ipairs(haystacks) do
        if h == text and not wanted[i] then
          wanted[i] = true
          break
        end
      end
    end
    local filtered = {}
    for i, note in ipairs(out) do
      if wanted[i] then
        filtered[#filtered + 1] = note
      end
    end
    out = filtered
  end
  return out
end

-- ---------------------------------------------------------------------------
-- rendering
-- ---------------------------------------------------------------------------

---@param self table
local function render_filters(self)
  local chunks = {}
  for _, name in ipairs({ "open", "resolved", "orphaned" }) do
    local on = M.filters[name]
    local suffix = name:sub(1, 1):upper() .. name:sub(2)
    local group = on and ("IncommState" .. suffix) or "IncommMuted"
    chunks[#chunks + 1] = { on and "✔ " or "☐ ", group }
    chunks[#chunks + 1] = { name, group }
    -- The gap is left unhighlighted: a group of its own would paint its
    -- background over the float's and show up as a block between the states.
    chunks[#chunks + 1] = { "   " }
  end
  local text, width = {}, 0
  for _, chunk in ipairs(chunks) do
    text[#text + 1] = chunk[1]
    width = width + vim.fn.strdisplaywidth(chunk[1])
  end
  -- Right-aligned, like the checkbox row in the IDE.
  local lead = math.max(0, self.geom.detail_w - width)
  vim.api.nvim_buf_set_lines(self.bufs.filters, 0, -1, false, { string.rep(" ", lead) .. table.concat(text) })
  vim.api.nvim_buf_clear_namespace(self.bufs.filters, M.ns, 0, -1)
  local col = lead
  for _, chunk in ipairs(chunks) do
    if chunk[2] and chunk[1] ~= "" then
      pcall(vim.api.nvim_buf_set_extmark, self.bufs.filters, M.ns, 0, col, {
        end_col = col + #chunk[1],
        hl_group = chunk[2],
      })
    end
    col = col + #chunk[1]
  end
end

---@param self table
local function render_list(self)
  local lines, highlights = {}, {}
  for i, note in ipairs(self.items) do
    local row = (i - 1) * 2
    local state = state_of(note)
    local icon = config.options.explorer.icon
    lines[#lines + 1] = icon .. " " .. format.preview(note.content, self.geom.list_w - 4)

    local replies = #note.replies
    local meta = replies == 0 and "no replies" or (replies == 1 and "1 reply" or (replies .. " replies"))
    local where = vim.fn.fnamemodify(note.file, ":t") .. ":" .. note.startLine
    -- The glyph leads the second line too, so the two lines of an entry are
    -- bordered as the one block they are.
    lines[#lines + 1] = icon .. " " .. meta .. "   " .. where .. (state ~= "open" and ("   " .. state) or "")

    -- The bar is the thread's state, not its author: blue open, green
    -- resolved, red orphaned -- the same reading as the gutter sign and the
    -- filter checkboxes above the list. Who wrote it is on the card in the
    -- detail pane, where there is room to say so.
    for offset = 0, 1 do
      highlights[#highlights + 1] = { row = row + offset, col = 0, end_col = #icon, hl = hl.for_state(note) }
    end
    highlights[#highlights + 1] = { row = row + 1, col = #icon, end_col = #lines[#lines], hl = "IncommMuted" }
    if state ~= "open" then
      highlights[#highlights + 1] = {
        row = row + 1,
        col = #lines[#lines] - #state,
        end_col = #lines[#lines],
        hl = hl.for_state(note),
      }
    end
  end

  if #lines == 0 then
    lines = { "", "  no threads match" }
    highlights = { { row = 1, col = 0, end_col = 20, hl = "IncommMuted" } }
  end

  vim.bo[self.bufs.list].modifiable = true
  vim.api.nvim_buf_set_lines(self.bufs.list, 0, -1, false, lines)
  vim.bo[self.bufs.list].modifiable = false
  vim.api.nvim_buf_clear_namespace(self.bufs.list, M.ns, 0, -1)
  bubble.apply(self.bufs.list, M.ns, highlights)

  -- The selected row: both of its lines, so the block reads as one entry --
  -- but starting *after* the bar, so the bar is the same glyph in the same
  -- colour whether the row is selected or not. A `line_hl_group` covered it
  -- too, which repainted the one thing in the list whose colour means
  -- something.
  if #self.items > 0 then
    local row = (self.index - 1) * 2
    local bar = #config.options.explorer.icon
    for offset = 0, 1 do
      pcall(vim.api.nvim_buf_set_extmark, self.bufs.list, M.ns, row + offset, bar, {
        end_row = row + offset,
        end_col = #(lines[row + offset + 1] or ""),
        hl_group = "IncommSelection",
        hl_eol = true, -- on past the text, so the row is a block and not a ragged edge
        priority = 20,
      })
    end
    if vim.api.nvim_win_is_valid(self.wins.list) then
      pcall(vim.api.nvim_win_set_cursor, self.wins.list, { row + 1, 0 })
    end
  end
end

--- Syntax-highlight a region of the detail buffer with treesitter, the way the
--- IDE's preview shows real syntax colours rather than flat text.
---@param bufnr integer
---@param first_row integer 0-based row the snippet starts at
---@param text string the snippet
---@param filename string used to work out the language
---@param gutter integer columns the snippet is indented by in the buffer
local function highlight_code(bufnr, first_row, text, filename, gutter)
  local ft = vim.filetype.match({ filename = filename, contents = vim.split(text, "\n") })
  if not ft then
    return
  end
  local ok_lang, lang = pcall(vim.treesitter.language.get_lang, ft)
  if not ok_lang or not lang or not pcall(vim.treesitter.language.add, lang) then
    return
  end
  local ok, err = pcall(function()
    local parser = vim.treesitter.get_string_parser(text, lang)
    local tree = parser:parse()[1]
    local query = vim.treesitter.query.get(lang, "highlights")
    if not tree or not query then
      return
    end
    local lines = vim.split(text, "\n", { plain = true })
    for id, node in query:iter_captures(tree:root(), text) do
      local name = query.captures[id]
      if not name:match("^_") then
        local srow, scol, erow, ecol = node:range()
        -- A capture can span lines (a block comment, a raw string), so paint it
        -- row by row. Columns are shifted by the gutter the snippet is written
        -- with -- without that every colour lands two cells to the left, which
        -- is what made the preview look like confetti.
        for row = srow, math.min(erow, #lines - 1) do
          local from = (row == srow) and scol or 0
          local to = (row == erow) and ecol or #(lines[row + 1] or "")
          if to > from then
            pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, first_row + row, from + gutter, {
              end_col = to + gutter,
              hl_group = "@" .. name .. "." .. lang,
              priority = 90,
            })
          end
        end
      end
    end
  end)
  if not ok then
    vim.notify("incomm: preview highlighting failed: " .. tostring(err), vim.log.levels.DEBUG)
  end
end

---@param self table
local function render_detail(self)
  local buf = self.bufs.detail
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)

  local note = self.items[self.index]
  if not note then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "", "  nothing to show" })
    vim.bo[buf].modifiable = false
    return
  end

  local width = self.geom.detail_w
  local lines, highlights = {}, {}

  ---@param text string
  ---@param ranges table[]?
  local function push(text, ranges)
    lines[#lines + 1] = text
    for _, r in ipairs(ranges or {}) do
      r.row = #lines - 1
      highlights[#highlights + 1] = r
    end
  end

  -- Where the thread lives, and what state it is in.
  local where = note.file .. ":" .. note.startLine
  local state = state_of(note)
  push(" " .. where .. "   " .. state, {
    { col = 1, end_col = 1 + #where, hl = "IncommDetailPath" },
    { col = 2 + #where, end_col = 2 + #where + #state + 2, hl = "IncommState" .. state:sub(1, 1):upper() .. state:sub(2) },
  })
  push("")

  -- The code the thread is anchored to: a single-line note gets one line of
  -- context either side, a range shows itself, capped so a long block cannot
  -- push the conversation off screen.
  local source = self.svc:lines_for(note.file)
  local code_first_row, code_text
  if source and #source > 0 then
    local first, last
    if note.endLine > note.startLine then
      first, last = note.startLine, math.min(note.endLine, note.startLine + 6)
    else
      first, last = note.startLine - 1, note.startLine + 1
    end
    first = math.max(1, math.min(first, #source))
    last = math.max(first, math.min(last, #source))

    code_first_row = #lines
    local snippet = {}
    for l = first, last do
      local text = source[l]:gsub("\t", "    ")
      snippet[#snippet + 1] = text
      push("  " .. text)
      if l >= note.startLine and l <= note.endLine then
        highlights[#highlights + 1] = {
          row = #lines - 1,
          col = 0,
          end_col = -1,
          hl = "IncommPreviewLine",
          line = true,
        }
      end
    end
    code_text = table.concat(snippet, "\n")
    push("")
  end

  -- The conversation.
  local bubble_width = math.max(width - 4, 24)
  local rows = bubble.build({
    author = note.author,
    title = note.authorTitle,
    created = note.createdAt,
    content = note.content,
    width = bubble_width,
    indent = 1,
    border = config.options.card.border,
  })
  for _, reply in ipairs(note.replies) do
    vim.list_extend(
      rows,
      bubble.build({
        author = reply.author,
        title = reply.authorTitle,
        created = reply.createdAt,
        content = reply.content,
        width = math.max(bubble_width - config.options.card.reply_indent, 20),
        indent = 1 + config.options.card.reply_indent,
        border = config.options.card.border,
      })
    )
  end
  local bubble_lines, bubble_highlights = bubble.to_lines(rows, #lines)
  vim.list_extend(lines, bubble_lines)
  vim.list_extend(highlights, bubble_highlights)

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  for _, h in ipairs(highlights) do
    if h.line then
      pcall(vim.api.nvim_buf_set_extmark, buf, M.ns, h.row, 0, {
        line_hl_group = h.hl,
        priority = 10,
      })
    else
      pcall(vim.api.nvim_buf_set_extmark, buf, M.ns, h.row, h.col, {
        end_col = h.end_col,
        hl_group = h.hl,
        hl_mode = "combine",
        priority = 100,
      })
    end
  end
  if code_text then
    highlight_code(buf, code_first_row, code_text, self.svc.store:abs_file(note.file), 2)
  end
  if vim.api.nvim_win_is_valid(self.wins.detail) then
    pcall(vim.api.nvim_win_set_cursor, self.wins.detail, { 1, 0 })
  end
end

---@param self table
---@param keep_index boolean?
local function refresh(self, keep_index)
  local previous = self.items[self.index]
  self.items = collect(self)
  if keep_index and previous then
    for i, note in ipairs(self.items) do
      if note.id == previous.id then
        self.index = i
        break
      end
    end
  end
  self.index = math.max(1, math.min(self.index, math.max(#self.items, 1)))
  render_filters(self)
  render_list(self)
  render_detail(self)
  self:update_titles()
end

-- ---------------------------------------------------------------------------
-- the window frame
-- ---------------------------------------------------------------------------

---@param bufnr integer
local function scratch(bufnr)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
end

---@param self table
function M.close(self)
  self = self or current
  if not self or self.closed then
    return
  end
  self.closed = true
  if self.show_cursor then
    self.show_cursor()
  end
  if self.unsubscribe then
    self.unsubscribe()
  end
  for _, win in pairs(self.wins) do
    if win and vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  if current == self then
    current = nil
  end
end

--- Open the explorer for `svc`, optionally narrowed to one file.
---@param svc incomm.Service
---@param rel? string
function M.open(svc, rel)
  if current then
    M.close(current)
  end

  local opts = config.options.explorer
  local total_w = math.min(math.floor(vim.o.columns * opts.width), vim.o.columns - 4)
  local total_h = math.min(math.floor(vim.o.lines * opts.height), vim.o.lines - 4)
  local list_w = math.max(math.floor(total_w * opts.list_width), 24)
  local detail_w = total_w - list_w - 4
  local body_h = total_h - 4
  local row = math.max(0, math.floor((vim.o.lines - total_h) / 2) - 1)
  local col = math.max(0, math.floor((vim.o.columns - total_w) / 2))

  local self = {
    svc = svc,
    rel = rel,
    query = "",
    index = 1,
    items = {},
    bufs = {},
    wins = {},
    geom = { list_w = list_w, detail_w = detail_w },
  }
  current = self

  ---@param bufnr integer
  ---@param cfg table
  ---@return integer
  local function float(bufnr, cfg)
    local win = vim.api.nvim_open_win(bufnr, false, vim.tbl_extend("force", {
      relative = "editor",
      style = "minimal",
      border = "rounded",
      zindex = 50,
    }, cfg))
    vim.wo[win].winhighlight = "NormalFloat:IncommExplorer,FloatBorder:IncommExplorerBorder,FloatTitle:IncommExplorerTitle"
    vim.wo[win].wrap = false
    return win
  end

  -- The editor behind the explorer, shaded. A window of its own rather than a
  -- `winblend` on the panes: blending the panes would show the code *through*
  -- the threads, and what is wanted is the opposite -- the panes opaque, and
  -- everything they do not cover pushed back.
  if opts.backdrop and opts.backdrop > 0 and opts.backdrop < 100 and vim.o.termguicolors then
    local buf = vim.api.nvim_create_buf(false, true)
    scratch(buf)
    self.wins.backdrop = vim.api.nvim_open_win(buf, false, {
      relative = "editor",
      row = 0,
      col = 0,
      width = vim.o.columns,
      height = vim.o.lines,
      focusable = false,
      style = "minimal",
      zindex = 40, -- under the panes' 50
    })
    vim.wo[self.wins.backdrop].winhighlight = "Normal:IncommBackdrop"
    vim.wo[self.wins.backdrop].winblend = opts.backdrop
  end

  for _, name in ipairs({ "search", "filters", "list", "detail" }) do
    self.bufs[name] = vim.api.nvim_create_buf(false, true)
    scratch(self.bufs[name])
  end

  self.wins.search = float(self.bufs.search, {
    row = row, col = col, width = list_w, height = 1, title = " search ", title_pos = "left",
  })
  self.wins.filters = float(self.bufs.filters, {
    row = row, col = col + list_w + 2, width = detail_w, height = 1,
  })
  self.wins.list = float(self.bufs.list, {
    row = row + 3, col = col, width = list_w, height = body_h,
  })
  self.wins.detail = float(self.bufs.detail, {
    row = row + 3, col = col + list_w + 2, width = detail_w, height = body_h,
  })
  vim.wo[self.wins.detail].wrap = false
  vim.bo[self.bufs.list].modifiable = false
  vim.bo[self.bufs.detail].modifiable = false

  function self:update_titles()
    local count = #self.items
    local title = string.format(" threads  %d ", count)
    if self.rel then
      title = string.format(" %s  %d ", vim.fn.fnamemodify(self.rel, ":t"), count)
    end
    pcall(vim.api.nvim_win_set_config, self.wins.list, { title = title, title_pos = "left" })
    local note = self.items[self.index]
    pcall(vim.api.nvim_win_set_config, self.wins.detail, {
      title = note and string.format(" thread %d/%d ", self.index, count) or " thread ",
      title_pos = "left",
    })
  end

  -- ---- actions ------------------------------------------------------------

  ---@return incomm.Note?
  local function selected()
    return self.items[self.index]
  end

  local function move(delta)
    if #self.items == 0 then
      return
    end
    self.index = math.max(1, math.min(self.index + delta, #self.items))
    render_list(self)
    render_detail(self)
    self:update_titles()
  end

  local function goto_thread()
    local note = selected()
    if not note then
      return
    end
    local path = svc.store:abs_file(note.file)
    M.close(self)
    vim.schedule(function()
      vim.cmd.edit(vim.fn.fnameescape(path))
      local line = math.min(note.startLine, vim.api.nvim_buf_line_count(0))
      vim.api.nvim_win_set_cursor(0, { math.max(line, 1), 0 })
      vim.cmd("normal! ^zz")
    end)
  end

  local function toggle_filter(name)
    M.filters[name] = not M.filters[name]
    refresh(self, true)
  end

  local function focus_search()
    vim.api.nvim_set_current_win(self.wins.search)
    vim.cmd.startinsert({ bang = true })
  end

  -- ---- the cursor ---------------------------------------------------------
  --
  -- Focus sits in the list, where there is nothing to type, and the block
  -- cursor parks on the selected row's first column -- a whole inverted cell
  -- over the bar, twice its width and in the cursor's own colour, which is
  -- what made a selected thread's state unreadable. The selection already says
  -- which row it is, so the cursor is hidden while the list has focus and
  -- comes straight back in the search box, where it is what you type against.
  local saved_guicursor
  local function hide_cursor()
    if not saved_guicursor then
      saved_guicursor = vim.o.guicursor
      vim.o.guicursor = "a:IncommHiddenCursor"
    end
  end
  local function show_cursor()
    if saved_guicursor then
      vim.o.guicursor = saved_guicursor
      saved_guicursor = nil
    end
  end
  self.show_cursor = show_cursor

  -- ---- keys ---------------------------------------------------------------

  local function map(buf, lhs, fn, mode)
    vim.keymap.set(mode or "n", lhs, fn, { buffer = buf, nowait = true, silent = true })
  end

  local list = self.bufs.list
  map(list, "j", function() move(1) end)
  map(list, "k", function() move(-1) end)
  map(list, "<Down>", function() move(1) end)
  map(list, "<Up>", function() move(-1) end)
  map(list, "gg", function() self.index = 1; render_list(self); render_detail(self); self:update_titles() end)
  map(list, "G", function() self.index = math.max(#self.items, 1); render_list(self); render_detail(self); self:update_titles() end)
  map(list, "<CR>", goto_thread)
  map(list, "q", function() M.close(self) end)
  map(list, "<Esc>", function() M.close(self) end)
  map(list, "<C-c>", function() M.close(self) end)

  map(list, "r", function()
    local note = selected()
    if note then
      composer.open({
        title = "incomm: reply to " .. format.range(note),
        anchor = "center",
        on_submit = function(content)
          svc:add_reply(note.id, content)
        end,
      })
    end
  end)
  map(list, "e", function()
    local note = selected()
    if note and note.author == require("incomm.model").AUTHOR_USER then
      composer.open({
        title = "incomm: edit comment",
        text = note.content,
        anchor = "center",
        on_submit = function(content)
          svc:update_content(note.id, content)
        end,
      })
    else
      vim.notify("incomm: only your own comments are editable", vim.log.levels.WARN)
    end
  end)
  map(list, "x", function()
    local note = selected()
    if note then
      svc:set_resolved(note.id, not note.resolved)
    end
  end)
  map(list, "d", function()
    local note = selected()
    if note then
      svc:remove_note(note.id)
    end
  end)
  map(list, "<Del>", function()
    local note = selected()
    if note then
      svc:remove_note(note.id)
    end
  end)

  -- The IDE's ⌘O / ⌘R / ⌘X checkboxes.
  map(list, "<C-o>", function() toggle_filter("open") end)
  map(list, "<C-r>", function() toggle_filter("resolved") end)
  map(list, "<C-x>", function() toggle_filter("orphaned") end)
  map(list, "/", focus_search)
  map(list, "<C-f>", focus_search)
  map(list, "i", focus_search)
  map(list, "?", function() M.help(self) end)

  -- Long threads: scroll the detail pane without leaving the list.
  map(list, "<C-d>", function()
    pcall(vim.api.nvim_win_call, self.wins.detail, function()
      vim.cmd("normal! \4")
    end)
  end)
  map(list, "<C-u>", function()
    pcall(vim.api.nvim_win_call, self.wins.detail, function()
      vim.cmd("normal! \21")
    end)
  end)

  local search = self.bufs.search
  local function leave_search()
    vim.cmd.stopinsert()
    vim.api.nvim_set_current_win(self.wins.list)
  end
  map(search, "<CR>", leave_search, { "n", "i" })
  map(search, "<Esc>", leave_search, { "n", "i" })
  map(search, "<C-c>", function()
    vim.api.nvim_buf_set_lines(search, 0, -1, false, { "" })
    self.query = ""
    refresh(self)
    leave_search()
  end, { "n", "i" })
  map(search, "<Down>", function() move(1) end, { "n", "i" })
  map(search, "<Up>", function() move(-1) end, { "n", "i" })

  local group = vim.api.nvim_create_augroup("incomm_explorer_" .. search, { clear = true })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    buffer = search,
    callback = function()
      self.query = vim.trim(vim.api.nvim_buf_get_lines(search, 0, 1, false)[1] or "")
      self.index = 1
      refresh(self)
    end,
  })
  vim.api.nvim_create_autocmd("BufEnter", { group = group, buffer = self.bufs.list, callback = hide_cursor })
  vim.api.nvim_create_autocmd("BufLeave", { group = group, buffer = self.bufs.list, callback = show_cursor })

  -- Closing one window closes the whole thing, so no float is ever orphaned.
  for _, win in pairs(self.wins) do
    vim.api.nvim_create_autocmd("WinClosed", {
      group = group,
      pattern = tostring(win),
      once = true,
      callback = function()
        M.close(self)
      end,
    })
  end

  -- A reply written here, or anything the agent does while it is open, redraws.
  self.unsubscribe = svc:on_change(function()
    vim.schedule(function()
      if not self.closed then
        refresh(self, true)
      end
    end)
  end)

  refresh(self)
  vim.api.nvim_set_current_win(self.wins.list)
  hide_cursor()
end

--- The key list, on `?`.
---@param self table?
function M.help(self)
  self = self or current
  local rows = {
    { "j / k", "next / previous thread" },
    { "<CR>", "go to the code" },
    { "r", "reply" },
    { "e", "edit your comment" },
    { "x", "resolve / reopen" },
    { "d", "delete the thread" },
    { "/", "search" },
    { "<C-o>", "show open threads" },
    { "<C-r>", "show resolved threads" },
    { "<C-x>", "show orphaned threads" },
    { "<C-d> / <C-u>", "scroll the thread" },
    { "q", "close" },
  }
  local key_w, desc_w = 0, 0
  for _, r in ipairs(rows) do
    key_w = math.max(key_w, #r[1])
    desc_w = math.max(desc_w, #r[2])
  end
  local width = key_w + desc_w + 6
  local lines = {}
  for _, r in ipairs(rows) do
    lines[#lines + 1] = string.format("  %-" .. key_w .. "s  %s", r[1], r[2])
  end

  local buf = vim.api.nvim_create_buf(false, true)
  scratch(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width + 2,
    height = #lines,
    row = math.floor((vim.o.lines - #lines) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = " incomm explorer ",
    title_pos = "center",
    zindex = 60,
  })
  vim.wo[win].winhighlight = "NormalFloat:IncommExplorer,FloatBorder:IncommExplorerBorder,FloatTitle:IncommExplorerTitle"
  for i = 1, #lines do
    pcall(vim.api.nvim_buf_set_extmark, buf, M.ns, i - 1, 0, {
      end_col = 2 + #rows[i][1],
      hl_group = "IncommHelpKey",
    })
  end
  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    if self and not self.closed and vim.api.nvim_win_is_valid(self.wins.list) then
      vim.api.nvim_set_current_win(self.wins.list)
    end
  end
  for _, key in ipairs({ "q", "<Esc>", "?", "<CR>", "<C-c>" }) do
    vim.keymap.set("n", key, close, { buffer = buf, nowait = true, silent = true })
  end
end

--- The explorer currently on screen, if any (tests).
function M.current()
  return current
end

return M
