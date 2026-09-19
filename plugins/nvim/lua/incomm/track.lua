-- Live position tracking: the extmark side of the plugin.
--
-- This is the Neovim answer to the IntelliJ tracker's `RangeMarker` + debounced
-- document listener (AGENTS.md §7.7, §11.5). Each thread gets an extmark over
-- its line range, so ordinary editing moves it for free; a debounced pass then
-- reads those marks back and persists the new positions, refreshing each note's
-- anchor text as it goes, so the CLI and the agent always see current lines.
--
-- Two details are load-bearing:
--
--   * `invalidate = true` on the mark. When the lines a thread covers are
--     deleted outright the mark goes invalid, and an invalid mark is *omitted*
--     from the position map -- which is the signal for the service to fall back
--     to a text re-anchor (and to orphan the note if that fails too), exactly
--     as the IDE does with a dead RangeMarker.
--   * position-only changes persist quietly. The extmarks have already moved
--     the cards, so publishing a change would redraw the buffer for nothing.

local config = require("incomm.config")
local render = require("incomm.ui.render")
local service = require("incomm.service")
local ui_state = require("incomm.ui.state")

local M = {}

M.ns = vim.api.nvim_create_namespace("incomm_track")

---@class incomm.Tracked
---@field svc incomm.Service
---@field rel string
---@field marks table<string, integer> note id -> extmark id
---@field timer uv.uv_timer_t?
---@field pending boolean
---@field flushing boolean
---@field unsubscribe fun()?

---@type table<integer, incomm.Tracked>
local tracked = {}

local augroup = vim.api.nvim_create_augroup("incomm_track", { clear = true })

---@param bufnr integer
---@return incomm.Tracked?
function M.get(bufnr)
  return tracked[bufnr or vim.api.nvim_get_current_buf()]
end

--- Place one extmark per thread, from the model's stored positions.
---@param bufnr integer
---@param t incomm.Tracked
local function rebuild_marks(bufnr, t)
  vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
  t.marks = {}
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  for _, note in ipairs(t.svc:notes_for_file(t.rel)) do
    if not note.orphaned then
      local s = math.max(1, math.min(note.startLine, line_count))
      local e = math.max(s, math.min(note.endLine, line_count))
      local end_line = vim.api.nvim_buf_get_lines(bufnr, e - 1, e, false)[1] or ""
      local ok, id = pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, s - 1, 0, {
        end_row = e - 1,
        end_col = #end_line,
        -- Text typed at the very start of the range pushes the thread down with
        -- the code it belongs to; text appended past its end stays outside.
        right_gravity = true,
        end_right_gravity = false,
        invalidate = true,
      })
      if ok then
        t.marks[note.id] = id
      end
    end
  end
end

--- Live line range of every tracked thread, by note id.
---@param bufnr integer
---@return table<string, integer[]>
function M.live_positions(bufnr)
  local t = tracked[bufnr]
  local out = {}
  if not t then
    return out
  end
  for id, mark in pairs(t.marks) do
    local m = vim.api.nvim_buf_get_extmark_by_id(bufnr, M.ns, mark, { details = true })
    if m and m[1] and not (m[3] or {}).invalid then
      local s = m[1] + 1
      local e = ((m[3] or {}).end_row or m[1]) + 1
      out[id] = { s, math.max(s, e) }
    end
  end
  return out
end

--- Redraw one buffer from the model, using live mark positions.
---@param bufnr integer
function M.render_buf(bufnr)
  local t = tracked[bufnr]
  if not t or not vim.api.nvim_buf_is_loaded(bufnr) then
    return
  end
  render.render(bufnr, t.svc, t.rel, M.live_positions(bufnr))
end

--- Read the marks back and persist the positions they moved to.
---@param bufnr integer
function M.flush(bufnr)
  local t = tracked[bufnr]
  if not t or t.flushing or not vim.api.nvim_buf_is_loaded(bufnr) then
    return
  end
  t.pending = false
  t.flushing = true
  local ok, err = pcall(function()
    local positions = {}
    for id, mark in pairs(t.marks) do
      local note = t.svc:find(id)
      -- Orphaned notes are floated to line 1 for display only; never persist
      -- that synthetic position -- let the service re-anchor them by text.
      if note and not note.orphaned then
        local m = vim.api.nvim_buf_get_extmark_by_id(bufnr, M.ns, mark, { details = true })
        if m and m[1] and not (m[3] or {}).invalid then
          local s = m[1] + 1
          local e = ((m[3] or {}).end_row or m[1]) + 1
          positions[id] = { s, math.max(s, e) }
        end
      end
    end
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    t.svc:apply_saved_positions(t.rel, lines, positions)
  end)
  t.flushing = false
  if not ok then
    vim.notify("incomm: re-anchor failed: " .. tostring(err), vim.log.levels.WARN)
    return
  end
  -- The cards moved with the text on their own, but their `L42` headers and any
  -- note that just un-orphaned need redrawing.
  M.render_buf(bufnr)
end

---@param bufnr integer
local function schedule_flush(bufnr)
  local t = tracked[bufnr]
  if not t then
    return
  end
  t.pending = true
  if t.timer then
    t.timer:stop()
  end
  t.timer = vim.defer_fn(function()
    M.flush(bufnr)
  end, config.options.reanchor_delay)
end

--- Rebuild marks and redraw a buffer after the model changed underneath it.
---@param bufnr integer
function M.refresh(bufnr)
  local t = tracked[bufnr]
  if not t or not vim.api.nvim_buf_is_loaded(bufnr) then
    return
  end
  -- Flush first when edits are still pending, so the marks we are about to
  -- rebuild from the model are not overwritten with stale line numbers.
  if t.pending and not t.flushing then
    M.flush(bufnr)
  end
  rebuild_marks(bufnr, t)
  M.render_buf(bufnr)
end

--- Refresh every tracked buffer (a model change can touch any of them).
function M.refresh_all()
  for bufnr in pairs(tracked) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      M.refresh(bufnr)
    else
      M.detach(bufnr)
    end
  end
end

---@param bufnr integer
function M.detach(bufnr)
  local t = tracked[bufnr]
  if not t then
    return
  end
  if t.timer then
    t.timer:stop()
  end
  if t.unsubscribe then
    t.unsubscribe()
  end
  tracked[bufnr] = nil
  if vim.api.nvim_buf_is_valid(bufnr) then
    pcall(vim.api.nvim_buf_clear_namespace, bufnr, M.ns, 0, -1)
    render.clear(bufnr)
  end
end

--- Start tracking a buffer, if it is a real file inside a project incomm knows.
---@param bufnr? integer
---@return incomm.Tracked?
function M.attach(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if tracked[bufnr] then
    return tracked[bufnr]
  end
  if not vim.api.nvim_buf_is_loaded(bufnr) or vim.bo[bufnr].buftype ~= "" then
    return nil
  end
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then
    return nil
  end
  local svc = service.for_path(name)
  if not svc then
    return nil
  end
  local rel = svc.store:rel_file(name)
  if not rel then
    return nil
  end

  local t = { svc = svc, rel = rel, marks = {}, pending = false, flushing = false }
  tracked[bufnr] = t

  -- Any model change (ours, the agent's, a branch switch) redraws this buffer.
  t.unsubscribe = svc:on_change(function()
    vim.schedule(function()
      if tracked[bufnr] then
        M.refresh(bufnr)
      end
    end)
  end)

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "InsertLeave" }, {
    group = augroup,
    buffer = bufnr,
    callback = function()
      schedule_flush(bufnr)
    end,
  })
  -- Saving is the moment the on-disk file catches up with the buffer, so flush
  -- immediately rather than waiting out the debounce.
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = augroup,
    buffer = bufnr,
    callback = function()
      M.flush(bufnr)
    end,
  })
  vim.api.nvim_create_autocmd({ "BufUnload", "BufWipeout" }, {
    group = augroup,
    buffer = bufnr,
    callback = function()
      M.detach(bufnr)
    end,
  })
  if config.options.add_hint then
    vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
      group = augroup,
      buffer = bufnr,
      callback = function()
        render.add_hint(bufnr, svc, rel, vim.api.nvim_win_get_cursor(0)[1])
      end,
    })
  end
  -- A resized window changes how the card wraps.
  vim.api.nvim_create_autocmd("WinResized", {
    group = augroup,
    buffer = bufnr,
    callback = function()
      M.render_buf(bufnr)
    end,
  })

  rebuild_marks(bufnr, t)
  M.render_buf(bufnr)
  return t
end

--- The thread under the cursor, using live positions so it is right even
--- between edits and the debounced re-anchor.
---@param bufnr? integer
---@param line? integer
---@return incomm.Note?, incomm.Service?, string?
function M.note_at_cursor(bufnr, line)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local t = tracked[bufnr] or M.attach(bufnr)
  if not t then
    return nil
  end
  line = line or vim.api.nvim_win_get_cursor(0)[1]
  local live = M.live_positions(bufnr)
  local best
  for _, note in ipairs(t.svc:notes_for_file(t.rel)) do
    local pos = live[note.id]
    local s, e
    if note.orphaned and not note.resolved then
      s, e = 1, 1
    elseif pos then
      s, e = pos[1], pos[2]
    else
      s, e = note.startLine, note.endLine
    end
    if line >= s and line <= e then
      if not best or (e - s) < (best.span) then
        best = { note = note, span = e - s }
      end
    end
  end
  if not best then
    return nil, t.svc, t.rel
  end
  return best.note, t.svc, t.rel
end

--- Attach every already-open buffer (used at setup and after `:Incomm reload`).
function M.attach_all()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      M.attach(bufnr)
    end
  end
end

--- Re-render everything without touching the model (colours, config changes,
--- card visibility).
function M.redraw_all()
  ui_state.prune(vim.iter(service.all()):fold({}, function(acc, svc)
    vim.list_extend(acc, svc:all_notes())
    return acc
  end))
  for bufnr in pairs(tracked) do
    M.render_buf(bufnr)
  end
end

M.tracked = tracked

return M
