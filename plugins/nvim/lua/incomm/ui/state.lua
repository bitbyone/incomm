-- View state: which cards are collapsed.
--
-- `hidden` is the single source of truth for "this card is hidden", exactly as
-- `hiddenNotes` is in the IntelliJ tracker (AGENTS.md §7.6). Hiding everything
-- is implemented by putting every id in the set rather than by an absolute
-- gate, so toggling one thread afterwards can still reveal it.

local M = {}

---@type table<string, boolean>
M.hidden = {}

--- The "show/hide all" intent, flipped by the toggle-all action.
M.cards_visible = true

---@param id string
---@return boolean
function M.is_hidden(id)
  return M.hidden[id] == true
end

---@param id string
---@param hidden boolean
function M.set_hidden(id, hidden)
  M.hidden[id] = hidden or nil
end

---@param id string
---@return boolean now_hidden
function M.toggle(id)
  local now = not M.is_hidden(id)
  M.set_hidden(id, now)
  return now
end

--- Ids whose initial visibility has already been decided, so the `hide_resolved`
--- default is applied once per thread and never fights a later manual toggle.
---@type table<string, boolean>
M.defaulted = {}

--- Apply the configured initial visibility to threads seen for the first time.
---@param notes incomm.Note[]
function M.apply_defaults(notes)
  if not require("incomm.config").options.hide_resolved then
    return
  end
  for _, note in ipairs(notes) do
    if not M.defaulted[note.id] then
      M.defaulted[note.id] = true
      if note.resolved then
        M.set_hidden(note.id, true)
      end
    end
  end
end

--- Drop state for notes that no longer exist, so the set cannot grow forever.
---@param notes incomm.Note[]
function M.prune(notes)
  local live = {}
  for _, note in ipairs(notes) do
    live[note.id] = true
  end
  for id in pairs(M.hidden) do
    if not live[id] then
      M.hidden[id] = nil
    end
  end
  for id in pairs(M.defaulted) do
    if not live[id] then
      M.defaulted[id] = nil
    end
  end
end

function M.reset()
  M.hidden = {}
  M.defaulted = {}
  M.cards_visible = true
end

return M
