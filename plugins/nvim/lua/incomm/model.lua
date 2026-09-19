-- The on-disk types of `.incomm/notes[_<branch>].json` (AGENTS.md §11.2).
--
-- Mirrors `cli/internal/model` and `plugins/intellij/.../model/Notes.kt`. The
-- encoder below is not `vim.json.encode`: it writes the fields in the Go
-- struct order, with Go's two-space indent and Go's HTML escaping, so a file
-- this plugin saves is byte-identical to one the CLI saves. That is not
-- cosmetic -- both writers rewrite the whole file, and a formatting difference
-- would make every alternating write look like a change to watchers, diffs and
-- anyone who does commit `.incomm/`.

local uv = vim.uv or vim.loop

local M = {}

M.SCHEMA_VERSION = 1
M.AUTHOR_USER = "user"
M.AUTHOR_AGENT = "agent"

---@class incomm.Anchor
---@field startPrefix string
---@field endPrefix string
---@field contextBefore string
---@field contextAfter string
---@field checksum string

---@class incomm.Reply
---@field id string
---@field author string
---@field authorTitle? string
---@field content string
---@field createdAt string

---@class incomm.Note
---@field id string
---@field file string project-root-relative, POSIX separators
---@field startLine integer 1-based, inclusive
---@field endLine integer 1-based, inclusive
---@field anchor incomm.Anchor
---@field content string
---@field resolved boolean
---@field orphaned boolean
---@field author string
---@field authorTitle? string
---@field createdAt string
---@field updatedAt string
---@field replies incomm.Reply[]

---@class incomm.NotesFile
---@field version integer
---@field branch? string raw (unsanitized) git branch name
---@field notes incomm.Note[]

--- RFC3339 in UTC, matching Go's `time.RFC3339` output.
---@return string
function M.now_utc()
  return os.date("!%Y-%m-%dT%H:%M:%SZ") --[[@as string]]
end

--- A short, unique-enough hex id: 4 random bytes, like the CLI's `NewID`.
---@return string
function M.new_id()
  local ok, bytes = pcall(uv.random, 4)
  if ok and type(bytes) == "string" and #bytes == 4 then
    return (bytes:gsub(".", function(c)
      return string.format("%02x", c:byte())
    end))
  end
  -- libuv's entropy source should not fail; fall back to something time-based
  -- rather than leaving the caller without an id.
  return string.format("%04x%04x", os.time() % 0x10000, math.random(0, 0xffff))
end

---@return incomm.NotesFile
function M.new_file()
  return { version = M.SCHEMA_VERSION, notes = {} }
end

--- Fill in zero values a hand-edited or legacy file may be missing, so the rest
--- of the plugin never has to nil-check the schema.
---@param f incomm.NotesFile
---@return incomm.NotesFile
function M.normalize(f)
  f.version = f.version or M.SCHEMA_VERSION
  if f.branch == vim.NIL then
    f.branch = nil
  end
  f.notes = f.notes or {}
  for _, note in ipairs(f.notes) do
    note.startLine = note.startLine or 1
    note.endLine = note.endLine or note.startLine
    note.resolved = note.resolved == true
    note.orphaned = note.orphaned == true
    note.content = note.content or ""
    note.author = note.author or M.AUTHOR_USER
    if note.authorTitle == vim.NIL then
      note.authorTitle = nil
    end
    note.createdAt = note.createdAt or M.now_utc()
    note.updatedAt = note.updatedAt or note.createdAt
    note.anchor = note.anchor or {}
    local a = note.anchor
    a.startPrefix = a.startPrefix or ""
    a.endPrefix = a.endPrefix or ""
    a.contextBefore = a.contextBefore or ""
    a.contextAfter = a.contextAfter or ""
    a.checksum = a.checksum or ""
    note.replies = note.replies or {}
    for _, reply in ipairs(note.replies) do
      reply.author = reply.author or M.AUTHOR_AGENT
      reply.content = reply.content or ""
      reply.createdAt = reply.createdAt or note.createdAt
      if reply.authorTitle == vim.NIL then
        reply.authorTitle = nil
      end
    end
  end
  return f
end

---@param f incomm.NotesFile
---@param id string
---@return incomm.Note?
function M.find(f, id)
  for _, note in ipairs(f.notes) do
    if note.id == id then
      return note
    end
  end
  return nil
end

--- Remove a note by id, reporting whether it existed.
---@param f incomm.NotesFile
---@param id string
---@return boolean
function M.remove(f, id)
  for i, note in ipairs(f.notes) do
    if note.id == id then
      table.remove(f.notes, i)
      return true
    end
  end
  return false
end

---@generic T
---@param v T
---@return T
function M.copy(v)
  return vim.deepcopy(v)
end

-- ---------------------------------------------------------------------------
-- JSON encoding (Go-compatible)
-- ---------------------------------------------------------------------------

-- Go's encoding/json escapes these by default, HTML-safely.
local ESCAPES = {
  ['"'] = '\\"',
  ["\\"] = "\\\\",
  ["\n"] = "\\n",
  ["\r"] = "\\r",
  ["\t"] = "\\t",
  ["<"] = "\\u003c",
  [">"] = "\\u003e",
  ["&"] = "\\u0026",
}

---@param s string
---@return string
local function quote(s)
  local out = s:gsub('[%z\1-\31"\\<>&]', function(c)
    return ESCAPES[c] or string.format("\\u%04x", c:byte())
  end)
  -- The two separators Go escapes because they break JavaScript parsers.
  out = out:gsub("\226\128\168", "\\u2028"):gsub("\226\128\169", "\\u2029")
  return '"' .. out .. '"'
end

--- Encode one object as Go would: fixed key order, `indent` spaces per level,
--- `omit` keys skipped when nil or empty.
---@param out string[]
---@param obj table
---@param order string[] key names in Go struct order
---@param omit table<string, boolean> keys with `omitempty`
---@param indent string current indentation
---@param write_value fun(out: string[], key: string, value: any, indent: string)
local function encode_object(out, obj, order, omit, indent, write_value)
  local inner = indent .. "  "
  local parts = {}
  for _, key in ipairs(order) do
    local value = obj[key]
    if not (omit[key] and (value == nil or value == "" or value == vim.NIL)) then
      parts[#parts + 1] = key
    end
  end
  out[#out + 1] = "{\n"
  for i, key in ipairs(parts) do
    out[#out + 1] = inner .. quote(key) .. ": "
    write_value(out, key, obj[key], inner)
    out[#out + 1] = (i < #parts) and ",\n" or "\n"
  end
  out[#out + 1] = indent .. "}"
end

local ANCHOR_ORDER = { "startPrefix", "endPrefix", "contextBefore", "contextAfter", "checksum" }
local REPLY_ORDER = { "id", "author", "authorTitle", "content", "createdAt" }
local NOTE_ORDER = {
  "id",
  "file",
  "startLine",
  "endLine",
  "anchor",
  "content",
  "resolved",
  "orphaned",
  "author",
  "authorTitle",
  "createdAt",
  "updatedAt",
  "replies",
}

---@param out string[]
---@param note incomm.Note
---@param indent string
local function encode_note(out, note, indent)
  encode_object(out, note, NOTE_ORDER, { authorTitle = true }, indent, function(o, key, value, inner)
    if key == "anchor" then
      encode_object(o, value or {}, ANCHOR_ORDER, {}, inner, function(o2, _, v2)
        o2[#o2 + 1] = quote(tostring(v2 or ""))
      end)
    elseif key == "replies" then
      local replies = value or {}
      if #replies == 0 then
        o[#o + 1] = "[]"
      else
        o[#o + 1] = "[\n"
        for i, reply in ipairs(replies) do
          o[#o + 1] = inner .. "  "
          encode_object(o, reply, REPLY_ORDER, { authorTitle = true }, inner .. "  ", function(o2, _, v2)
            o2[#o2 + 1] = quote(tostring(v2 or ""))
          end)
          o[#o + 1] = (i < #replies) and ",\n" or "\n"
        end
        o[#o + 1] = inner .. "]"
      end
    elseif key == "startLine" or key == "endLine" then
      o[#o + 1] = tostring(math.floor(value or 1))
    elseif key == "resolved" or key == "orphaned" then
      o[#o + 1] = value and "true" or "false"
    else
      o[#o + 1] = quote(tostring(value or ""))
    end
  end)
end

--- Serialize a notes file the way `json.MarshalIndent(f, "", "  ")` plus a
--- trailing newline does in the CLI.
---@param f incomm.NotesFile
---@return string
function M.encode(f)
  local out = {}
  encode_object(out, f, { "version", "branch", "notes" }, { branch = true }, "", function(o, key, value, inner)
    if key == "version" then
      o[#o + 1] = tostring(math.floor(value or M.SCHEMA_VERSION))
    elseif key == "branch" then
      o[#o + 1] = quote(tostring(value))
    else
      local notes = value or {}
      if #notes == 0 then
        o[#o + 1] = "[]"
      else
        o[#o + 1] = "[\n"
        for i, note in ipairs(notes) do
          o[#o + 1] = inner .. "  "
          encode_note(o, note, inner .. "  ")
          o[#o + 1] = (i < #notes) and ",\n" or "\n"
        end
        o[#o + 1] = inner .. "]"
      end
    end
  end)
  out[#out + 1] = "\n"
  return table.concat(out)
end

--- Parse a notes file. Returns an empty model for empty/corrupt input rather
--- than throwing: a half-written file must never take the UI down.
---@param text string
---@return incomm.NotesFile?, string? error
function M.decode(text)
  if vim.trim(text) == "" then
    return M.new_file()
  end
  local ok, decoded = pcall(vim.json.decode, text, { luanil = { object = true, array = true } })
  if not ok or type(decoded) ~= "table" then
    return nil, tostring(decoded)
  end
  return M.normalize(decoded --[[@as incomm.NotesFile]])
end

return M
