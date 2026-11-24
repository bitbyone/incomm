-- Key hints in a float's footer, lit as aedi.nvim and unagit light theirs: the
-- key in the accent colour, what it does muted, the parts apart by a dim ` · `,
-- all on the background of the border they sit in -- not on a band of their own.
--
--   j/k comment · e edit · esc close
--
-- A hint is a list of { key, what } pairs, or a string in that shape (parts
-- apart by " · ", the key the first word of each).

local M = {}

---@alias incomm.Hint { [1]: string, [2]: string }[]

local function attr(name, field)
  local ok, h = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
  return ok and type(h) == "table" and h[field] or nil
end

local function first(field, ...)
  for _, name in ipairs({ ... }) do
    local v = attr(name, field)
    if v then
      return v
    end
  end
end

--- The groups, from the colours as they are now: cheap, and it follows a
--- colourscheme change without an autocommand. `IncommHintKey`, `IncommHint`
--- and `IncommHintSep` set by a scheme or the user win.
function M.define()
  local bg = first("bg", "FloatBorder", "NormalFloat", "Normal")
  -- the footer's own copy: the base group's colour on the border's background
  local function set(name)
    vim.api.nvim_set_hl(0, name .. "Footer", { fg = attr(name, "fg"), bg = bg, italic = attr(name, "italic") })
  end
  vim.api.nvim_set_hl(0, "IncommHintKey", { default = true, fg = first("fg", "FloatTitle", "Special", "Title") })
  vim.api.nvim_set_hl(0, "IncommHint", { default = true, fg = first("fg", "Comment", "NonText") })
  vim.api.nvim_set_hl(0, "IncommHintSep", { default = true, fg = first("fg", "NonText", "Comment") })
  set("IncommHintKey")
  set("IncommHint")
  set("IncommHintSep")
end

--- `"j/k comment · e edit"` as pairs.
---@param hint incomm.Hint|string
---@return incomm.Hint
function M.parse(hint)
  if type(hint) == "table" then
    return hint
  end
  local out = {}
  for _, part in ipairs(vim.split(hint, " · ", { plain = true })) do
    local key, what = part:match("^%s*(%S+)%s*(.-)%s*$")
    if key then
      out[#out + 1] = { key, what }
    end
  end
  return out
end

--- `{ text, hl }` chunks for a float's `footer`.
---@param hint incomm.Hint|string
---@return { [1]: string, [2]: string }[]
function M.chunks(hint)
  M.define()
  local out = { { " ", "IncommHintFooter" } }
  for i, h in ipairs(M.parse(hint)) do
    if i > 1 then
      out[#out + 1] = { " · ", "IncommHintSepFooter" }
    end
    out[#out + 1] = { h[1], "IncommHintKeyFooter" }
    if h[2] ~= "" then
      out[#out + 1] = { " " .. h[2], "IncommHintFooter" }
    end
  end
  out[#out + 1] = { " ", "IncommHintFooter" }
  return out
end

return M
