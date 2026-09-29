-- Changing who may see a comment.
--
-- The audience belongs to each comment, but the cursor and the explorer's
-- selection belong to a thread. So the thread details dialog (`ui/thread.lua`,
-- `:Incomm list`) shows each comment's audience on the right between two arrows,
-- drawn by `cell` here, and h/l step it back and forth along agent -> agent +
-- external -> external -> private; every step is written straight away.
--
-- A comment on the forge (one with a `source`) only flips between agent +
-- external and external, and a thread with such a reply is never private: see
-- `model.audience_cycle`.
--
-- A new thread can start with any audience: `:Incomm thread private`.

local comments = require("incomm.ui.comments")
local config = require("incomm.config")
local model = require("incomm.model")

local M = {}

--- An audience as a person reads it.
---@param audience string
---@return string
function M.label(audience)
  return audience == model.AUDIENCE_BOTH and "agent + external" or audience
end

--- The comments of a thread as dialog rows (see `comments.rows`).
M.rows = comments.rows

--- The widest audience label, so the arrows never move.
local LABEL_W = 0
for _, a in ipairs(model.AUDIENCE_CYCLE) do
  LABEL_W = math.max(LABEL_W, vim.fn.strdisplaywidth(M.label(a)))
end

---@param row table
---@return string
local function audience_hl(row)
  if row.inherited then
    return "IncommMuted"
  end
  if row.audience == model.AUDIENCE_PRIVATE then
    return "IncommBadgePrivate"
  end
  if model.includes_external(row.audience) then
    return row.published and "IncommBadgePublished" or "IncommBadgePending"
  end
  return "IncommBadge"
end

--- `◀ audience ▶` for the right of a row, the label centred between the arrows.
---@param row table
---@return table[] chunks, integer width
function M.cell(row)
  local arrows = config.options.audience.arrows
  local label = M.label(row.audience)
  local gap = LABEL_W - vim.fn.strdisplaywidth(label)
  local before = math.floor(gap / 2)
  local chunks = {
    { arrows[1], "IncommMuted" },
    { string.rep(" ", before + 1) },
    { label, audience_hl(row) },
    { string.rep(" ", gap - before + 1) },
    { arrows[2], "IncommMuted" },
  }
  return chunks, LABEL_W + 2 + vim.fn.strdisplaywidth(arrows[1]) + vim.fn.strdisplaywidth(arrows[2])
end

return M
