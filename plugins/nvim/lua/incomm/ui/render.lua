-- Drawing threads into a buffer: sign-column icons, inline cards, the range
-- band and the "+" hint.
--
-- The IntelliJ plugin embeds real Swing components as inlays; a terminal has no
-- such thing, so a card here is a block of `virt_lines` hung above the note's
-- first line. Everything the IDE puts on the card that a mouse would reach --
-- resolve, reply, delete -- is an action on the thread under the cursor
-- instead, which is how a Vim user expects to drive it anyway.
--
-- Two rules carried over from the IDE (AGENTS.md §11.4 step 4):
--   * an orphaned but unresolved note floats to line 1, since its real anchor
--     is lost and it must stay reachable;
--   * an orphaned *and* resolved note is not drawn at all.
--
-- A thread's extent is shown the way the IDE shows it: the icon on its first
-- line and a thin band down the rest of its range, both in the sign column.
-- Nothing paints the lines themselves -- they belong to the code.

local bubble = require("incomm.ui.bubble")
local config = require("incomm.config")
local format = require("incomm.ui.format")
local hl = require("incomm.ui.highlights")
local state = require("incomm.ui.state")

local M = {}

M.ns = vim.api.nvim_create_namespace("incomm")
M.ns_add = vim.api.nvim_create_namespace("incomm_add")

--- Display width of a line's leading whitespace, tabs expanded the way the
--- buffer itself expands them.
---@param bufnr integer
---@param line integer 1-based
---@return integer
local function code_indent(bufnr, line)
  local text = vim.api.nvim_buf_get_lines(bufnr, line - 1, line, false)[1]
  if not text then
    return 0
  end
  local leading = text:match("^[ \t]*") or ""
  local tabstop = vim.bo[bufnr].tabstop
  local width = 0
  for i = 1, #leading do
    if leading:sub(i, i) == "\t" then
      width = width + (tabstop - (width % tabstop))
    else
      width = width + 1
    end
  end
  return width
end

--- Columns available for a card in the first window showing `bufnr`.
---@param bufnr integer
---@return integer
local function text_width(bufnr)
  local width = 80
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == bufnr then
      local info = vim.fn.getwininfo(win)[1]
      width = vim.api.nvim_win_get_width(win) - (info and info.textoff or 0)
      break
    end
  end
  return math.max(width, 24)
end

--- The virt_lines block for one thread.
---
--- A muted header line naming the range and the state, then one bordered
--- bubble per message, replies indented inside the thread. Every bubble is the
--- configured width whatever its text, so a file full of threads keeps a
--- straight left and right edge instead of a ragged one.
---@param note incomm.Note
---@param start_line integer 1-based line the card hangs against (its live position)
---@param end_line integer
---@param available integer columns the window can give the card
---@param indent integer? columns to shift it right, to sit over its own code
---@return table[][] virt_lines
function M.card_lines(note, start_line, end_line, available, indent)
  local opts = config.options.card
  indent = indent or 0
  local width = math.max(math.min(opts.width, available - indent), 20)
  local rows = {}

  -- Header: the range and the thread's state, above the box.
  local range = note.endLine ~= note.startLine and string.format("L%d-%d", start_line, end_line)
    or ("L" .. start_line)
  local state = hl.state_suffix(note)
  -- The one thing that stays filled: a small tab naming the line and the state,
  -- padded on both sides so the block closes cleanly around the text.
  rows[#rows + 1] = {
    { " " .. range, "IncommCardLine" },
    { "  ", "IncommCard" },
    { format.state(note), "IncommCardState" .. state },
    { " ", "IncommCard" },
  }

  vim.list_extend(
    rows,
    bubble.build({
      author = note.author,
      title = note.authorTitle,
      created = note.createdAt,
      content = note.content,
      width = width,
      border = opts.border,
    })
  )

  -- Not named `indent`: that is the parameter holding the card's own offset,
  -- and shadowing it here once left every card indented by the reply gap.
  local reply_indent = opts.reply_indent
  for _, reply in ipairs(note.replies) do
    vim.list_extend(
      rows,
      bubble.build({
        author = reply.author,
        title = reply.authorTitle,
        created = reply.createdAt,
        content = reply.content,
        -- Nested and a little narrower, so the reply reads as an answer to the
        -- message above rather than as a second thread.
        width = math.max(width - reply_indent, 20),
        indent = reply_indent,
        border = opts.border,
      })
    )
  end

  if opts.trailing_blank then
    rows[#rows + 1] = { { "", "IncommCard" } }
  end

  -- Shift the whole card over its code. Replies keep their own indent on top
  -- of this, so the thread stays nested relative to the comment it answers.
  if indent > 0 then
    local lead = string.rep(" ", indent)
    for _, row in ipairs(rows) do
      table.insert(row, 1, { lead })
    end
  end
  return rows
end

--- Where a note is drawn right now: its live extmark position when the buffer
--- is tracked, its stored position otherwise, and line 1 when it is orphaned.
---@param note incomm.Note
---@param live integer[]? {start, end} from the tracking extmark
---@param line_count integer
---@return integer?, integer? nil when the note must not be drawn
local function display_range(note, live, line_count)
  if note.orphaned then
    if note.resolved then
      return nil -- lost its anchor and already handled: keep it out of the way
    end
    return 1, 1
  end
  local s, e = note.startLine, note.endLine
  if live then
    s, e = live[1], live[2]
  end
  s = math.max(1, math.min(s, line_count))
  e = math.max(s, math.min(e, line_count))
  return s, e
end

--- Redraw every thread of `bufnr`.
---@param bufnr integer
---@param svc incomm.Service
---@param rel string
---@param live_positions table<string, integer[]> live extmark positions by note id
function M.render(bufnr, svc, rel, live_positions)
  if not vim.api.nvim_buf_is_loaded(bufnr) then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)

  local notes = svc:notes_for_file(rel)
  if #notes == 0 then
    return
  end
  state.apply_defaults(notes)
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local width = text_width(bufnr)
  local signs = config.options.signs

  for _, note in ipairs(notes) do
    local s, e = display_range(note, live_positions[note.id], line_count)
    if s then
      local show_card = config.options.cards and not state.is_hidden(note.id)
      local sign_hl = hl.sign_for_state(note)
      local opts = {
        priority = signs.priority,
        hl_mode = "combine",
      }
      if signs.enabled then
        opts.sign_text = note.orphaned and signs.orphaned or (note.resolved and signs.resolved or signs.open)
        opts.sign_hl_group = sign_hl
      end
      if show_card then
        local indent = config.options.card.align_to_code and code_indent(bufnr, s) or 0
        opts.virt_lines = M.card_lines(note, s, e, width, indent)
        -- Above the code it belongs to -- except on line 1, where Neovim draws
        -- nothing at all above the first buffer line. There the card goes
        -- directly below instead, which matters more than it sounds: an
        -- orphaned thread floats to line 1, so that is exactly where a thread
        -- that needs attention ends up.
        opts.virt_lines_above = s > 1
      end
      pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, s - 1, 0, opts)

      -- The icon marks the thread's first line; the rest of its range gets a
      -- thin band, which is the terminal's answer to the IDE's gutter band.
      if signs.enabled and signs.range and e > s then
        for line = s + 1, e do
          pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, line - 1, 0, {
            sign_text = signs.range,
            sign_hl_group = sign_hl,
            priority = signs.priority - 1,
          })
        end
      end
    end
  end
end

--- The "+" affordance on a cursor line that carries no thread.
---@param bufnr integer
---@param svc incomm.Service
---@param rel string
---@param line integer
function M.add_hint(bufnr, svc, rel, line)
  vim.api.nvim_buf_clear_namespace(bufnr, M.ns_add, 0, -1)
  if not config.options.add_hint or svc:note_at(rel, line) then
    return
  end
  pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns_add, line - 1, 0, {
    sign_text = "+",
    sign_hl_group = "IncommAddHint",
    priority = config.options.signs.priority - 1,
  })
end

---@param bufnr integer
function M.clear(bufnr)
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
    vim.api.nvim_buf_clear_namespace(bufnr, M.ns_add, 0, -1)
  end
end

return M
