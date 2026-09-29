-- Thread details: every comment of one thread, and what can be done to each.
--
-- `:Incomm list` (and the explorer's `a`) opens the comment dialog
-- (`ui/comments.lua`) with three things to do to the selected comment:
--
--   h / l    step who may see it (see `ui/audience.lua`), saved at once
--   e        edit it in the composer; the dialog comes back afterwards
--   d        delete it -- the thread's own comment takes the thread with it
--
-- What is on the merge request already (it has a `source`) is neither edited
-- nor deleted here, and only flips between agent + external and external.

local audience = require("incomm.ui.audience")
local comments = require("incomm.ui.comments")
local composer = require("incomm.ui.composer")
local format = require("incomm.ui.format")
local model = require("incomm.model")
local ui_state = require("incomm.ui.state")

local M = {}

local function warn(msg)
  vim.notify("incomm: " .. msg, vim.log.levels.WARN)
end

--- The dialog on screen, if any (tests).
function M.current()
  return comments.current()
end

--- Open thread details for `note`.
---@param svc incomm.Service
---@param note incomm.Note
---@param opts? { index?: integer, anchor?: "cursor"|"center" } where the selection starts, where the composer opens
---@return table? the dialog
function M.open(svc, note, opts)
  opts = opts or {}
  if not svc:check_writable() then
    return nil
  end

  local function step(forward)
    return function(self, row)
      -- Only through what this comment may be: a published one flips between
      -- agent + external and external.
      local target = forward and model.next_audience(row.audience, row.cycle)
        or model.prev_audience(row.audience, row.cycle)
      -- The change notification redraws too; drawing here keeps the dialog
      -- right even when the write is refused and nothing is published.
      svc:set_audience(self.note_id, row.reply_id, target)
      comments.draw(self)
    end
  end

  local function edit(self, row)
    if not row.editable then
      warn("cannot edit this comment: " .. row.not_editable)
      return
    end
    local index = self.index
    comments.close(self)
    -- Back to the same comment afterwards, saved or not: the dialog is where the
    -- work on this thread is being done.
    local function reopen()
      local fresh = svc:find(note.id)
      if fresh then
        M.open(svc, fresh, { index = index, anchor = opts.anchor })
      end
    end
    composer.open({
      title = "incomm: edit comment",
      text = row.content,
      anchor = "center",
      on_submit = function(content)
        if row.reply_id then
          svc:update_reply(note.id, row.reply_id, content)
        else
          svc:update_content(note.id, content)
        end
        vim.schedule(reopen)
      end,
      on_cancel = function()
        vim.schedule(reopen)
      end,
    })
  end

  local function delete(self, row)
    if not row.deletable then
      warn("cannot delete this comment: " .. row.not_deletable)
      return
    end
    if row.reply_id then
      svc:remove_reply(self.note_id, row.reply_id)
      comments.draw(self)
    else
      -- The thread's own comment is the thread: it goes, and the dialog with it.
      svc:remove_note(self.note_id)
      ui_state.set_hidden(self.note_id, false)
      comments.close(self)
      vim.notify("incomm: deleted thread " .. self.note_id)
    end
  end

  local on, back = step(true), step(false)
  local dialog = comments.open({
    svc = svc,
    note = note,
    title = "thread details  " .. format.range(note),
    footer = "j/k comment · h/l audience · e edit · d delete · esc close",
    right = audience.cell,
    keys = {
      l = on,
      ["<Right>"] = on,
      ["<Space>"] = on,
      h = back,
      ["<Left>"] = back,
      e = edit,
      d = delete,
      ["<Del>"] = delete,
    },
  })
  if dialog and opts.index then
    dialog.index = opts.index
    comments.draw(dialog)
  end
  return dialog
end

return M
