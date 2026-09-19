-- Text shaping shared by the cards, the explorer and the notifications.

local config = require("incomm.config")

local M = {}

--- Parse an RFC3339 UTC timestamp into an epoch, or nil.
---@param ts string?
---@return integer?
function M.parse_time(ts)
  if type(ts) ~= "string" then
    return nil
  end
  local y, mo, d, h, mi, s = ts:match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
  if not y then
    return nil
  end
  -- os.time interprets the table as local time, so convert through the offset
  -- between the two readings of "now" rather than guessing the zone.
  local utc = os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(d), hour = tonumber(h), min = tonumber(mi), sec = tonumber(s), isdst = false })
  local now = os.time()
  local offset = os.difftime(now, os.time(os.date("!*t", now) --[[@as osdateparam]]))
  return utc + offset
end

--- Render a timestamp per `date_format`.
---@param ts string?
---@return string
function M.time(ts)
  local epoch = M.parse_time(ts)
  if not epoch then
    return ts or ""
  end
  local style = config.options.date_format
  if style == "relative" then
    local delta = os.difftime(os.time(), epoch)
    if delta < 60 then
      return "just now"
    elseif delta < 3600 then
      return string.format("%dm ago", math.floor(delta / 60))
    elseif delta < 86400 then
      return string.format("%dh ago", math.floor(delta / 3600))
    elseif delta < 7 * 86400 then
      return string.format("%dd ago", math.floor(delta / 86400))
    end
    return os.date("%d %b", epoch) --[[@as string]]
  elseif style == "datetime" then
    return os.date("%Y-%m-%d %H:%M", epoch) --[[@as string]]
  elseif style == "date" then
    return os.date("%Y-%m-%d", epoch) --[[@as string]]
  elseif style == "time" then
    return os.date("%H:%M", epoch) --[[@as string]]
  end
  return os.date(style, epoch) --[[@as string]]
end

--- The display name for a comment's author, per the shared convention: a user
--- comment shows its title, an agent comment shows "Agent" or "Agent (title)".
---@param author string
---@param title string?
---@return string
function M.author(author, title)
  if author == "agent" then
    return title and title ~= "" and ("Agent (" .. title .. ")") or "Agent"
  end
  return (title and title ~= "") and title or "User"
end

--- `L42` or `L42-48`.
---@param note incomm.Note
---@return string
function M.range(note)
  if note.endLine ~= note.startLine then
    return string.format("L%d-%d", note.startLine, note.endLine)
  end
  return "L" .. note.startLine
end

---@param note incomm.Note
---@return string
function M.state(note)
  if note.orphaned then
    return "orphaned"
  elseif note.resolved then
    return "resolved"
  end
  return "open"
end

--- Wrap `text` to `width` display cells, breaking on whitespace where possible
--- and honouring the newlines the author typed.
---@param text string
---@param width integer
---@return string[]
function M.wrap(text, width)
  width = math.max(width, 20)
  local out = {}
  for _, paragraph in ipairs(vim.split(text or "", "\n", { plain = true })) do
    if paragraph == "" then
      out[#out + 1] = ""
    else
      local line = ""
      for word in paragraph:gmatch("%S+") do
        local candidate = line == "" and word or (line .. " " .. word)
        if vim.fn.strdisplaywidth(candidate) <= width then
          line = candidate
        else
          if line ~= "" then
            out[#out + 1] = line
          end
          -- A single word longer than the line gets hard-broken rather than
          -- pushing the card past the window edge.
          while vim.fn.strdisplaywidth(word) > width do
            local cut = width
            while cut > 1 and vim.fn.strdisplaywidth(vim.fn.strcharpart(word, 0, cut)) > width do
              cut = cut - 1
            end
            out[#out + 1] = vim.fn.strcharpart(word, 0, cut)
            word = vim.fn.strcharpart(word, cut)
          end
          line = word
        end
      end
      if line ~= "" then
        out[#out + 1] = line
      end
    end
  end
  if #out == 0 then
    out[1] = ""
  end
  return out
end

--- One-line preview of a comment, for the explorer and notifications.
---@param text string
---@param max? integer
---@return string
function M.preview(text, max)
  max = max or 80
  local flat = vim.trim((text or ""):gsub("%s+", " "))
  if vim.fn.strchars(flat) > max then
    return vim.fn.strcharpart(flat, 0, max - 1) .. "…"
  end
  return flat
end

return M
