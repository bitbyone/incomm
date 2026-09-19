-- The interactive surfaces: the composer, the `:Incomm` command, and the
-- watcher that picks up what the agent writes while the editor is open.
--
-- Keys are fed through `nvim_feedkeys` in "x" (execute now) mode, so these
-- exercise the real mappings rather than calling the callbacks directly.

local T = _G.T
local incomm = require("incomm")
local service = require("incomm.service")
local track = require("incomm.track")
local actions = require("incomm.actions")
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
---@param opts? table
---@return integer bufnr, incomm.Service
local function open_fixture(dir, opts)
  service.reset()
  ui_state.reset()
  make_repo(dir)
  vim.cmd("silent! %bwipeout!")
  vim.cmd.cd(dir)
  incomm.setup(vim.tbl_extend("force", { watch = false, reanchor_delay = 10 }, opts or {}))
  vim.cmd.edit(dir .. "/src/main.go")
  local bufnr = vim.api.nvim_get_current_buf()
  local t = track.attach(bufnr)
  return bufnr, t.svc
end

---@param keys string
local function feed(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end

--- The composer window, if one is open.
---@return integer?, integer?
local function composer_win()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.b[buf].incomm_composer then
      return win, buf
    end
  end
end

--- Type `text` into the open composer and save it with the real keymap.
---@param text string
local function compose(text)
  local win, buf = composer_win()
  T.ok(win, "the composer is open")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text, "\n", { plain = true }))
  feed("<C-s>")
  T.eq(composer_win(), nil, "the composer closed")
end

T.test("the composer writes a thread on the cursor line", function()
  T.with_tmpdir(function(dir)
    local _, svc = open_fixture(dir)
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    actions.start_thread()
    compose("please add error handling")

    T.eq(#svc:all_notes(), 1)
    local note = svc:all_notes()[1]
    T.eq(note.startLine, 4)
    T.eq(note.endLine, 4)
    T.eq(note.content, "please add error handling")
    T.eq(note.author, "user", "comments made in the editor are the human's")
  end)
end)

T.test(":'<,'>Incomm thread anchors to the selected range", function()
  T.with_tmpdir(function(dir)
    local _, svc = open_fixture(dir)
    vim.cmd("4,6Incomm thread")
    compose("this whole block")

    local note = svc:all_notes()[1]
    T.eq({ note.startLine, note.endLine }, { 4, 6 })
    T.eq(note.anchor.startPrefix, "func main() {")
    T.eq(note.anchor.endPrefix, "}")
  end)
end)

T.test("a visual selection becomes the thread's range", function()
  T.with_tmpdir(function(dir)
    local _, svc = open_fixture(dir)
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    feed("V2j")
    actions.start_thread()
    compose("this whole block")
    local note = svc:all_notes()[1]
    T.eq({ note.startLine, note.endLine }, { 4, 6 }, "the selected lines, not the cursor line")
  end)
end)

T.test("cancelling the composer leaves nothing behind", function()
  T.with_tmpdir(function(dir)
    local _, svc = open_fixture(dir)
    actions.start_thread()
    local _, buf = composer_win()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "never mind" })
    feed("<Esc>")
    T.eq(composer_win(), nil, "closed")
    T.eq(#svc:all_notes(), 0, "no thread was written")
  end)
end)

T.test("saving from insert mode does not leave the code buffer inserting", function()
  T.with_tmpdir(function(dir)
    local _, svc = open_fixture(dir)
    actions.start_thread()
    local _, cbuf = composer_win()
    vim.api.nvim_buf_set_lines(cbuf, 0, -1, false, { "typed while inserting" })
    vim.cmd.startinsert()
    feed("<C-s>")
    T.eq(composer_win(), nil, "composer closed")
    T.ok(not vim.fn.mode():match("^i"), "back in normal mode, got: " .. vim.fn.mode())
    T.eq(#svc:all_notes(), 1)
  end)
end)

T.test("every configured save key saves, and Cmd-Enter is one of them", function()
  T.with_tmpdir(function(dir)
    local _, svc = open_fixture(dir)
    local keys = require("incomm.config").options.composer.save
    T.ok(vim.tbl_contains(keys, "<D-CR>"), "Cmd-Enter, the key the IDE uses")

    actions.start_thread()
    local _, cbuf = composer_win()
    -- Every save key is bound in both modes, whether or not this terminal can
    -- deliver it; the mapping is what a capable one will find.
    local bound = {}
    for _, mode in ipairs({ "n", "i" }) do
      for _, m in ipairs(vim.api.nvim_buf_get_keymap(cbuf, mode)) do
        bound[m.lhs:upper() .. ":" .. mode] = true
      end
    end
    for _, key in ipairs(keys) do
      for _, mode in ipairs({ "n", "i" }) do
        T.ok(bound[key:upper() .. ":" .. mode], key .. " is mapped in " .. mode)
      end
    end

    vim.api.nvim_buf_set_lines(cbuf, 0, -1, false, { "saved with a key" })
    feed("<C-s>")
    T.eq(svc:all_notes()[1].content, "saved with a key")
  end)
end)

T.test("an empty comment is not saved", function()
  T.with_tmpdir(function(dir)
    local _, svc = open_fixture(dir)
    actions.start_thread()
    compose("   ")
    T.eq(#svc:all_notes(), 0)
  end)
end)

T.test("multi-line markdown survives the round trip", function()
  T.with_tmpdir(function(dir)
    local _, svc = open_fixture(dir)
    actions.start_thread()
    compose("first line\n\n- a bullet\n- another")
    T.eq(svc:all_notes()[1].content, "first line\n\n- a bullet\n- another")
  end)
end)

T.test("reply and edit go through the composer too", function()
  T.with_tmpdir(function(dir)
    local _, svc = open_fixture(dir)
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    actions.start_thread()
    compose("original")

    actions.reply()
    compose("a reply")
    local note = svc:all_notes()[1]
    T.eq(#note.replies, 1)
    T.eq(note.replies[1].content, "a reply")
    T.eq(note.replies[1].author, "user")

    -- Editing the original: the composer opens prefilled, and only user
    -- comments are offered (the reply here is the user's too, so picking is
    -- needed -- drive it through vim.ui.select's default).
    local original_select = vim.ui.select
    vim.ui.select = function(items, _, on_choice)
      on_choice(items[1]) -- the original comment
    end
    actions.edit()
    local win, buf = composer_win()
    T.ok(win, "composer opened for the edit")
    T.eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "original" }, "prefilled with the current text")
    compose("original, revised")
    vim.ui.select = original_select

    T.eq(svc:all_notes()[1].content, "original, revised")
    T.eq(#svc:all_notes()[1].replies, 1, "the reply is untouched")
  end)
end)

T.test("agent comments are not editable", function()
  T.with_tmpdir(function(dir)
    local bufnr, svc = open_fixture(dir)
    svc:add_note("src/main.go", 4, 4, "agent remark", "agent", "Opus 5")
    track.refresh(bufnr)
    vim.api.nvim_win_set_cursor(0, { 4, 0 })

    actions.edit()
    T.eq(composer_win(), nil, "no composer for someone else's words")
  end)
end)

T.test(":Incomm subcommands drive the same actions", function()
  T.with_tmpdir(function(dir)
    local bufnr, svc = open_fixture(dir)
    local note = svc:add_note("src/main.go", 4, 4, "a thread")
    track.refresh(bufnr)
    vim.api.nvim_win_set_cursor(0, { 4, 0 })

    vim.cmd("Incomm resolve")
    T.eq(svc:find(note.id).resolved, true)
    vim.cmd("Incomm resolve")
    T.eq(svc:find(note.id).resolved, false)

    vim.cmd("Incomm toggle")
    T.eq(ui_state.is_hidden(note.id), true)
    vim.cmd("Incomm toggle")
    T.eq(ui_state.is_hidden(note.id), false)

    vim.cmd("Incomm delete")
    T.eq(svc:find(note.id), nil)
  end)
end)

T.test(":IncommWidth changes the bubble width for the session", function()
  T.with_tmpdir(function(dir)
    local bufnr, svc = open_fixture(dir)
    local config = require("incomm.config")
    local render = require("incomm.ui.render")
    config.options.state_file = dir .. "/state/card-width" -- never the real one
    svc:add_note("src/main.go", 4, 4, "a thread")
    require("incomm.track").refresh(bufnr)

    ---@return integer
    local function drawn_width()
      local card = vim.api.nvim_buf_get_extmarks(bufnr, render.ns, 0, -1, { details = true })[1][4].virt_lines
      local width = 0
      for _, chunk in ipairs(card[2]) do -- the box's top edge
        width = width + vim.fn.strdisplaywidth(chunk[1])
      end
      return width
    end

    vim.cmd("IncommWidth 44")
    T.eq(config.options.card.width, 44)
    T.eq(drawn_width(), 44, "the cards redrew at the new width")

    vim.cmd("IncommWidth 30")
    T.eq(drawn_width(), 30)

    -- Nonsense is refused, and leaves the width alone.
    vim.cmd("IncommWidth 4")
    T.eq(config.options.card.width, 30, "too narrow to hold a bubble")
    vim.cmd("IncommWidth nope")
    T.eq(config.options.card.width, 30, "not a number")

    vim.cmd("IncommWidth reset")
    T.eq(config.options.card.width, config.defaults.card.width, "back to the configured default")
  end)
end)

T.test("IncommWidth! remembers the width, and reset forgets it", function()
  T.with_tmpdir(function(dir)
    local _, svc = open_fixture(dir)
    local config = require("incomm.config")
    local state = dir .. "/state/card-width"
    config.options.state_file = state

    vim.cmd("IncommWidth! 52")
    T.eq(vim.fn.filereadable(state), 1, "it was written down")
    T.eq(config.load_width(), 52)

    -- A new session reads it back and it wins over the configured default.
    require("incomm").setup({ watch = false, state_file = state, card = { width = 80 } })
    T.eq(config.options.card.width, 52, "the remembered width survived setup")

    vim.cmd("IncommWidth! reset")
    T.eq(vim.fn.filereadable(state), 0, "forgotten")
    require("incomm").setup({ watch = false, state_file = state, card = { width = 80 } })
    T.eq(config.options.card.width, 80, "the config is back in charge")
  end)
end)

T.test(":Incomm completes its subcommands", function()
  local completions = vim.fn.getcompletion("Incomm ", "cmdline")
  T.ok(vim.tbl_contains(completions, "thread"), "thread")
  T.ok(vim.tbl_contains(completions, "explorer"), "explorer")
  T.ok(vim.tbl_contains(completions, "toggle-resolved"), "toggle-resolved")
  T.ok(vim.tbl_contains(completions, "reanchor"), "reanchor")
end)

T.test("a thread written from outside shows up while the buffer is open", function()
  T.with_tmpdir(function(dir)
    local bufnr, svc = open_fixture(dir, { watch = true })
    require("incomm.watch").start()

    -- Someone else writes the notes file (this is what `incomm add` does).
    local other = require("incomm.store").open(dir)
    local disk = other:load()
    table.insert(disk.notes, {
      id = "outside1",
      file = "src/main.go",
      startLine = 5,
      endLine = 5,
      anchor = require("incomm.anchor").compute(SOURCE, 5, 5),
      content = "from outside",
      resolved = false,
      orphaned = false,
      author = "agent",
      authorTitle = "Opus 5",
      createdAt = require("incomm.model").now_utc(),
      updatedAt = require("incomm.model").now_utc(),
      replies = {},
    })
    other:save(disk)

    local appeared = vim.wait(15000, function()
      return svc:find("outside1") ~= nil
    end, 25)
    T.ok(appeared, "the watcher reloaded the file on its own")

    -- And it is drawn, without anyone touching the buffer.
    track.refresh(bufnr)
    local ui = vim.api.nvim_buf_get_extmarks(bufnr, require("incomm.ui.render").ns, 0, -1, { details = true })
    T.eq(#ui, 1)
    T.eq(ui[1][2], 4, "on line 5")
    require("incomm.watch").stop()
  end)
end)

T.test("a project with no .incomm/ yet is watched until it appears", function()
  T.with_tmpdir(function(dir)
    local watch = require("incomm.watch")
    local _, svc = open_fixture(dir, { watch = true })
    watch.start()

    -- Nothing has been written, so there is no directory to watch yet: the
    -- root event announcing it arrives once and can be missed, so a slow stat
    -- runs behind it until the real watch is armed.
    local handles = watch.handles[svc.store.root] or {}
    T.eq(handles.notes, nil, "no directory watch yet")
    T.ok(handles.root ~= nil, "the project root is watched for it appearing")
    T.ok(handles.poll ~= nil, "and a fallback timer is running")

    svc:add_note("src/main.go", 4, 4, "the first note")
    handles = watch.handles[svc.store.root] or {}
    T.ok(handles.notes ~= nil, "the directory watch took over on the first write")
    T.eq(handles.poll, nil, "and the fallback stopped")
    T.eq(handles.root, nil, "as did the root watch")
    watch.stop()
  end)
end)

T.test("a branch switch swaps the threads live", function()
  T.with_tmpdir(function(dir)
    local bufnr, svc = open_fixture(dir, { watch = true })
    require("incomm.watch").start()
    svc:add_note("src/main.go", 4, 4, "on main")
    track.refresh(bufnr)
    T.eq(#vim.api.nvim_buf_get_extmarks(bufnr, require("incomm.ui.render").ns, 0, -1, {}), 1)

    vim.fn.writefile({ "ref: refs/heads/feature/x" }, dir .. "/.git/HEAD")
    local switched = vim.wait(15000, function()
      return svc.store.raw_branch == "feature/x"
    end, 25)
    T.ok(switched, "the HEAD watcher noticed")
    track.refresh(bufnr)
    T.eq(#vim.api.nvim_buf_get_extmarks(bufnr, require("incomm.ui.render").ns, 0, -1, {}), 0, "the other branch's cards are gone")
    require("incomm.watch").stop()
  end)
end)

if vim.fn.executable("incomm") == 1 then
  T.test("the agent's CLI reply lands in the open buffer", function()
    T.with_tmpdir(function(dir)
      local bufnr, svc = open_fixture(dir, { watch = true })
      require("incomm.watch").start()
      vim.api.nvim_win_set_cursor(0, { 5, 0 })
      actions.start_thread()
      compose("agent: what does this print?")
      local note = svc:all_notes()[1]

      vim.fn.system({ "incomm", "--root", dir, "reply", note.id, "-c", "it prints hi", "--author-title", "Opus 5" })
      local arrived = vim.wait(15000, function()
        return #(svc:find(note.id) or {}).replies == 1
      end, 25)
      T.ok(arrived, "the reply arrived through the watcher")
      T.eq(svc:find(note.id).replies[1].content, "it prints hi")

      track.refresh(bufnr)
      local card = vim.api.nvim_buf_get_extmarks(bufnr, require("incomm.ui.render").ns, 0, -1, { details = true })[1][4].virt_lines
      local text = table.concat(vim.tbl_map(function(line)
        return table.concat(vim.tbl_map(function(chunk)
          return chunk[1]
        end, line))
      end, card), "\n")
      T.ok(text:find("Agent (Opus 5)", 1, true), "shown as an agent bubble")
      T.ok(text:find("it prints hi", 1, true), "with the reply text")
      require("incomm.watch").stop()
    end)
  end)

  T.test("resolving in the editor is what the agent's CLI sees", function()
    T.with_tmpdir(function(dir)
      local bufnr, svc = open_fixture(dir)
      local note = svc:add_note("src/main.go", 4, 4, "fix this")
      track.refresh(bufnr)
      vim.api.nvim_win_set_cursor(0, { 4, 0 })
      vim.cmd("Incomm resolve")

      local listed = vim.json.decode(vim.fn.system({ "incomm", "--root", dir, "list", "--json" }))
      T.eq(#listed.notes, 1)
      T.eq(listed.notes[1].resolved, true)
      T.eq(listed.notes[1].id, note.id)

      local unresolved = vim.json.decode(vim.fn.system({ "incomm", "--root", dir, "list", "--unresolved", "--json" }))
      T.eq(#(unresolved.notes or {}), 0, "and it drops out of the agent's work queue")
    end)
  end)
end

service.reset()
