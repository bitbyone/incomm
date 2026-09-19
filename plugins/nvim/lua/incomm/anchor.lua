-- The shared, deterministic line-anchoring algorithm (AGENTS.md §11.4).
--
-- This is a line-by-line port of `cli/internal/anchor/anchor.go`, which
-- `plugins/intellij/.../anchor/Anchoring.kt` also mirrors. All three are
-- exercised by the same `fixtures/anchor/cases.json`, so any change here has to
-- land in the other two as well -- the spec calls schema and anchoring parity
-- sacred, and it is: the CLI re-anchors on `list`, this plugin re-anchors as you
-- type, and a note that lands on different lines in the two is a note the human
-- and the agent are no longer talking about the same code through.

local sha1 = require("incomm.sha1")

local M = {}

-- Tunables -- MUST match the spec, the Go implementation and the Kotlin one.
M.PREFIX_LEN = 64 -- max chars kept for start/end prefixes
M.CONTEXT_PREFIX_LEN = 48 -- max chars kept for context-before/after
M.SEARCH_RADIUS = 400 -- max lines to search away from the last known line
M.MIN_PREFIX_MATCH = 4 -- min non-whitespace chars required to attempt a match

--- Trim leading/trailing ASCII whitespace only.
---
--- ASCII-only on purpose: Go's `strings.Trim(s, " \t\n\r\f\v")` and Kotlin's
--- equivalent both stop there, and a Unicode-aware trim would quietly disagree
--- with them on lines that start with a non-breaking space.
---@param s string
---@return string
local function trim_ws(s)
  return (s:gsub("^[ \t\n\r\f\v]+", ""):gsub("[ \t\n\r\f\v]+$", ""))
end

--- First `maxlen` Unicode code points of `s`.
---
--- Go slices `[]rune`, so the cap counts characters, not bytes. Counting them
--- by hand beats `vim.fn.strcharpart` here: this runs inside the scoring loop
--- for every candidate line, and it must work outside the main loop too (the
--- test harness calls it with no editor around).
---@param s string
---@param maxlen integer
---@return string
local function char_prefix(s, maxlen)
  if #s <= maxlen then
    return s -- a byte can never hold more than one code point
  end
  local i, n, len = 1, 0, #s
  while i <= len do
    if n == maxlen then
      return s:sub(1, i - 1)
    end
    local b = s:byte(i)
    local size
    if b < 0x80 then
      size = 1
    elseif b < 0xC0 then
      size = 1 -- stray continuation byte: one replacement rune, as in Go
    elseif b < 0xE0 then
      size = 2
    elseif b < 0xF0 then
      size = 3
    else
      size = 4
    end
    i = i + size
    n = n + 1
  end
  return s
end

--- A line's stored anchor text: trimmed, then capped at `maxlen` code points.
---@param line string
---@param maxlen integer
---@return string
function M.trimmed_prefix(line, maxlen)
  return char_prefix(trim_ws(line), maxlen)
end

--- Count non-whitespace code points (cheap proxy: bytes outside the ASCII
--- whitespace set, which is what Go counts runes of).
---@param s string
---@return integer
local function non_ws_count(s)
  local n = 0
  for i = 1, #s do
    local b = s:byte(i)
    if b ~= 0x20 and b ~= 0x09 and b ~= 0x0A and b ~= 0x0D and b ~= 0x0C and b ~= 0x0B then
      -- Continuation bytes (0x80-0xBF) are not rune starts; skip them so a
      -- multi-byte character counts once, exactly like Go's `range` loop.
      if b < 0x80 or b >= 0xC0 then
        n = n + 1
      end
    end
  end
  return n
end

---@param v integer
---@param lo integer
---@param hi integer
---@return integer
local function clamp(v, lo, hi)
  if v < lo then
    return lo
  end
  if v > hi then
    return hi
  end
  return v
end

--- `sha1:<hex>` of the 1-based inclusive line block [start,end], joined by \n.
--- Out-of-range requests are clamped, mirroring the Go version.
---@param lines string[]
---@param start_line integer
---@param end_line integer
---@return string
function M.checksum(lines, start_line, end_line)
  local n = #lines
  if n == 0 then
    return ""
  end
  local s = clamp(start_line, 1, n)
  local e = clamp(end_line, 1, n)
  if e < s then
    e = s
  end
  local block = table.concat(lines, "\n", s, e)
  return "sha1:" .. sha1.hex(block)
end

--- Build an anchor for a note occupying 1-based inclusive [start_line, end_line].
---@param lines string[]
---@param start_line integer
---@param end_line integer
---@return incomm.Anchor
function M.compute(lines, start_line, end_line)
  local n = #lines
  local s = clamp(start_line, 1, math.max(n, 1))
  local e = clamp(end_line, s, math.max(n, 1))

  local start_prefix, end_prefix, before, after = "", "", "", ""
  if n > 0 then
    start_prefix = M.trimmed_prefix(lines[s], M.PREFIX_LEN)
    end_prefix = M.trimmed_prefix(lines[e], M.PREFIX_LEN)
    if s - 1 >= 1 then
      before = M.trimmed_prefix(lines[s - 1], M.CONTEXT_PREFIX_LEN)
    end
    if e < n then
      after = M.trimmed_prefix(lines[e + 1], M.CONTEXT_PREFIX_LEN)
    end
  end

  return {
    startPrefix = start_prefix,
    endPrefix = end_prefix,
    contextBefore = before,
    contextAfter = after,
    checksum = M.checksum(lines, s, e),
  }
end

--- Do the stored context lines (if any) still sit around this 1-based block?
--- Empty context always matches.
---@param lines string[]
---@param start_line integer
---@param end_line integer
---@param a incomm.Anchor
---@return boolean
local function context_matches(lines, start_line, end_line, a)
  if a.contextBefore ~= "" then
    if start_line - 1 < 1 or M.trimmed_prefix(lines[start_line - 1], M.CONTEXT_PREFIX_LEN) ~= a.contextBefore then
      return false
    end
  end
  if a.contextAfter ~= "" then
    if end_line + 1 > #lines or M.trimmed_prefix(lines[end_line + 1], M.CONTEXT_PREFIX_LEN) ~= a.contextAfter then
      return false
    end
  end
  return true
end

---@param a incomm.Anchor
---@param b incomm.Anchor
---@return boolean
function M.anchor_equal(a, b)
  return a.startPrefix == b.startPrefix
    and a.endPrefix == b.endPrefix
    and a.contextBefore == b.contextBefore
    and a.contextAfter == b.contextAfter
    and a.checksum == b.checksum
end

--- Recompute `note.startLine`/`endLine` against the file's current lines,
--- refreshing `note.anchor` and `note.orphaned` in place.
---@param note incomm.Note
---@param lines string[]
local function apply(note, lines)
  local total = #lines
  local line_span = math.max(note.endLine - note.startLine, 0)
  local anchor = note.anchor

  -- 1. Fast path -- still where we left it (prefixes AND any stored context match).
  if
    note.startLine >= 1
    and note.endLine >= 1
    and note.endLine <= total
    and M.trimmed_prefix(lines[note.startLine], M.PREFIX_LEN) == anchor.startPrefix
    and M.trimmed_prefix(lines[note.endLine], M.PREFIX_LEN) == anchor.endPrefix
    and context_matches(lines, note.startLine, note.endLine, anchor)
  then
    note.orphaned = false
    return
  end

  -- 2. Too weak to anchor -> give up.
  if non_ws_count(anchor.startPrefix) < M.MIN_PREFIX_MATCH then
    note.orphaned = true
    return
  end

  -- 3. Search + score candidates. Indices are 0-based here to keep the distance
  --    arithmetic identical to the Go original; +1 converts back at the end.
  local old_idx = note.startLine - 1
  local best_idx, best_score, best_dist = -1, 0, 0
  for i = 0, total - 1 do
    local dist = math.abs(i - old_idx)
    if dist <= M.SEARCH_RADIUS then
      local cand = M.trimmed_prefix(lines[i + 1], M.PREFIX_LEN)
      if cand:sub(1, #anchor.startPrefix) == anchor.startPrefix then
        local score = 100
        if cand == anchor.startPrefix then
          score = score + 60 -- exact prefix, not merely a longer line starting with it
        end
        if
          anchor.contextBefore ~= ""
          and i - 1 >= 0
          and M.trimmed_prefix(lines[i], M.CONTEXT_PREFIX_LEN) == anchor.contextBefore
        then
          score = score + 40
        end
        if
          anchor.contextAfter ~= ""
          and i + line_span + 1 < total
          and M.trimmed_prefix(lines[i + line_span + 2], M.CONTEXT_PREFIX_LEN) == anchor.contextAfter
        then
          score = score + 40
        end
        if anchor.checksum ~= "" and M.checksum(lines, i + 1, i + 1 + line_span) == anchor.checksum then
          score = score + 80 -- strongest signal: the block is byte-identical
        end
        score = score - dist

        -- Higher score wins; tie -> smaller distance -> smaller index (the loop
        -- ascends, so a later equal candidate never displaces an earlier one).
        if best_idx == -1 or score > best_score or (score == best_score and dist < best_dist) then
          best_idx, best_score, best_dist = i, score, dist
        end
      end
    end
  end

  -- 4. Accept or give up.
  if best_idx == -1 or best_score < 100 then
    note.orphaned = true
    return
  end
  local new_start = best_idx + 1
  local new_end = clamp(new_start + line_span, new_start, total)
  note.startLine = new_start
  note.endLine = new_end
  note.anchor = M.compute(lines, new_start, new_end)
  note.orphaned = false
end

--- Re-anchor `note` against `lines`, reporting whether anything changed.
---@param note incomm.Note mutated in place
---@param lines string[]
---@return boolean changed
function M.reanchor(note, lines)
  local before_start, before_end = note.startLine, note.endLine
  local before_orphaned, before_anchor = note.orphaned, note.anchor
  apply(note, lines)
  return note.startLine ~= before_start
    or note.endLine ~= before_end
    or note.orphaned ~= before_orphaned
    or not M.anchor_equal(note.anchor, before_anchor)
end

--- Split text into lines the way the store does: CRLF/CR normalised to LF, and
--- a single trailing newline dropped so counts match editor line numbers.
---@param text string
---@return string[]
function M.split_lines(text)
  text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
  if text == "" then
    return {}
  end
  if text:sub(-1) == "\n" then
    text = text:sub(1, -2)
  end
  return vim.split(text, "\n", { plain = true })
end

return M
