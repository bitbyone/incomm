-- Every user-facing operation, one function per IntelliJ action.
--
-- The mapping to `plugins/intellij/.../actions/` is deliberate and complete:
--
--   incomm.StartThread      -> start_thread      (`:Incomm thread`, range-aware)
--   incomm.Reply            -> reply
--   incomm.EditComment      -> edit
--   incomm.ResolveThread    -> resolve           (toggles; resolving collapses)
--   incomm.ToggleThread     -> toggle_thread
--   incomm.DeleteThread     -> delete_thread
--   incomm.ToggleAllThreads -> toggle_all
--   incomm.ToggleResolved   -> toggle_resolved
--   incomm.ClearFile        -> clear_file        (confirms)
--   incomm.ClearAllThreads  -> clear_all         (confirms)
--   incomm.OpenExplorer     -> explorer
--   incomm.OpenFileExplorer -> explorer_file
--   incomm.Reload           -> reload
--   toggle detect changes   -> toggle_watch
--
-- plus `reanchor`, `next`/`prev` and `delete_comment`, which have no IDE
-- counterpart: the CLI exposes re-anchoring, and thread-to-thread motion is how
-- a Vim user navigates what the IDE's mouse reaches for.

local composer = require("incomm.ui.composer")
local config = require("incomm.config")
local format = require("incomm.ui.format")
local model = require("incomm.model")
local service = require("incomm.service")
local track = require("incomm.track")
local ui_state = require("incomm.ui.state")

local M = {}

---@param msg string
---@param level? integer
local function notify(msg, level)
  vim.notify("incomm: " .. msg, level or vim.log.levels.INFO)
end

--- Resolve the service and relative path for the current buffer, complaining
--- when the file is outside any project incomm can write notes for.
---@return incomm.Service?, string?, integer?
local function current(quiet)
  local bufnr = vim.api.nvim_get_current_buf()
  local t = track.get(bufnr) or track.attach(bufnr)
  if not t then
    if not quiet then
      notify("this buffer is not a file inside an incomm project", vim.log.levels.WARN)
    end
    return nil
  end
  return t.svc, t.rel, bufnr
end

--- The thread under the cursor, or nil with a message.
---@return incomm.Note?, incomm.Service?, string?
local function note_under_cursor(quiet)
  local note, svc, rel = track.note_at_cursor()
  if not note and not quiet then
    notify("no thread on this line", vim.log.levels.WARN)
  end
  return note, svc, rel
end

-- ---- creating -------------------------------------------------------------

--- Start a thread on the current line, on `line1..line2` when a range was given
--- (`:'<,'>Incomm thread`), or on the visual selection when called straight
--- from a visual-mode mapping.
---@param line1? integer
---@param line2? integer
function M.start_thread(line1, line2)
  local svc, rel, bufnr = current()
  if not svc then
    return
  end
  local s, e
  if line1 then
    s, e = line1, math.max(line1, line2 or line1)
  elseif vim.fn.mode():match("^[vV\22]") then
    -- Called from a visual-mode mapping: take the selection, then leave visual
    -- mode so the composer opens with a normal cursor.
    local anchor_line = vim.fn.getpos("v")[2]
    local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
    s, e = math.min(anchor_line, cursor_line), math.max(anchor_line, cursor_line)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
  else
    s = vim.api.nvim_win_get_cursor(0)[1]
    e = s
  end
  composer.open({
    title = string.format("incomm: new thread on %s%s", s == e and ("L" .. s) or ("L" .. s .. "-" .. e), ""),
    on_submit = function(content)
      -- Positions may have drifted while the composer was open; take them from
      -- the live marks, not from what the model last stored.
      track.flush(bufnr)
      local note = svc:add_note(rel, s, e, content)
      ui_state.set_hidden(note.id, false)
      notify(string.format("thread %s added on %s", note.id, format.range(note)))
    end,
  })
end

--- Reply to the thread under the cursor.
function M.reply()
  local note, svc = note_under_cursor()
  if not note then
    return
  end
  composer.open({
    title = "incomm: reply to " .. format.range(note),
    on_submit = function(content)
      svc:add_reply(note.id, content)
      ui_state.set_hidden(note.id, false)
    end,
  })
end

-- ---- editing --------------------------------------------------------------

--- Every message of a thread, as pickable entries.
---@param note incomm.Note
---@return table[]
local function messages(note)
  local out = {
    {
      label = string.format("%s: %s", format.author(note.author, note.authorTitle), format.preview(note.content, 60)),
      author = note.author,
      content = note.content,
      reply_id = nil,
    },
  }
  for _, reply in ipairs(note.replies) do
    out[#out + 1] = {
      label = string.format("  %s: %s", format.author(reply.author, reply.authorTitle), format.preview(reply.content, 60)),
      author = reply.author,
      content = reply.content,
      reply_id = reply.id,
    }
  end
  return out
end

--- Edit a comment in place. Only `user`-authored messages are editable -- the
--- IDE holds the same line: an agent's words are the agent's.
function M.edit()
  local note, svc = note_under_cursor()
  if not note then
    return
  end
  local editable = vim.tbl_filter(function(m)
    return m.author == model.AUTHOR_USER
  end, messages(note))
  if #editable == 0 then
    notify("nothing of yours to edit in this thread", vim.log.levels.WARN)
    return
  end

  local function do_edit(entry)
    composer.open({
      title = "incomm: edit comment",
      text = entry.content,
      on_submit = function(content)
        if entry.reply_id then
          svc:update_reply(note.id, entry.reply_id, content)
        else
          svc:update_content(note.id, content)
        end
      end,
    })
  end

  if #editable == 1 then
    do_edit(editable[1])
    return
  end
  vim.ui.select(editable, {
    prompt = "incomm: edit which comment?",
    format_item = function(item)
      return item.label
    end,
  }, function(choice)
    if choice then
      do_edit(choice)
    end
  end)
end

--- Delete a single message: the original comment (and with it the thread) or
--- one reply.
function M.delete_comment()
  local note, svc = note_under_cursor()
  if not note then
    return
  end
  local entries = messages(note)
  if #entries == 1 then
    M.delete_thread()
    return
  end
  vim.ui.select(entries, {
    prompt = "incomm: delete which comment?",
    format_item = function(item)
      return item.label
    end,
  }, function(choice)
    if not choice then
      return
    end
    if choice.reply_id then
      svc:remove_reply(note.id, choice.reply_id)
    else
      M.delete_thread()
    end
  end)
end

-- ---- thread state ---------------------------------------------------------

--- Resolve or reopen the thread under the cursor. Resolving also collapses the
--- card, the way the IDE's resolve does.
---@param resolved? boolean explicit state; omit to toggle
function M.resolve(resolved)
  local note, svc = note_under_cursor()
  if not note then
    return
  end
  local target = resolved
  if target == nil then
    target = not note.resolved
  end
  svc:set_resolved(note.id, target)
  if target and config.options.hide_on_resolve then
    ui_state.set_hidden(note.id, true)
  elseif not target then
    ui_state.set_hidden(note.id, false)
  end
  track.redraw_all()
  notify(target and ("resolved " .. format.range(note)) or ("reopened " .. format.range(note)))
end

--- Show/hide the card of the thread under the cursor (the gutter-icon click).
function M.toggle_thread()
  local note = note_under_cursor()
  if not note then
    return
  end
  ui_state.toggle(note.id)
  track.redraw_all()
end

--- Delete the thread under the cursor, replies and all. No confirmation, as in
--- the IDE -- `u` does not bring it back, but the CLI's `add` is one line away.
function M.delete_thread()
  local note, svc = note_under_cursor()
  if not note then
    return
  end
  svc:remove_note(note.id)
  ui_state.set_hidden(note.id, false)
  notify("deleted thread " .. note.id)
end

-- ---- bulk visibility ------------------------------------------------------

--- Show/hide every card. Gutter signs stay: the threads are still there.
function M.toggle_all()
  local notes = {}
  for _, svc in ipairs(service.all()) do
    vim.list_extend(notes, svc:all_notes())
  end
  -- Hiding all means "every id is in the hidden set", not a global gate, so a
  -- single toggle afterwards can still reveal one thread (AGENTS.md §7.6).
  local any_visible = false
  for _, note in ipairs(notes) do
    if not ui_state.is_hidden(note.id) then
      any_visible = true
      break
    end
  end
  for _, note in ipairs(notes) do
    ui_state.set_hidden(note.id, any_visible)
  end
  ui_state.cards_visible = not any_visible
  track.redraw_all()
end

--- Show/hide the cards of resolved threads only.
function M.toggle_resolved()
  local notes = {}
  for _, svc in ipairs(service.all()) do
    vim.list_extend(notes, svc:all_notes())
  end
  local any_visible = false
  for _, note in ipairs(notes) do
    if note.resolved and not ui_state.is_hidden(note.id) then
      any_visible = true
      break
    end
  end
  local touched = 0
  for _, note in ipairs(notes) do
    if note.resolved then
      ui_state.set_hidden(note.id, any_visible)
      touched = touched + 1
    end
  end
  if touched == 0 then
    notify("no resolved threads", vim.log.levels.INFO)
    return
  end
  track.redraw_all()
end

-- ---- clearing -------------------------------------------------------------

---@param prompt string
---@return boolean
local function confirm(prompt)
  return vim.fn.confirm(prompt, "&Yes\n&No", 2) == 1
end

--- Delete every thread anchored to the current file.
function M.clear_file()
  local svc, rel = current()
  if not svc then
    return
  end
  local count = #svc:notes_for_file(rel)
  if count == 0 then
    notify("no threads in this file")
    return
  end
  if not confirm(string.format("incomm: delete %d thread(s) in %s?", count, rel)) then
    return
  end
  svc:remove_notes_for_file(rel)
  notify(string.format("deleted %d thread(s) in %s", count, rel))
end

--- Delete every thread on this branch (removes the notes file).
function M.clear_all()
  local svc = select(1, current(true)) or service.primary()
  local count = #svc:all_notes()
  if count == 0 then
    notify("no threads to clear")
    return
  end
  if not confirm(string.format("incomm: delete ALL %d thread(s) on branch %s?", count, svc.store.raw_branch ~= "" and svc.store.raw_branch or "(no branch)")) then
    return
  end
  svc:clear_all()
  notify(string.format("deleted %d thread(s)", count))
end

-- ---- syncing --------------------------------------------------------------

--- Force-reload the model from disk and redraw everything.
function M.reload()
  for _, svc in ipairs(service.all()) do
    svc:check_branch()
    svc:reload()
  end
  track.attach_all()
  track.refresh_all()
  notify("reloaded")
end

--- Re-anchor every thread against the current file contents -- the editor's
--- `incomm reanchor`. Positions self-heal on their own as you type; this is for
--- files changed outside the editor.
function M.reanchor()
  local changed = false
  for _, svc in ipairs(service.all()) do
    changed = svc:reanchor_from_disk() or changed
  end
  track.refresh_all()
  notify(changed and "re-anchored" or "everything already anchored")
end

--- Turn external-change watching on or off at runtime.
function M.toggle_watch()
  local watch = require("incomm.watch")
  local now = not config.options.watch
  config.options.watch = now
  if now then
    watch.start()
    notify("watching .incomm/ for external changes")
  else
    watch.stop()
    notify("no longer watching for external changes")
  end
end

-- ---- appearance -----------------------------------------------------------

M.MIN_WIDTH = 24

--- Change the inline bubble width. `value` is a number, or "reset" to go back
--- to what the config asked for; `persist` also remembers it for next time.
---
--- Only the cards in the buffer are affected -- the explorer's bubbles size
--- themselves to its pane, which the window already decides.
---@param value string|integer|nil
---@param persist boolean?
function M.set_width(value, persist)
  local card = config.options.card

  if value == nil or value == "" then
    local saved = config.load_width()
    notify(string.format(
      "bubble width %d%s",
      card.width,
      saved and (saved == card.width and " (remembered)" or string.format(" (%d remembered)", saved)) or ""
    ))
    return
  end

  local width
  if value == "reset" then
    width = config.defaults.card.width
    if persist then
      config.save_width(nil)
    end
  else
    width = tonumber(value)
    if not width or width ~= math.floor(width) then
      notify("width must be a whole number of columns", vim.log.levels.WARN)
      return
    end
    width = math.floor(width)
    if width < M.MIN_WIDTH then
      notify("width must be at least " .. M.MIN_WIDTH .. " columns", vim.log.levels.WARN)
      return
    end
    if persist then
      local ok, err = config.save_width(width)
      if not ok then
        notify("could not remember the width: " .. tostring(err), vim.log.levels.WARN)
        persist = false
      end
    end
  end

  card.width = width
  track.redraw_all()
  notify(string.format(
    "bubble width %d%s",
    width,
    persist and " (remembered)" or (value == "reset" and " (config default)" or " (this session)")
  ))
end

-- ---- navigation -----------------------------------------------------------

--- Jump to the next/previous thread in the current file.
---@param dir 1|-1
function M.goto_thread(dir)
  local svc, rel, bufnr = current()
  if not svc then
    return
  end
  local live = track.live_positions(bufnr)
  local cursor = vim.api.nvim_win_get_cursor(0)[1]
  local lines = {}
  for _, note in ipairs(svc:notes_for_file(rel)) do
    local pos = live[note.id]
    local s = note.orphaned and 1 or (pos and pos[1] or note.startLine)
    lines[#lines + 1] = s
  end
  if #lines == 0 then
    notify("no threads in this file")
    return
  end
  table.sort(lines)
  local target
  if dir > 0 then
    for _, l in ipairs(lines) do
      if l > cursor then
        target = l
        break
      end
    end
    target = target or lines[1] -- wrap
  else
    for i = #lines, 1, -1 do
      if lines[i] < cursor then
        target = lines[i]
        break
      end
    end
    target = target or lines[#lines]
  end
  vim.cmd("normal! m'")
  vim.api.nvim_win_set_cursor(0, { math.min(target, vim.api.nvim_buf_line_count(bufnr)), 0 })
  vim.cmd("normal! ^")
end

-- ---- explorer -------------------------------------------------------------

--- The two-pane thread explorer over every thread on this branch.
function M.explorer()
  local svc = select(1, current(true)) or service.primary()
  require("incomm.ui.explorer").open(svc)
end

--- The explorer, limited to the current file.
function M.explorer_file()
  local svc, rel = current()
  if not svc then
    return
  end
  require("incomm.ui.explorer").open(svc, rel)
end

--- Print a short status line: root, branch, notes file, counts.
function M.status()
  local svc = select(1, current(true)) or service.primary()
  local notes = svc:all_notes()
  local open, resolved, orphaned = 0, 0, 0
  for _, note in ipairs(notes) do
    if note.orphaned then
      orphaned = orphaned + 1
    end
    if note.resolved then
      resolved = resolved + 1
    else
      open = open + 1
    end
  end
  local lines = {
    "incomm",
    "  root    " .. svc.store.root,
    "  branch  " .. (svc.store.raw_branch ~= "" and svc.store.raw_branch or "(none, legacy notes.json)"),
    "  file    " .. svc.store:notes_path(),
    string.format("  threads %d (%d open, %d resolved, %d orphaned)", #notes, open, resolved, orphaned),
    "  watch   " .. (config.options.watch and "on" or "off"),
  }
  vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end

return M
