-- Changing who may see a comment.
--
-- The audience belongs to each comment, but the cursor and the explorer's
-- selection belong to a thread. So the flow picks the comment first -- skipped
-- when the thread has only one -- and then moves it one step along
-- agent -> agent + external -> external -> private, or straight to a named
-- audience when one is given. The same flow serves `:Incomm audience` and the
-- explorer's `a`.

local format = require("incomm.ui.format")
local model = require("incomm.model")

local M = {}

--- An audience as a person reads it.
---@param audience string
---@return string
function M.label(audience)
  return audience == model.AUDIENCE_BOTH and "agent + external" or audience
end

--- The comments of a thread as pickable entries, the thread's own first.
---@param note incomm.Note
---@return table[]
function M.entries(note)
  local function entry(comment, reply_id, indent)
    local effective = model.effective_audience(note, comment)
    return {
      reply_id = reply_id,
      audience = model.normalize_audience(comment.audience),
      effective = effective,
      label = string.format(
        "%s%s: %s  [%s]",
        indent,
        format.author(comment.author, comment.authorTitle),
        format.preview(comment.content, 50),
        M.label(effective)
      ),
    }
  end

  local out = { entry(note, nil, "") }
  for _, reply in ipairs(note.replies) do
    out[#out + 1] = entry(reply, reply.id, "  ")
  end
  return out
end

--- Move one comment, or the whole thread, to an audience.
---@param svc incomm.Service
---@param note incomm.Note
---@param choice table an entry from `entries`, or `{ whole = true }`
---@param target string? a named audience; nil steps the cycle
---@return string audience what was applied
local function apply(svc, note, choice, target)
  if choice.whole then
    -- One step from the thread's own audience, applied to every comment, so a
    -- thread does not end up with each message on a different step.
    local audience = target or model.next_audience(note.audience)
    svc:set_thread_audience(note.id, audience)
    return audience
  end
  local audience = target or model.next_audience(choice.audience)
  svc:set_audience(note.id, choice.reply_id, audience)
  return audience
end

--- Run the flow on `note`.
---@param svc incomm.Service
---@param note incomm.Note
---@param target? string a named audience instead of the next step
function M.change(svc, note, target)
  if not svc:check_writable() then
    return
  end
  if target and model.normalize_audience(target) ~= target then
    vim.notify(
      "incomm: audience must be one of " .. table.concat(model.AUDIENCE_CYCLE, ", "),
      vim.log.levels.ERROR
    )
    return
  end

  local entries = M.entries(note)
  local function done(choice)
    local audience = apply(svc, note, choice, target)
    vim.notify("incomm: " .. (choice.whole and "whole thread" or "comment") .. " is now " .. M.label(audience))
  end

  if #entries == 1 then
    done(entries[1])
    return
  end
  local choices = vim.list_extend(vim.list_slice(entries), { { whole = true, label = "whole thread" } })
  vim.ui.select(choices, {
    prompt = "incomm: change the audience of which comment?",
    format_item = function(item)
      return item.label
    end,
  }, function(choice)
    if choice then
      done(choice)
    end
  end)
end

return M
