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

--- Install a fixture as the notes file of a fresh repo and return its bytes.
---@param dir string
---@param fixture string
---@return string
local function install_fixture(dir, fixture)
  make_repo(dir, "main")
  vim.fn.mkdir(dir .. "/.incomm", "p")
  local data = require("incomm.git").read_file(T.repo_root .. "/fixtures/" .. fixture)
  local fd = assert(io.open(dir .. "/.incomm/notes_main.json", "wb"))
  fd:write(data)
  fd:close()
  return data
end

T.test("a file in a newer format is refused, whatever its shape, and left untouched", function()
  T.with_tmpdir(function(dir)
    local before = install_fixture(dir, "notes.future.json")
    local s = store.open(dir)
    local loaded, err, incompat = s:load()
    T.eq(err, nil)
    T.eq(#loaded.notes, 0, "no model is taken from it")
    T.eq(incompat, { found = 99, supported = model.SCHEMA_VERSION })
    T.eq(s:read_raw(), before, "loading never writes")
    T.eq(select(3, model.decode(before)).found, 99)
  end)
end)

T.test("a v1 file loads and is stamped with the current version on save", function()
  T.with_tmpdir(function(dir)
    install_fixture(dir, "notes.sample.json")
    local s = store.open(dir)
    local f = s:load()
    T.eq(f.version, 1)
    T.eq(#f.notes, 3)
    s:save(f)
    T.eq(s:load().version, model.SCHEMA_VERSION)
    T.ok(s:read_raw():find('"version": 2', 1, true), "the file says version 2")
    local raw = s:read_raw()
    local _, agents = raw:gsub('"audience": "agent"', "")
    local _, replies = raw:gsub('"replies": %[\n', "")
    T.ok(agents >= 3, "every note of the old file gains its default audience, and so does its reply: " .. agents)
    T.eq(s:load().notes[1].replies[1].audience, "agent")
  end)
end)

T.test("a v2 file round-trips audience and source byte for byte", function()
  T.with_tmpdir(function(dir)
    local before = install_fixture(dir, "notes.v2.sample.json")
    local s = store.open(dir)
    local f = s:load()
    T.eq(f.notes[2].audience, "agent+external")
    T.eq(f.notes[2].source.id, 501)
    T.eq(f.notes[2].replies[1].source.thread, nil)
    T.eq(f.notes[3].audience, "private")
    T.eq(f.notes[1].audience, "agent", "an absent audience is read as agent")
    -- The fixture has no branch field and writes `&`, `<` and `>` raw, where Go
    -- (and so this encoder) escapes them, and its first note has no audience; a
    -- save stamps the branch, escapes those three, writes that note's default
    -- audience out and changes nothing else.
    s:save(f)
    local want = before:gsub('"version": 2,\n', '"version": 2,\n  "branch": "main",\n', 1)
    want = want:gsub("Reviewer & Co <r@example.com>", "Reviewer \\u0026 Co \\u003cr@example.com\\u003e", 1)
    want = want:gsub("note_501&x=1", "note_501\\u0026x=1", 1)
    local title = '"authorTitle": "Jan Tobola",\n      "createdAt": "2026-07-17T10:00:00Z"'
    local at = want:find(title, 1, true)
    T.ok(at, "the fixture's first note has no audience")
    local put = '"authorTitle": "Jan Tobola",\n      "audience": "agent",\n      "createdAt": "2026-07-17T10:00:00Z"'
    want = want:sub(1, at - 1) .. put .. want:sub(at + #title)
    T.eq(s:read_raw(), want)
  end)
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

  -- An older `incomm` on $PATH has no audience flags and no `version` command.
  local function cli_speaks_v2()
    local out = vim.fn.system({ "incomm", "version", "--json" })
    if vim.v.shell_error ~= 0 then
      return false
    end
    local ok, info = pcall(vim.json.decode, out)
    return ok and type(info) == "table" and (info.formatVersion or 0) >= 2
  end

  T.test("audience and source are byte-identical to the CLI's output", function()
    if not cli_speaks_v2() then
      io.write("       (skipped: the incomm on $PATH predates format v2)\n")
      return
    end
    T.with_tmpdir(function(dir)
      make_repo(dir, "main")
      local add = vim.fn.system({
        "incomm", "--root", dir, "add",
        "-f", dir .. "/src/main.go", "-l", "3:5",
        "-c", "imported & <linked>",
        "--author", "user", "--author-title", "Reviewer",
        "--audience", "agent+external",
        "--source-url", "https://gitlab.example/g/a/-/merge_requests/7#note_501&x=1",
        "--source-id", "501", "--source-thread", "9f8e7d6c5b4a",
        "--json",
      })
      local note = vim.json.decode(add)
      vim.fn.system({
        "incomm", "--root", dir, "reply", note.id, "-c", "for the forge",
        "--audience", "external", "--source-url", "https://gitlab.example/x#note_502", "--source-id", "502",
      })
      local s = store.open(dir)
      local on_disk = s:read_raw()
      T.ok(on_disk:find('"audience": "agent+external"', 1, true), "the CLI wrote the audience")
      T.ok(on_disk:find('"version": 2', 1, true), "the CLI stamped version 2")
      T.eq(model.encode(s:load()), on_disk, "plugin re-encoding differs from the CLI's bytes")
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
