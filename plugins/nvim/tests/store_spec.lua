-- Store and schema parity with the CLI.
--
-- These tests shell out to the real `incomm` binary when it is on $PATH: the
-- point is not that this plugin round-trips its own output (it would), but that
-- what it writes is byte-identical to what the Go CLI writes, and that both
-- resolve the same root, branch and filename.

local T = _G.T
local store = require("incomm.store")
local model = require("incomm.model")

local has_cli = vim.fn.executable("incomm") == 1

--- A throwaway git repo with one source file, on branch `branch`.
---@param dir string
---@param branch string
local function make_repo(dir, branch)
  vim.fn.mkdir(dir .. "/src", "p")
  vim.fn.writefile({ "package main", "", "func main() {", '\tprintln("hi")', "}" }, dir .. "/src/main.go")
  vim.fn.mkdir(dir .. "/.git", "p")
  vim.fn.writefile({ "ref: refs/heads/" .. branch }, dir .. "/.git/HEAD")
  vim.fn.writefile({ "[user]", "\tname = Fixture User" }, dir .. "/.git/config")
end

T.test("branch scoping matches the CLI's filenames", function()
  T.with_tmpdir(function(dir)
    make_repo(dir, "feature/cool-thing")
    local s = store.open(dir)
    T.eq(s.raw_branch, "feature/cool-thing")
    T.eq(s.branch, "feature_cool-thing")
    T.eq(s:notes_file_name(), "notes_feature_cool-thing.json")
  end)
end)

T.test("a detached HEAD falls back to the legacy notes.json", function()
  T.with_tmpdir(function(dir)
    make_repo(dir, "main")
    vim.fn.writefile({ "9fceb02d0ae598e95dc970b74767f19372d61af8" }, dir .. "/.git/HEAD")
    local s = store.open(dir)
    T.eq(s.raw_branch, "")
    T.eq(s:notes_file_name(), "notes.json")
  end)
end)

T.test("the root is the nearest ancestor holding .incomm/", function()
  T.with_tmpdir(function(dir)
    make_repo(dir, "main")
    vim.fn.mkdir(dir .. "/.incomm", "p")
    vim.fn.mkdir(dir .. "/src/deep/nested", "p")
    local s = store.open(dir .. "/src/deep/nested")
    T.eq(s.root, dir)
    T.eq(s:rel_file(dir .. "/src/main.go"), "src/main.go")
    T.eq(s:rel_file("/etc/hosts"), nil, "files outside the root are rejected")
  end)
end)

T.test("save is atomic and re-readable", function()
  T.with_tmpdir(function(dir)
    make_repo(dir, "main")
    local s = store.open(dir)
    local f = model.new_file()
    f.notes = {
      {
        id = "abc12345",
        file = "src/main.go",
        startLine = 3,
        endLine = 5,
        anchor = require("incomm.anchor").compute(s:read_lines("src/main.go"), 3, 5),
        content = "needs a test",
        resolved = false,
        orphaned = false,
        author = "user",
        authorTitle = "Fixture User",
        createdAt = "2026-01-01T00:00:00Z",
        updatedAt = "2026-01-01T00:00:00Z",
        replies = {},
      },
    }
    local written = s:save(f)
    T.ok(written, "save returned the bytes it wrote")
    local reloaded = s:load()
    T.eq(reloaded.branch, "main")
    T.eq(#reloaded.notes, 1)
    T.eq(reloaded.notes[1].content, "needs a test")
    T.eq(model.encode(reloaded), written, "re-encoding is stable")
    T.eq(s:clear(), true)
    T.eq(#s:load().notes, 0)
  end)
end)

T.test("encoding escapes exactly as Go's encoding/json does", function()
  local f = model.new_file()
  f.notes = {
    {
      id = "1",
      file = "a.go",
      startLine = 1,
      endLine = 1,
      anchor = { startPrefix = "", endPrefix = "", contextBefore = "", contextAfter = "", checksum = "" },
      content = 'tags <b> & "quotes"\nand a tab\there',
      resolved = false,
      orphaned = false,
      author = "agent",
      createdAt = "x",
      updatedAt = "x",
      replies = {},
    },
  }
  local text = model.encode(f)
  T.ok(text:find('\\u003cb\\u003e \\u0026 \\"quotes\\"', 1, true), "HTML-escaped like Go: " .. text)
  T.ok(text:find("\\nand a tab\\there", 1, true), "control chars escaped")
  T.ok(not text:find('"authorTitle"', 1, true), "omitempty fields are omitted")
  T.ok(text:find('"replies": []', 1, true), "empty slices are [] not null")
end)

if not has_cli then
  T.test("SKIPPED: byte-identity with the CLI (incomm not on $PATH)", function() end)
else
  T.test("what the plugin writes is byte-identical to the CLI's output", function()
    T.with_tmpdir(function(dir)
      make_repo(dir, "main")
      -- Let the CLI create the file, with a range note, a reply and an
      -- author title, so every field shape is exercised.
      local add = vim.fn.system({
        "incomm", "--root", dir, "add",
        "-f", dir .. "/src/main.go", "-l", "3:5",
        "-c", 'agent note with <html> & "quotes"',
        "--author-title", "Opus 5",
        "--json",
      })
      local note = vim.json.decode(add)
      vim.fn.system({ "incomm", "--root", dir, "reply", note.id, "-c", "a reply", "--author", "user", "--author-title", "Fixture User" })

      local s = store.open(dir)
      local on_disk = s:read_raw()
      local reencoded = model.encode(s:load())
      T.eq(reencoded, on_disk, "plugin re-encoding differs from the CLI's bytes")
    end)
  end)

  T.test("the CLI reads back a file this plugin wrote", function()
    T.with_tmpdir(function(dir)
      make_repo(dir, "main")
      local s = store.open(dir)
      local anchor = require("incomm.anchor")
      local lines = s:read_lines("src/main.go")
      local f = model.new_file()
      f.notes = {
        {
          id = model.new_id(),
          file = "src/main.go",
          startLine = 4,
          endLine = 4,
          anchor = anchor.compute(lines, 4, 4),
          content = "written by the nvim plugin",
          resolved = false,
          orphaned = false,
          author = "user",
          authorTitle = "Fixture User",
          createdAt = model.now_utc(),
          updatedAt = model.now_utc(),
          replies = {},
        },
      }
      s:save(f)
      local listed = vim.json.decode(vim.fn.system({ "incomm", "--root", dir, "list", "--json" }))
      T.eq(#listed.notes, 1)
      T.eq(listed.notes[1].content, "written by the nvim plugin")
      T.eq(listed.notes[1].startLine, 4)
      T.eq(listed.notes[1].orphaned, false, "the CLI re-anchors it without orphaning")
    end)
  end)
end
