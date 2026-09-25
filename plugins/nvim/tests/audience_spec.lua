-- Audience: who may see a comment, and the surfaces that show and change it.
--
-- The pure rules live in `model.lua`, the badge in `ui/bubble.lua`, the write in
-- the service, and the flow in `ui/audience.lua` behind `:Incomm audience` and
-- the explorer's `a`. The one thing worth checking against the real CLI is that
-- a change made here leaves the same bytes `incomm set` would.

local T = _G.T
local bubble = require("incomm.ui.bubble")
local explorer = require("incomm.ui.explorer")
local incomm = require("incomm")
local model = require("incomm.model")
local render = require("incomm.ui.render")
local service = require("incomm.service")
local track = require("incomm.track")
local ui_state = require("incomm.ui.state")

local SOURCE = {
  "package main",
  "",
  "// entrypoint",
  "func main() {",
  '\tprintln("hi")',
  "}",
}

---@param dir string
local function make_repo(dir)
  vim.fn.mkdir(dir .. "/src", "p")
  vim.fn.writefile(SOURCE, dir .. "/src/main.go")
  vim.fn.mkdir(dir .. "/.git", "p")
  vim.fn.writefile({ "ref: refs/heads/main" }, dir .. "/.git/HEAD")
  vim.fn.writefile({ "[user]", "\tname = Fixture User" }, dir .. "/.git/config")
end

---@param dir string
---@return integer bufnr, incomm.Service
local function open_fixture(dir)
  service.reset()
  ui_state.reset()
  make_repo(dir)
  vim.cmd("silent! %bwipeout!")
  vim.cmd.cd(dir)
  incomm.setup({ watch = false, reanchor_delay = 10 })
  vim.cmd.edit(dir .. "/src/main.go")
  local bufnr = vim.api.nvim_get_current_buf()
  local t = track.attach(bufnr)
  return bufnr, t.svc
end

---@param keys string
local function feed(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end

---@param chunks table[]
---@return string
local function flat(chunks)
  return table.concat(vim.tbl_map(function(chunk)
    return chunk[1]
  end, chunks))
end

--- Run `fn` with `vim.ui.select` and `vim.notify` replaced, restoring both.
---@param choose fun(items: table[], opts: table): table? what the "user" picks
---@param fn fun(calls: table[], notes: string[])
local function with_ui(choose, fn)
  local select, notify = vim.ui.select, vim.notify
  local calls, notes = {}, {}
  vim.ui.select = function(items, opts, on_choice)
    calls[#calls + 1] = { items = items, opts = opts }
    on_choice(choose(items, opts))
  end
  vim.notify = function(msg)
    notes[#notes + 1] = msg
  end
  local ok, err = pcall(fn, calls, notes)
  vim.ui.select, vim.notify = select, notify
  if not ok then
    error(err, 0)
  end
end

local function no_picker()
  error("the picker must not open for a thread with one comment")
end

-- ---- the rules ---------------------------------------------------------------

T.test("an absent audience is agent and an unknown one is private", function()
  for _, absent in ipairs({ "", "agent" }) do
    T.eq(model.normalize_audience(absent), "agent")
  end
  T.eq(model.normalize_audience(nil), "agent")
  T.eq(model.normalize_audience(vim.NIL), "agent")
  T.eq(model.normalize_audience("team"), "private", "a value from the future is never shown")
  T.eq(model.stored_audience("agent"), "agent", "the default is written out like any other value")
  T.eq(model.stored_audience("external"), "external")
end)

T.test("the cycle is agent, agent + external, external, private", function()
  local seen, a = {}, "agent"
  for _ = 1, 5 do
    seen[#seen + 1] = a
    a = model.next_audience(a)
  end
  T.eq(seen, { "agent", "agent+external", "external", "private", "agent" })
  T.eq(model.next_audience(nil), "agent+external", "an absent audience steps from agent")
  T.eq(model.next_audience("team"), "agent", "an unknown one counts as private, so it steps to agent")
end)

T.test("a comment under a private root is private whatever it stores", function()
  local private_root = { audience = "private" }
  T.eq(model.effective_audience(private_root, { audience = "agent+external" }), "private")
  T.eq(model.effective_audience(private_root, private_root), "private")
  T.eq(model.effective_audience({ audience = "external" }, { audience = nil }), "agent")
  T.eq(model.effective_audience({}, { audience = "external" }), "external")
  T.eq(model.effective_audience({ audience = "team" }, { audience = "agent" }), "private", "unknown root is private")
end)

T.test("what includes the agent, what includes the forge, and what is published", function()
  T.ok(model.includes_external("external") and model.includes_external("agent+external"))
  T.ok(not model.includes_external("agent") and not model.includes_external(nil) and not model.includes_external("private"))
  T.ok(model.includes_agent(nil) and model.includes_agent("agent+external"))
  T.ok(not model.includes_agent("external") and not model.includes_agent("private"))
  T.ok(not model.is_published({}))
  T.ok(not model.is_published({ source = {} }))
  T.ok(model.is_published({ source = { id = 5 } }))
  T.ok(model.is_published({ source = { url = "https://forge/x" } }))
end)

-- ---- the badge -----------------------------------------------------------------

T.test("plain agent is drawn too, dimmer; the others name themselves and their state", function()
  local plain = bubble.badge("agent", false, 80)
  T.eq(flat(plain), "  agent")
  T.eq(plain[1][2], "IncommBadgeAgent", "the default is the quietest badge")
  T.eq({ bubble.badge("agent", false, 3) }, { {}, 0 }, "and it gives way like the rest")

  local chunks = bubble.badge("agent+external", false, 80)
  T.eq(flat(chunks), "  agent + external · not published")
  T.eq(chunks[2][2], "IncommBadgePending")
  T.eq(flat(bubble.badge("agent+external", true, 80)), "  agent + external · published")
  local published = bubble.badge("external", true, 80)
  T.eq(published[2][2], "IncommBadgePublished")
  T.eq(flat(bubble.badge("external", false, 80)), "  external · not published")

  local private = bubble.badge("private", true, 80)
  T.eq(flat(private), "  private", "private has no state: it never goes anywhere")
  T.eq(private[1][2], "IncommBadgePrivate")
end)

T.test("the badge gives way when the header line is short of room", function()
  local full = "  agent + external · not published"
  local width = vim.fn.strdisplaywidth(full)
  T.eq(flat(bubble.badge("agent+external", false, width)), full)
  T.eq(flat(bubble.badge("agent+external", false, width - 1)), "  agent + external", "the state word goes first")
  T.eq(flat(bubble.badge("agent+external", false, 17)), "  +external", "then \"agent +\" shrinks to a plus")
  T.eq({ bubble.badge("agent+external", false, 5) }, { {}, 0 }, "then the whole badge")
  T.eq(flat(bubble.badge("external", false, 10)), "  external", "external has nothing shorter to give")
  T.eq({ bubble.badge("external", false, 9) }, { {}, 0 })
end)

T.test("a badge never changes a bubble's height or breaks its box", function()
  local function build(audience, width, title)
    return bubble.build({
      author = "user",
      title = title or "Jan Tobola",
      created = "2026-07-17T10:00:00Z",
      content = "one short line",
      width = width,
      border = "rounded",
      audience = audience,
      published = false,
    })
  end
  for _, width in ipairs({ 60, 40, 24 }) do
    local plain = build("agent", width)
    for _, audience in ipairs({ "agent+external", "external", "private" }) do
      local badged = build(audience, width)
      T.eq(#badged, #plain, audience .. " at width " .. width .. " changes the height")
      local want = vim.fn.strdisplaywidth(flat(badged[1]))
      for i, row in ipairs(badged) do
        T.eq(vim.fn.strdisplaywidth(flat(row)), want, audience .. " at width " .. width .. ", row " .. i)
      end
    end
  end
  T.ok(flat(build("external", 60)[2]):find("external · not published", 1, true), "the header carries it")
  T.ok(not flat(build("agent", 60)[2]):find("external", 1, true))
  -- A long name leaves no room; the box still closes cleanly.
  local crowded = build("agent+external", 30, "A very long display name")
  T.eq(#crowded, #build("agent", 30, "A very long display name"))
end)

T.test("a card draws the badge on each comment, and a private root makes its replies private", function()
  T.with_tmpdir(function(dir)
    local bufnr, svc = open_fixture(dir)
    local note = svc:add_note("src/main.go", 4, 4, "root")
    svc:add_reply(note.id, "answer", "agent", "Opus 5")
    svc:set_audience(note.id, nil, "external")
    track.refresh(bufnr)

    local function card_text()
      local mark = vim.api.nvim_buf_get_extmarks(bufnr, render.ns, 0, -1, { details = true })[1]
      local lines = {}
      for _, row in ipairs(mark[4].virt_lines) do
        lines[#lines + 1] = flat(row)
      end
      return lines
    end
    local before = #card_text()
    local text = table.concat(card_text(), "\n")
    T.ok(text:find("external · not published", 1, true), "the root's badge: " .. text)
    T.ok(not text:find("private", 1, true))

    svc:set_audience(note.id, nil, "private")
    track.refresh(bufnr)
    local after = card_text()
    T.eq(#after, before, "changing an audience does not change the card's height")
    local privates = 0
    for _, line in ipairs(after) do
      if line:find("private", 1, true) then
        privates = privates + 1
      end
    end
    T.eq(privates, 2, "the root and its reply, though the reply stores nothing")
    T.eq(svc:find(note.id).replies[1].audience, "agent", "the reply's stored audience is untouched")
  end)
end)

-- ---- the service ---------------------------------------------------------------

T.test("set_audience stores the default as agent and never changes what it was not asked to", function()
  T.with_tmpdir(function(dir)
    local _, svc = open_fixture(dir)
    local note = svc:add_note("src/main.go", 4, 4, "root")
    svc:add_reply(note.id, "answer", "agent", "Opus 5")
    local reply_id = svc:find(note.id).replies[1].id

    T.ok(svc:set_audience(note.id, nil, "external"))
    T.eq(svc:find(note.id).audience, "external")
    T.eq(svc:find(note.id).replies[1].audience, "agent", "the reply is its own comment")
    T.ok(svc.store:read_raw():find('"audience": "external"', 1, true), "on disk")

    T.ok(svc:set_audience(note.id, reply_id, "agent+external"))
    T.eq(svc:find(note.id).replies[1].audience, "agent+external")
    T.eq(svc:find(note.id).audience, "external")

    T.ok(svc:set_audience(note.id, nil, "agent"))
    T.eq(svc:find(note.id).audience, "agent", "agent is stored as agent")
    T.ok(svc.store:read_raw():find('"audience": "agent"', 1, true), "and written like any other value")

    T.ok(not svc:set_audience(note.id, nil, "team"), "an unknown audience is refused")
    T.ok(not svc:set_audience(note.id, nil, ""), "so is an empty one")
    T.ok(not svc:set_audience(note.id, "nosuchreply", "external"), "and a reply that is not there")
    T.ok(not svc:set_audience("nosuchnote", nil, "external"))
    T.eq(svc:find(note.id).audience, "agent")
    T.eq(svc:find(note.id).replies[1].audience, "agent+external")
  end)
end)

T.test("set_thread_audience moves every comment in one write", function()
  T.with_tmpdir(function(dir)
    local _, svc = open_fixture(dir)
    local note = svc:add_note("src/main.go", 4, 4, "root")
    svc:add_reply(note.id, "one", "agent", "Opus 5")
    svc:add_reply(note.id, "two")
    svc:set_audience(note.id, svc:find(note.id).replies[1].id, "private")

    local saves = 0
    service.on_saved(function()
      saves = saves + 1
    end)
    T.ok(svc:set_thread_audience(note.id, "agent+external"))
    T.eq(saves, 1, "one write for the whole thread")
    local after = svc:find(note.id)
    T.eq(after.audience, "agent+external")
    T.eq({ after.replies[1].audience, after.replies[2].audience }, { "agent+external", "agent+external" })
    T.ok(svc:set_thread_audience(note.id, "agent"))
    T.eq(after.audience, "agent", "agent is stored as agent, on every comment")
    T.eq(after.replies[1].audience, "agent")
    T.eq(after.replies[2].audience, "agent")
  end)
end)

T.test("a file in a newer format refuses an audience change and is left untouched", function()
  T.with_tmpdir(function(dir)
    local _, svc = open_fixture(dir)
    local note = svc:add_note("src/main.go", 4, 4, "root")
    local future = require("incomm.git").read_file(T.repo_root .. "/fixtures/notes.future.json")
    local fd = assert(io.open(svc.store:notes_path(), "wb"))
    fd:write(future)
    fd:close()
    with_ui(no_picker, function(calls, notes)
      svc:reload({ publish = false })
      T.ok(svc.blocked, "the service is blocked")
      T.ok(not svc:set_audience(note.id, nil, "external"))
      T.ok(not svc:set_thread_audience(note.id, "external"))
      require("incomm.ui.audience").change(svc, note)
      T.eq(#calls, 0)
      T.ok(#notes >= 1 and notes[#notes]:find("update the incomm plugin", 1, true), "it says why: " .. vim.inspect(notes))
    end)
    T.eq(svc.store:read_raw(), future, "nothing was written")
  end)
end)

-- ---- byte-identity with the CLI ---------------------------------------------------

local has_cli = vim.fn.executable("incomm") == 1

local function cli_speaks_v2()
  local out = vim.fn.system({ "incomm", "version", "--json" })
  if vim.v.shell_error ~= 0 then
    return false
  end
  local ok, info = pcall(vim.json.decode, out)
  return ok and type(info) == "table" and (info.formatVersion or 0) >= 2
end

if not has_cli or not cli_speaks_v2() then
  T.test("SKIPPED: a change matches `incomm set` (no incomm that speaks format v2 on $PATH)", function() end)
else
  T.test("changing an audience leaves the bytes `incomm set` leaves", function()
    T.with_tmpdir(function(dir)
      local by_cli, by_plugin = dir .. "/cli", dir .. "/plugin"
      make_repo(by_cli)
      make_repo(by_plugin)
      local function cli(root, ...)
        local out = vim.fn.system({ "incomm", "--root", root, ... })
        T.eq(vim.v.shell_error, 0, "incomm failed: " .. out)
        return out
      end

      local note = vim.json.decode(cli(by_cli, "add", "-f", by_cli .. "/src/main.go", "-l", "4", "-c", "root & <it>",
        "--author", "user", "--author-title", "Fixture User", "--json"))
      local reply = vim.json.decode(cli(by_cli, "reply", note.id, "-c", "answer", "--author", "agent",
        "--author-title", "Opus 5", "--json"))
      local reply_id = reply.replies[1].id

      -- The same file, in the checkout the plugin works on.
      vim.fn.mkdir(by_plugin .. "/.incomm", "p")
      local start = require("incomm.git").read_file(by_cli .. "/.incomm/notes_main.json")
      local fd = assert(io.open(by_plugin .. "/.incomm/notes_main.json", "wb"))
      fd:write(start)
      fd:close()

      -- The CLI goes first through the reply while the thread is still the agent's,
      -- then moves the thread to the forge; and back again.
      cli(by_cli, "set", note.id, "--reply", reply_id, "--audience", "agent+external")
      cli(by_cli, "set", note.id, "--audience", "external")
      cli(by_cli, "--view", "external", "set", note.id, "--audience", "agent")

      service.reset()
      vim.cmd.cd(by_plugin)
      incomm.setup({ watch = false })
      local svc = service.for_root(by_plugin)
      T.ok(svc:set_audience(note.id, reply_id, "agent+external"))
      T.ok(svc:set_audience(note.id, nil, "external"))
      T.ok(svc:set_audience(note.id, nil, "agent"))

      -- Both stamp the moment of the change; nothing else may differ.
      local function bytes(root)
        local raw = require("incomm.git").read_file(root .. "/.incomm/notes_main.json")
        return (raw:gsub('"updatedAt": "[^"]*"', '"updatedAt": "T"'))
      end
      T.eq(bytes(by_plugin), bytes(by_cli))
      T.ok(bytes(by_cli):find('"audience": "agent+external"', 1, true), "the reply kept its audience")
    end)
  end)
end

-- ---- :Incomm audience ------------------------------------------------------------------

T.test(":Incomm audience steps a one-comment thread round the cycle without a picker", function()
  T.with_tmpdir(function(dir)
    local bufnr, svc = open_fixture(dir)
    local note = svc:add_note("src/main.go", 4, 4, "root")
    track.refresh(bufnr)
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    with_ui(no_picker, function(_, notes)
      local seen = {}
      for _ = 1, 4 do
        vim.cmd("Incomm audience")
        seen[#seen + 1] = svc:find(note.id).audience
      end
      T.eq(seen, { "agent+external", "external", "private", "agent" })
      T.ok(notes[1]:find("agent + external", 1, true), "it says what it did: " .. notes[1])
    end)
    T.eq(svc:find(note.id).audience, "agent")
  end)
end)

T.test(":Incomm audience <name> goes straight there, and refuses a name that is not one", function()
  T.with_tmpdir(function(dir)
    local bufnr, svc = open_fixture(dir)
    local note = svc:add_note("src/main.go", 4, 4, "root")
    track.refresh(bufnr)
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    with_ui(no_picker, function(_, notes)
      vim.cmd("Incomm audience private")
      T.eq(svc:find(note.id).audience, "private")
      vim.cmd("Incomm audience nonsense")
      T.eq(svc:find(note.id).audience, "private", "unchanged")
      T.ok(notes[#notes]:find("must be one of", 1, true), notes[#notes])
      vim.cmd("Incomm audience agent+external")
      T.eq(svc:find(note.id).audience, "agent+external")
    end)
  end)
end)

T.test("the subcommand completes its argument", function()
  T.eq(vim.fn.getcompletion("Incomm audience ", "cmdline"), { "agent", "agent+external", "external", "private" })
  T.eq(vim.fn.getcompletion("Incomm audience ex", "cmdline"), { "external" })
  T.ok(vim.tbl_contains(vim.fn.getcompletion("Incomm audi", "cmdline"), "audience"))
  T.eq(vim.fn.getcompletion("Incomm reply ", "cmdline"), {}, "other subcommands take no argument")
end)

T.test("with replies the picker lists the comments, and only the chosen one moves", function()
  T.with_tmpdir(function(dir)
    local bufnr, svc = open_fixture(dir)
    local note = svc:add_note("src/main.go", 4, 4, "root comment")
    svc:add_reply(note.id, "the agent's answer", "agent", "Opus 5")
    local reply_id = svc:find(note.id).replies[1].id
    track.refresh(bufnr)
    vim.api.nvim_win_set_cursor(0, { 4, 0 })

    with_ui(function(items)
      return items[2]
    end, function(calls)
      vim.cmd("Incomm audience")
      T.eq(#calls, 1)
      local items = calls[1].items
      T.eq(#items, 3, "the root, the reply, and the whole thread")
      T.ok(items[1].label:find("root comment", 1, true) and items[1].label:find("[agent]", 1, true), items[1].label)
      T.ok(items[2].label:find("Agent (Opus 5)", 1, true) and items[2].label:find("the agent's answer", 1, true), items[2].label)
      T.ok(items[2].label:find("^  "), "replies are indented under the root")
      T.eq(items[3].whole, true)
      T.eq(items[3].label, "whole thread")
    end)
    T.eq(svc:find(note.id).replies[1].audience, "agent+external", "the reply moved one step")
    T.eq(svc:find(note.id).audience, "agent", "the root did not")
    T.eq(svc:find(note.id).replies[1].id, reply_id)

    -- The root can be chosen too, and cancelling changes nothing.
    with_ui(function(items)
      return items[1]
    end, function()
      vim.cmd("Incomm audience")
    end)
    T.eq(svc:find(note.id).audience, "agent+external")
    with_ui(function()
      return nil
    end, function()
      vim.cmd("Incomm audience")
    end)
    T.eq(svc:find(note.id).audience, "agent+external")
    T.eq(svc:find(note.id).replies[1].audience, "agent+external")
  end)
end)

T.test("the whole-thread entry steps from the root's audience and applies it to every comment", function()
  T.with_tmpdir(function(dir)
    local bufnr, svc = open_fixture(dir)
    local note = svc:add_note("src/main.go", 4, 4, "root")
    svc:add_reply(note.id, "reply")
    svc:set_audience(note.id, svc:find(note.id).replies[1].id, "private")
    track.refresh(bufnr)
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    with_ui(function(items)
      return items[#items]
    end, function()
      vim.cmd("Incomm audience")
    end)
    local after = svc:find(note.id)
    T.eq({ after.audience, after.replies[1].audience }, { "agent+external", "agent+external" })
  end)
end)

-- ---- the explorer ---------------------------------------------------------------------

T.test("the explorer's a changes the selected thread and its detail pane shows the badge", function()
  T.with_tmpdir(function(dir)
    local _, svc = open_fixture(dir)
    local note = svc:add_note("src/main.go", 4, 4, "root")
    explorer.filters = { open = true, resolved = false, orphaned = true }
    -- The detail pane is a fraction of the screen; give it room for the whole badge.
    local columns, lines = vim.o.columns, vim.o.lines
    vim.o.columns, vim.o.lines = 200, 50
    explorer.open(svc)
    local self = explorer.current()
    T.ok(self, "an explorer is on screen")

    local function detail()
      return table.concat(vim.api.nvim_buf_get_lines(self.bufs.detail, 0, -1, false), "\n")
    end
    T.ok(not detail():find("external", 1, true), "nothing to say about a plain agent comment")

    with_ui(no_picker, function()
      feed("a")
      T.eq(svc:find(note.id).audience, "agent+external")
      vim.wait(2000, function()
        return detail():find("agent + external · not published", 1, true) ~= nil
      end, 10)
      T.ok(detail():find("agent + external · not published", 1, true), "the pane follows: " .. detail())

      svc:add_reply(note.id, "one more")
      vim.wait(2000, function()
        return detail():find("one more", 1, true) ~= nil
      end, 10)
      -- With a reply, the same key opens the picker.
      with_ui(function(items)
        return items[2]
      end, function(calls)
        feed("a")
        T.eq(#calls, 1)
      end)
    end)
    T.eq(svc:find(note.id).replies[1].audience, "agent+external")
    if explorer.current() then
      explorer.close(explorer.current())
    end
    vim.o.columns, vim.o.lines = columns, lines
  end)
end)

T.test("in a narrow explorer the badge shrinks instead of pushing the box out", function()
  T.with_tmpdir(function(dir)
    local _, svc = open_fixture(dir)
    local note = svc:add_note("src/main.go", 4, 4, "root")
    svc:set_audience(note.id, nil, "agent+external")
    explorer.filters = { open = true, resolved = false, orphaned = true }
    local columns, lines = vim.o.columns, vim.o.lines
    vim.o.columns, vim.o.lines = 80, 24
    explorer.open(svc)
    local self = explorer.current()
    local rows = vim.api.nvim_buf_get_lines(self.bufs.detail, 0, -1, false)
    local widths, header = {}, nil
    for _, row in ipairs(rows) do
      if row:find("╭", 1, true) or row:find("│", 1, true) or row:find("╰", 1, true) then
        widths[#widths + 1] = vim.fn.strdisplaywidth(row)
      end
      if row:find("Fixture User", 1, true) then
        header = row
      end
    end
    T.ok(header and header:find("external", 1, true), "some form of the badge is there: " .. tostring(header))
    for _, w in ipairs(widths) do
      T.eq(w, widths[1], "every row of the box is as wide as its top")
    end
    explorer.close(self)
    vim.o.columns, vim.o.lines = columns, lines
  end)
end)

T.test("the explorer's help lists a", function()
  T.with_tmpdir(function(dir)
    local _, svc = open_fixture(dir)
    svc:add_note("src/main.go", 4, 4, "root")
    explorer.filters = { open = true, resolved = false, orphaned = true }
    explorer.open(svc)
    explorer.help(explorer.current())
    local found
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
        if line:find("change who sees a comment", 1, true) then
          found = true
        end
      end
    end
    T.ok(found, "the help names the key")
    feed("q") -- closes the help
    if explorer.current() then
      explorer.close(explorer.current())
    end
  end)
end)
