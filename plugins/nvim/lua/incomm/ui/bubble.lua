-- One message, drawn as a bordered bubble.
--
-- Both places that render a thread use this: the inline card hangs the rows off
-- an extmark as `virt_lines`, and the explorer's detail pane writes them into a
-- buffer. Keeping one builder means a reply looks the same wherever it is read,
-- and the box is what separates it from the comment above it.
--
-- Nothing inside a bubble is filled. A `virt_lines` background stops at the end
-- of the text it is drawn on and cannot be made to meet the border's own cell,
-- so a filled bubble always showed a seam along its right edge. The border
-- carries the author's colour instead, which is all the fill was ever for.
--
-- A row is a list of `{ text, highlight }` chunks, which is the shape
-- `virt_lines` wants; `to_lines` flattens rows into buffer lines plus the byte
-- ranges to highlight for the buffer case.

local format = require("incomm.ui.format")
local hl = require("incomm.ui.highlights")
local model = require("incomm.model")

local M = {}

--- Border glyph sets: top-left, top, top-right, right, bottom-right, bottom,
--- bottom-left, left.
M.borders = {
  rounded = { "╭", "─", "╮", "│", "╯", "─", "╰", "│" },
  single = { "┌", "─", "┐", "│", "┘", "─", "└", "│" },
  double = { "╔", "═", "╗", "║", "╝", "═", "╚", "║" },
  solid = { "▛", "▀", "▜", "▐", "▟", "▄", "▙", "▌" },
}

---@param spec string|string[]
---@return string[]
function M.border_chars(spec)
  if type(spec) == "table" then
    return spec
  end
  return M.borders[spec] or M.borders.rounded
end

---@class incomm.BubbleOpts
---@field author string
---@field title string?
---@field created string
---@field content string
---@field width integer total width of the box, borders included
---@field indent integer? leading spaces (replies are nested)
---@field border string|string[]|false
---@field audience string? the comment's EFFECTIVE audience; plain agent is drawn too, dimmer than the rest
---@field published boolean? whether the comment records where it went on the forge

---@param chunks table[]
---@return integer
local function chunks_width(chunks)
  local total = 0
  for _, chunk in ipairs(chunks) do
    total = total + vim.fn.strdisplaywidth(chunk[1])
  end
  return total
end

--- The audience label that trails the author and time in a bubble's header, as
--- chunks, plus the display width they take. It lives in the header line that
--- is already there, so a bubble is never taller for having one, and it gives
--- way when the line is short of room: the state word goes first, then "agent +"
--- shrinks to "+", then the whole badge. Plain agent is the default, so it is
--- drawn dimmer than the states that ask for something.
---@param audience string? effective audience
---@param published boolean? whether it has a source
---@param room integer display cells left on the header line
---@return table[] chunks, integer used
function M.badge(audience, published, room)
  local a = model.normalize_audience(audience)
  local candidates
  if a == model.AUDIENCE_AGENT then
    candidates = { { { "  agent", "IncommBadgeAgent" } } }
  elseif a == model.AUDIENCE_PRIVATE then
    candidates = { { { "  private", "IncommBadgePrivate" } } }
  else
    local label = a == model.AUDIENCE_BOTH and "agent + external" or a
    local word = published and "published" or "not published"
    local word_hl = published and "IncommBadgePublished" or "IncommBadgePending"
    candidates = {
      { { "  " .. label, "IncommBadge" }, { " · " .. word, word_hl } },
      { { "  " .. label, "IncommBadge" } },
    }
    if a == model.AUDIENCE_BOTH then
      candidates[#candidates + 1] = { { "  +external", "IncommBadge" } }
    end
  end
  for _, chunks in ipairs(candidates) do
    local width = chunks_width(chunks)
    if width <= room then
      return chunks, width
    end
  end
  return {}, 0
end

--- Build one bubble.
---@param opts incomm.BubbleOpts
---@return table[][] rows
function M.build(opts)
  local suffix = hl.author_suffix(opts.author)
  local border_hl = "IncommBorder" .. suffix
  local indent = opts.indent or 0
  local width = math.max(opts.width, 16)
  local inner = width - 2 -- what sits between the two border columns
  local rows = {}

  -- Unhighlighted, so the gap to the left of a nested reply is just the buffer.
  local pad = indent > 0 and { { string.rep(" ", indent) } } or nil

  ---@param chunks table[]
  local function row(chunks)
    local out = {}
    if pad then
      vim.list_extend(out, vim.deepcopy(pad))
    end
    vim.list_extend(out, chunks)
    rows[#rows + 1] = out
  end

  local b = opts.border ~= false and M.border_chars(opts.border) or nil

  if b then
    row({ { b[1] .. string.rep(b[2], inner) .. b[3], border_hl } })
  end

  --- A content line inside the box, padded to the inner width.
  ---@param chunks table[] the line's own chunks, already measured by `used`
  ---@param used integer display width of those chunks
  local function boxed(chunks, used)
    local line = {}
    if b then
      line[#line + 1] = { b[8], border_hl }
    end
    line[#line + 1] = { " " }
    vim.list_extend(line, chunks)
    local rest = inner - used - 2
    if rest > 0 then
      line[#line + 1] = { string.rep(" ", rest) }
    end
    line[#line + 1] = { " " }
    if b then
      line[#line + 1] = { b[4], border_hl }
    end
    row(line)
  end

  -- Author and time, then who may see it.
  local name = format.author(opts.author, opts.title)
  local when = format.time(opts.created)
  local header = {
    { name, "IncommName" .. suffix },
    { "  " .. when, "IncommTime" .. suffix },
  }
  local used = vim.fn.strdisplaywidth(name) + 2 + vim.fn.strdisplaywidth(when)
  -- The audience floats to the right edge: name and time on the left, its state
  -- against the border. The badge's own two leading spaces are the least gap it
  -- keeps from the time; the rest of the line is the gap.
  local badge, badge_width = M.badge(opts.audience, opts.published, inner - 2 - used)
  if badge_width > 0 then
    local right = vim.deepcopy(badge)
    right[1][1] = right[1][1]:gsub("^%s+", "")
    local right_width = chunks_width(right)
    header[#header + 1] = { string.rep(" ", inner - 2 - used - right_width) }
    vim.list_extend(header, right)
    boxed(header, inner - 2)
  else
    boxed(header, used)
  end

  -- Body, wrapped to the inner width.
  for _, text in ipairs(format.wrap(opts.content, inner - 2)) do
    boxed({ { text, "IncommText" .. suffix } }, vim.fn.strdisplaywidth(text))
  end

  if b then
    row({ { b[7] .. string.rep(b[6], inner) .. b[5], border_hl } })
  end

  return rows
end

--- Flatten rows into buffer lines plus the highlight ranges to apply.
---@param rows table[][]
---@param offset integer? 0-based buffer row the first line lands on
---@return string[] lines, { row: integer, col: integer, end_col: integer, hl: string }[]
function M.to_lines(rows, offset)
  offset = offset or 0
  local lines, highlights = {}, {}
  for i, row in ipairs(rows) do
    local text, col = {}, 0
    for _, chunk in ipairs(row) do
      local piece = chunk[1]
      text[#text + 1] = piece
      if chunk[2] and piece ~= "" then
        highlights[#highlights + 1] = {
          row = offset + i - 1,
          col = col,
          end_col = col + #piece,
          hl = chunk[2],
        }
      end
      col = col + #piece
    end
    lines[#lines + 1] = table.concat(text)
  end
  return lines, highlights
end

--- Apply the ranges produced by `to_lines` to a buffer.
---@param bufnr integer
---@param ns integer
---@param highlights table[]
function M.apply(bufnr, ns, highlights)
  for _, h in ipairs(highlights) do
    pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, h.row, h.col, {
      end_col = h.end_col,
      hl_group = h.hl,
      hl_mode = "combine",
    })
  end
end

return M
