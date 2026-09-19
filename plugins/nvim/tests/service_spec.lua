-- Model mutations, merge-on-write, and live position tracking.
--
-- The concurrency tests mirror `NotesServiceTest` on the IntelliJ side: an
-- agent note added behind our back must survive our next write, and a note we
-- just deleted must not come back from the still-current file on disk.

local T = _G.T
local service = require("incomm.service")
local model = require("incomm.model")

local has_cli = vim.fn.executable("incomm") == 1

---@param dir string
local function make_repo(dir)
  vim.fn.mkdir(dir .. "/src", "p")
  vim.fn.writefile({
    "package main",
    "",
    "// entrypoint",
    "func main() {",
    '\tprintln("hi")',
    "}",
  }, dir .. "/src/main.go")
  vim.fn.mkdir(dir .. "/.git", "p")
  vim.fn.writefile({ "ref: refs/heads/main" }, dir .. "/.git/HEAD")
  vim.fn.writefile({ "[user]", "\tname = Fixture User" }, dir .. "/.git/config")
end

---@param dir string
---@return incomm.Service
local function fresh(dir)
  service.reset()
  make_repo(dir)
  return service.for_root(dir)
end

T.test("adding a thread writes a file the CLI can read", function()
  T.with_tmpdir(function(dir)
    local svc = fresh(dir)
    local note = svc:add_note("src/main.go", 4, 6, "please add a test")
    T.eq(note.author, "user")
    T.eq(note.authorTitle, "Fixture User", "user comments carry git user.name")
    T.eq(note.anchor.startPrefix, "func main() {")
    T.eq(note.anchor.contextBefore, "// entrypoint")
    T.eq(#svc:all_notes(), 1)

    local reloaded = svc.store:load()
    T.eq(#reloaded.notes, 1)
    T.eq(reloaded.branch, "main")
  end)
end)

T.test("replies, edits, resolve and delete round-trip", function()
  T.with_tmpdir(function(dir)
    local svc = fresh(dir)
    local note = svc:add_note("src/main.go", 4, 4, "first")
    svc:add_reply(note.id, "a reply")
    svc:update_content(note.id, "edited")
    svc:set_resolved(note.id, true)

    local stored = svc.store:load().notes[1]
    T.eq(stored.content, "edited")
    T.eq(stored.resolved, true)
    T.eq(#stored.replies, 1)
    T.eq(stored.replies[1].author, "user")

    svc:remove_reply(note.id, stored.replies[1].id)
    T.eq(#svc:find(note.id).replies, 0)
    T.eq(svc:remove_note(note.id), true)
    T.eq(svc:is_empty(), true)
    T.eq(#svc.store:load().notes, 0)
  end)
end)

T.test("merge-on-write keeps a note added behind our back", function()
  T.with_tmpdir(function(dir)
    local svc = fresh(dir)
    local mine = svc:add_note("src/main.go", 4, 4, "mine")

    -- Someone else (the agent, via the CLI) appends to the file while our
    -- model is stale.
    local disk = svc.store:load()
    table.insert(disk.notes, {
      id = "agent001",
      file = "src/main.go",
      startLine = 5,
      endLine = 5,
      anchor = require("incomm.anchor").compute(svc:lines_for("src/main.go"), 5, 5),
      content = "from the agent",
      resolved = false,
      orphaned = false,
      author = "agent",
      authorTitle = "Opus 5",
      createdAt = model.now_utc(),
      updatedAt = model.now_utc(),
      replies = {},
    })
    svc.store:save(disk)

    -- Our next write must not clobber it.
    svc:update_content(mine.id, "mine, edited")
    local after = svc.store:load()
    T.eq(#after.notes, 2, "the agent's note survived our write")
    T.ok(model.find(after, "agent001"), "by id")
    T.eq(model.find(after, mine.id).content, "mine, edited")
  end)
end)

T.test("a locally deleted note is not resurrected by the merge", function()
  T.with_tmpdir(function(dir)
    local svc = fresh(dir)
    local note = svc:add_note("src/main.go", 4, 4, "doomed")
    -- Delete it, but pretend the file on disk still has it: write the old
    -- content back underneath us, then force another write.
    local stale = svc.store:load()
    svc:remove_note(note.id)
    svc.store:save(stale) -- disk now has the deleted note again
    svc.locally_deleted[note.id] = true
    svc:add_note("src/main.go", 5, 5, "another")

    local after = svc.store:load()
    T.eq(model.find(after, note.id), nil, "the deleted note stayed deleted")
    T.eq(#after.notes, 1)
  end)
end)

T.test("reload skips its notification when nothing changed", function()
  T.with_tmpdir(function(dir)
    local svc = fresh(dir)
    svc:add_note("src/main.go", 4, 4, "x")
    local fired = 0
    svc:on_change(function()
      fired = fired + 1
    end)
    T.eq(svc:reload(), false, "our own write is not a change")
    T.eq(fired, 0)

    -- A real external change does fire.
    local disk = svc.store:load()
    disk.notes[1].content = "changed elsewhere"
    svc.store:save(disk)
    T.eq(svc:reload(), true)
    T.eq(fired, 1)
    T.eq(svc:find(svc:all_notes()[1].id).content, "changed elsewhere")
  end)
end)

T.test("agent replies arriving from outside are reported as news", function()
  T.with_tmpdir(function(dir)
    local svc = fresh(dir)
    local note = svc:add_note("src/main.go", 4, 4, "question?")
    local got
    svc:on_agent_news(function(news)
      got = news
    end)

    local disk = svc.store:load()
    table.insert(disk.notes[1].replies, {
      id = "r1",
      author = "agent",
      authorTitle = "Opus 5",
      content = "answered",
      createdAt = model.now_utc(),
    })
    svc.store:save(disk)
    svc:reload()

    T.ok(got and #got == 1, "one piece of news")
    T.eq(got[1].is_reply, true)
    T.eq(got[1].content, "answered")
    T.eq(got[1].file, "src/main.go")
    T.eq(svc:find(note.id).replies[1].content, "answered")
  end)
end)

T.test("apply_saved_positions moves notes and re-anchors dead ones", function()
  T.with_tmpdir(function(dir)
    local svc = fresh(dir)
    local moved = svc:add_note("src/main.go", 4, 4, "tracks the func")
    local dead = svc:add_note("src/main.go", 5, 5, "tracks the println")

    -- Two lines inserted at the top: the editor's extmark for `moved` reports
    -- line 6; `dead` lost its mark and must be found by text.
    local lines = {
      "// added",
      "// added",
      "package main",
      "",
      "// entrypoint",
      "func main() {",
      '\tprintln("hi")',
      "}",
    }
    vim.fn.writefile(lines, dir .. "/src/main.go")
    svc:apply_saved_positions("src/main.go", lines, { [moved.id] = { 6, 6 } })

    T.eq(svc:find(moved.id).startLine, 6, "position taken from the extmark")
    T.eq(svc:find(moved.id).anchor.startPrefix, "func main() {")
    T.eq(svc:find(dead.id).startLine, 7, "re-anchored by text")
    T.eq(svc:find(dead.id).orphaned, false)
  end)
end)

T.test("a note whose code is gone becomes orphaned, and heals when it returns", function()
  T.with_tmpdir(function(dir)
    local svc = fresh(dir)
    local note = svc:add_note("src/main.go", 5, 5, "about the println")

    vim.fn.writefile({ "package main", "", "// entrypoint", "func main() {", "}" }, dir .. "/src/main.go")
    svc:reanchor_from_disk()
    T.eq(svc:find(note.id).orphaned, true)

    vim.fn.writefile(
      { "package main", "", "// entrypoint", "func main() {", '\tprintln("hi")', "}" },
      dir .. "/src/main.go"
    )
    svc:reanchor_from_disk()
    T.eq(svc:find(note.id).orphaned, false, "self-healed once the text came back")
    T.eq(svc:find(note.id).startLine, 5)
  end)
end)

T.test("a deleted file orphans its notes rather than losing them", function()
  T.with_tmpdir(function(dir)
    local svc = fresh(dir)
    local note = svc:add_note("src/main.go", 4, 4, "x")
    vim.fn.delete(dir .. "/src/main.go")
    svc:reanchor_from_disk()
    T.eq(svc:find(note.id).orphaned, true)
    T.eq(svc:find(note.id).startLine, 4, "the last known position is kept")
  end)
end)

T.test("switching branches switches the notes file", function()
  T.with_tmpdir(function(dir)
    local svc = fresh(dir)
    svc:add_note("src/main.go", 4, 4, "on main")
    T.eq(vim.fn.filereadable(dir .. "/.incomm/notes_main.json"), 1)

    vim.fn.writefile({ "ref: refs/heads/feature/x" }, dir .. "/.git/HEAD")
    T.eq(svc:check_branch(), true)
    T.eq(svc:is_empty(), true, "the feature branch starts clean")
    svc:add_note("src/main.go", 5, 5, "on the feature branch")
    T.eq(vim.fn.filereadable(dir .. "/.incomm/notes_feature_x.json"), 1)

    vim.fn.writefile({ "ref: refs/heads/main" }, dir .. "/.git/HEAD")
    svc:check_branch()
    T.eq(#svc:all_notes(), 1)
    T.eq(svc:all_notes()[1].content, "on main", "switching back restores the branch's threads")
  end)
end)

T.test("note_at finds the innermost thread under a line", function()
  T.with_tmpdir(function(dir)
    local svc = fresh(dir)
    svc:add_note("src/main.go", 3, 6, "the whole function")
    local inner = svc:add_note("src/main.go", 5, 5, "this line")
    T.eq(svc:note_at("src/main.go", 5).id, inner.id)
    T.eq(svc:note_at("src/main.go", 3).content, "the whole function")
    T.eq(svc:note_at("src/main.go", 1), nil)
  end)
end)

if has_cli then
  T.test("the CLI and the plugin interleave writes without losing notes", function()
    T.with_tmpdir(function(dir)
      local svc = fresh(dir)
      local mine = svc:add_note("src/main.go", 4, 4, "from the editor")

      -- The agent adds a note and replies to ours, entirely through the CLI.
      vim.fn.system({ "incomm", "--root", dir, "add", "-f", dir .. "/src/main.go", "-l", "5", "-c", "from the agent", "--author-title", "Opus 5" })
      vim.fn.system({ "incomm", "--root", dir, "reply", mine.id, "-c", "on it", "--author-title", "Opus 5" })

      svc:reload()
      T.eq(#svc:all_notes(), 2)
      T.eq(#svc:find(mine.id).replies, 1)

      -- And our next write keeps all of it.
      svc:set_resolved(mine.id, true)
      local listed = vim.json.decode(vim.fn.system({ "incomm", "--root", dir, "list", "--json" }))
      T.eq(#listed.notes, 2)
      T.eq(model.find(listed, mine.id).resolved, true)
      T.eq(#model.find(listed, mine.id).replies, 1)
    end)
  end)

  T.test("the CLI's view of positions matches ours after an edit", function()
    T.with_tmpdir(function(dir)
      local svc = fresh(dir)
      local note = svc:add_note("src/main.go", 5, 5, "about the println")
      vim.fn.writefile({
        "package main",
        "",
        "import \"fmt\"",
        "",
        "// entrypoint",
        "func main() {",
        '\tprintln("hi")',
        "}",
      }, dir .. "/src/main.go")

      svc:reanchor_from_disk()
      local listed = vim.json.decode(vim.fn.system({ "incomm", "--root", dir, "list", "--json" }))
      T.eq(model.find(listed, note.id).startLine, svc:find(note.id).startLine, "same line after re-anchoring")
      T.eq(svc:find(note.id).startLine, 7)
    end)
  end)
end

service.reset()
