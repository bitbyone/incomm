-- A dialog listing the comments of one thread, one entry per comment.
--
-- The cursor and the explorer's selection belong to a thread, but editing,
-- deleting or re-addressing a message is about one comment of it. This is where
-- that comment is picked: the thread's own comment first, its replies indented
-- under it, each as two lines -- who and when (plus whatever the caller puts on
-- the right), then as much of the text as fits.
--
-- It opens in navigation mode, never in a prompt: j/k (or the arrow keys) move,
-- and the caller decides what the other keys do. A picker from `vim.ui.select`
-- starts in its filter field, which is the wrong mode for choosing one of three
-- messages.

local bubble = require("incomm.ui.bubble")
local config = require("incomm.config")
local format = require("incomm.ui.format")
local hl = require("incomm.ui.highlights")
local model = require("incomm.model")

local M = {}

M.ns = vim.api.nvim_create_namespace("incomm_comments")

--- Rows per comment in the dialog.
M.ROW_LINES = 2

--- The comments of a thread as dialog rows, the thread's own first.
---
--- `audience` is what the comment stores. A reply under a private root is
--- private whatever it stores; `inherited` says so.
---@param note incomm.Note
---@return table[]
function M.rows(note)
  local root_private = model.normalize_audience(note.audience) == model.AUDIENCE_PRIVATE
  local function row(comment, reply_id)
    local audience = model.normalize_audience(comment.audience)
    local out_row = {
      reply_id = reply_id,
      author = comment.author,
      name = format.author(comment.author, comment.authorTitle),
      created = comment.createdAt,
      content = comment.content,
      audience = audience,
      published = model.is_published(comment),
      inherited = reply_id ~= nil and root_private and audience ~= model.AUDIENCE_PRIVATE,
      -- The audiences it may take: fewer once it is on the forge.
      cycle = model.audience_cycle(note, comment),
      on_forge = model.has_source(comment),
    }
    out_row.editable, out_row.not_editable = model.can_edit(note, comment)
    out_row.deletable, out_row.not_deletable = model.can_delete(note, comment)
    return out_row
  end
  local out = { row(note, nil) }
  for _, reply in ipairs(note.replies) do
    out[#out + 1] = row(reply, reply.id)
  end
  return out
end

--- The two lines of one entry, as chunk rows.
---@param row table
---@param width integer inner width of the dialog
---@param right? table[] chunks for the right end of the first line
---@param right_w? integer their display width
---@return table[][]
function M.entry(row, width, right, right_w)
  right, right_w = right or {}, right_w or 0
  local indent = row.reply_id and string.rep(" ", config.options.card.reply_indent) or ""
  local time = format.time(row.created)
  -- What is on the merge request says so: it cannot be edited or deleted here.
  local forge = row.on_forge and "  · on the MR" or ""
  local head_w = 1 + #indent + vim.fn.strdisplaywidth(row.name) + 2 + vim.fn.strdisplaywidth(time)
    + vim.fn.strdisplaywidth(forge)
  local pad = math.max(width - head_w - right_w - 1, 1)
  local first = {
    { " " .. indent },
    { row.name, "IncommName" .. hl.author_suffix(row.author) },
    { "  " .. time, "IncommMuted" },
    { forge, "IncommBadgePublished" },
    { string.rep(" ", pad) },
  }
  vim.list_extend(first, right)
  first[#first + 1] = { " " }

  local text_w = math.max(width - 2 - #indent - 2, 8)
  local second = {
    { " " .. indent .. "  " },
    { format.preview(row.content, text_w), "IncommText" .. hl.author_suffix(row.author) },
  }
  return { first, second }
end

local current

--- The dialog on screen, if any (tests).
function M.current()
  return current
end

---@param self table?
function M.close(self)
  self = self or current
  if not self or self.closed then
    return
  end
  self.closed = true
  if self.saved_guicursor then
    vim.o.guicursor = self.saved_guicursor
  end
  if self.unsubscribe then
    self.unsubscribe()
  end
  if vim.api.nvim_win_is_valid(self.win) then
    pcall(vim.api.nvim_win_close, self.win, true)
  end
  if self.return_win and vim.api.nvim_win_is_valid(self.return_win) then
    pcall(vim.api.nvim_set_current_win, self.return_win)
  end
  if current == self then
    current = nil
  end
end

--- The row under the selection.
---@param self table
---@return table?
function M.selected(self)
  return self.rows[self.index]
end

---@param self table
function M.draw(self)
  local note = self.svc:find(self.note_id)
  if not note then
    M.close(self)
    return
  end
  self.rows = vim.tbl_filter(self.filter, M.rows(note))
  if #self.rows == 0 then
    M.close(self)
    return
  end
  self.index = math.max(1, math.min(self.index, #self.rows))

  local chunk_rows = {}
  for _, row in ipairs(self.rows) do
    local right, right_w
    if self.right then
      right, right_w = self.right(row)
    end
    vim.list_extend(chunk_rows, M.entry(row, self.width, right, right_w))
  end
  local lines, highlights = bubble.to_lines(chunk_rows, 0)
  -- Every line padded to the dialog, so the selection is a block to its edge.
  for i, line in ipairs(lines) do
    local pad = self.width - vim.fn.strdisplaywidth(line)
    if pad > 0 then
      lines[i] = line .. string.rep(" ", pad)
    end
  end

  vim.bo[self.buf].modifiable = true
  vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, lines)
  vim.bo[self.buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(self.buf, M.ns, 0, -1)
  bubble.apply(self.buf, M.ns, highlights)
  local first = (self.index - 1) * M.ROW_LINES
  for offset = 0, M.ROW_LINES - 1 do
    pcall(vim.api.nvim_buf_set_extmark, self.buf, M.ns, first + offset, 0, {
      end_row = first + offset,
      end_col = #lines[first + offset + 1],
      hl_group = "IncommSelection",
      hl_eol = true,
      priority = 20,
    })
  end
  if vim.api.nvim_win_is_valid(self.win) then
    local height = math.min(#lines, math.max(vim.o.lines - 6, M.ROW_LINES))
    pcall(vim.api.nvim_win_set_config, self.win, { height = height })
    -- The second line first, then the first, so a scrolled window shows the
    -- whole entry.
    pcall(vim.api.nvim_win_set_cursor, self.win, { first + M.ROW_LINES, 0 })
    pcall(vim.api.nvim_win_set_cursor, self.win, { first + 1, 0 })
  end
end

---@class incomm.CommentsOpts
---@field svc incomm.Service
---@field note incomm.Note
---@field title string
---@field footer string key hints
---@field filter? fun(row: table): boolean which comments are listed; all by default
---@field right? fun(row: table): table[], integer chunks for the right of the first line, and their width
---@field keys? table<string, fun(self: table, row: table)> extra keys, called with the selected row
---@field on_choose? fun(row: table) <CR>: close the dialog, then this; without it <CR> just closes

--- Open the dialog.
---@param opts incomm.CommentsOpts
---@return table? the dialog
function M.open(opts)
  if current then
    M.close(current)
  end

  local width = math.min(config.options.comments.width, vim.o.columns - 4)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false

  local self = {
    svc = opts.svc,
    note_id = opts.note.id,
    index = 1,
    width = width,
    buf = buf,
    filter = opts.filter or function()
      return true
    end,
    right = opts.right,
    return_win = vim.api.nvim_get_current_win(),
  }
  current = self

  local height = (#opts.note.replies + 1) * M.ROW_LINES
  self.win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = math.min(height, math.max(vim.o.lines - 6, M.ROW_LINES)),
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    style = "minimal",
    border = "rounded",
    title = " " .. opts.title .. " ",
    title_pos = "left",
    footer = " " .. opts.footer .. " ",
    footer_pos = "right",
    zindex = 70, -- over the explorer, which it can be opened from
  })
  -- The composer's look: the float's own background, darker than the code
  -- in most schemes, so the dialog stands off what is behind it.
  vim.wo[self.win].winhighlight = "FloatTitle:IncommComposerTitle,FloatFooter:IncommComposerHint"
  vim.wo[self.win].wrap = false

  -- The selection says where you are; a block cursor would only cover the indent.
  self.saved_guicursor = vim.o.guicursor
  vim.o.guicursor = "a:IncommHiddenCursor"

  local function move(delta)
    self.index = math.max(1, math.min(self.index + delta, #self.rows))
    M.draw(self)
  end

  local function map(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true })
  end
  for _, key in ipairs({ "j", "<Down>", "<Tab>" }) do
    map(key, function() move(1) end)
  end
  for _, key in ipairs({ "k", "<Up>", "<S-Tab>" }) do
    map(key, function() move(-1) end)
  end
  map("gg", function() move(-math.huge) end)
  map("G", function() move(math.huge) end)
  for _, key in ipairs({ "<Esc>", "q", "<C-c>" }) do
    map(key, function() M.close(self) end)
  end
  map("<CR>", function()
    local row = M.selected(self)
    M.close(self)
    if row and opts.on_choose then
      opts.on_choose(row)
    end
  end)
  for lhs, fn in pairs(opts.keys or {}) do
    map(lhs, function()
      local row = M.selected(self)
      if row then
        fn(self, row)
      end
    end)
  end

  local group = vim.api.nvim_create_augroup("incomm_comments_" .. buf, { clear = true })
  vim.api.nvim_create_autocmd("WinLeave", {
    group = group,
    buffer = buf,
    once = true,
    callback = function()
      if self.closed then
        return
      end
      -- Clicking away, or a :wincmd, closes it like <Esc> does; deferred so the
      -- window being entered is not yanked back by `return_win`.
      self.return_win = nil
      vim.schedule(function()
        M.close(self)
      end)
    end,
  })

  -- The agent answering while the dialog is open adds a row; a deleted thread
  -- closes it.
  self.unsubscribe = opts.svc:on_change(function()
    vim.schedule(function()
      if not self.closed then
        M.draw(self)
      end
    end)
  end)

  M.draw(self)
  if self.closed then
    return nil
  end
  return self
end

return M
