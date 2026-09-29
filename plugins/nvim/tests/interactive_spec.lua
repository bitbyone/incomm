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

T.test("the composer is exactly as wide as the bubble it becomes", function()
  T.with_tmpdir(function(dir)
    local config = require("incomm.config")
    open_fixture(dir)

    ---@return integer total including borders
    local function composer_total()
      local win = composer_win()
      local cfg = vim.api.nvim_win_get_config(win)
      return cfg.width + 2 -- the border sits outside the window's columns
    end

    config.options.card.width = 60
    actions.start_thread()
    T.eq(composer_total(), 60, "follows card.width by default")
    feed("<Esc>")

    -- An explicit width wins, and means the same thing: outer columns.
    config.options.composer.width = 40
    actions.start_thread()
    T.eq(composer_total(), 40)
    feed("<Esc>")

    -- Never wider than the editor, whatever it is asked for.
    config.options.composer.width = 10000
    actions.start_thread()
    T.ok(composer_total() <= vim.o.columns, "clamped to " .. vim.o.columns)
    feed("<Esc>")

    config.options.composer.width = config.defaults.composer.width
    config.options.card.width = config.defaults.card.width
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

    -- Both comments are the user's, so the comment dialog asks which one --
    -- in navigation mode: <CR> takes the selected one, the original.
    actions.edit()
    local dialog = require("incomm.ui.comments").current()
    T.ok(dialog, "the dialog asks which comment")
    T.eq(#dialog.rows, 2)
    T.eq(vim.fn.mode(), "n", "it opens in navigation mode, not a prompt")
    feed("<CR>")
    T.eq(require("incomm.ui.comments").current(), nil, "and closes on the choice")
    local win, buf = composer_win()
    T.ok(win, "composer opened for the edit")
    T.eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "original" }, "prefilled with the current text")
    compose("original, revised")

    T.eq(svc:all_notes()[1].content, "original, revised")
    T.eq(#svc:all_notes()[1].replies, 1, "the reply is untouched")
  end)
end)

T.test("the edit dialog lists only your comments, j picks a reply, Esc changes nothing", function()
  T.with_tmpdir(function(dir)
    local bufnr, svc = open_fixture(dir)
    local note = svc:add_note("src/main.go", 4, 4, "mine")
    svc:add_reply(note.id, "the agent's", "agent", "Opus 5")
    svc:add_reply(note.id, "mine again")
    track.refresh(bufnr)
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    local comments = require("incomm.ui.comments")

    actions.edit()
    T.eq(vim.tbl_map(function(r) return r.content end, comments.current().rows), { "mine", "mine again" })
    feed("<Esc>")
    T.eq(comments.current(), nil)
    T.eq(composer_win(), nil, "cancelled: no composer")

    actions.edit()
    feed("j<CR>")
    local _, buf = composer_win()
    T.eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "mine again" }, "the reply, not the original")
    compose("revised")
    local stored = svc:find(note.id)
    T.eq({ stored.content, stored.replies[1].content, stored.replies[2].content }, { "mine", "the agent's", "revised" })
  end)
end)

T.test("the explorer's e asks which of your comments, like :Incomm edit", function()
  T.with_tmpdir(function(dir)
    local _, svc = open_fixture(dir)
    local note = svc:add_note("src/main.go", 4, 4, "first")
    svc:add_reply(note.id, "second")
    local explorer = require("incomm.ui.explorer")
    explorer.filters = { open = true, resolved = false, orphaned = true }
    explorer.open(svc)
    feed("e")
    local comments = require("incomm.ui.comments")
    T.ok(comments.current(), "the dialog, not straight into the first comment")
    feed("j<CR>")
    local _, buf = composer_win()
    T.eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "second" })
    compose("second, revised")
    T.eq(svc:find(note.id).replies[1].content, "second, revised")
    if explorer.current() then
      explorer.close(explorer.current())
    end
  end)
end)

T.test("delete-comment picks the message in the same dialog", function()
  T.with_tmpdir(function(dir)
    local bufnr, svc = open_fixture(dir)
    local note = svc:add_note("src/main.go", 4, 4, "root")
    svc:add_reply(note.id, "keep")
    svc:add_reply(note.id, "drop")
    track.refresh(bufnr)
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    actions.delete_comment()
    feed("jj<CR>")
    T.eq(vim.tbl_map(function(r) return r.content end, svc:find(note.id).replies), { "keep" })
    actions.delete_comment()
    feed("<CR>")
    T.eq(svc:find(note.id), nil, "the original takes the thread with it")
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

-- ---- thread details ---------------------------------------------------------

--- Give a comment a `source`, as an import from the forge or a publish would.
local function publish(comment, id)
  comment.source = { id = id, url = "https://forge/mr/7#note_" .. id }
  comment.audience = "agent+external"
end

T.test(":Incomm list opens thread details: h/l audience, e edit, d delete", function()
  T.with_tmpdir(function(dir)
    local bufnr, svc = open_fixture(dir)
    local note = svc:add_note("src/main.go", 4, 4, "root")
    svc:add_reply(note.id, "first")
    svc:add_reply(note.id, "second")
    track.refresh(bufnr)
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    local thread = require("incomm.ui.thread")

    vim.cmd("Incomm list")
    local d = thread.current()
    T.ok(d, "thread details are open")
    T.ok(vim.api.nvim_win_get_config(d.win).title[1][1]:find("thread details", 1, true), "and say so")
    T.eq(vim.fn.mode(), "n")

    feed("jl")
    T.eq(svc:find(note.id).replies[1].audience, "agent+external", "l steps the audience")

    -- e: the composer, then the dialog again on the same comment.
    feed("e")
    local _, buf = composer_win()
    T.eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "first" })
    compose("first, revised")
    vim.wait(1000, function() return thread.current() ~= nil end, 10)
    T.eq(svc:find(note.id).replies[1].content, "first, revised")
    T.ok(thread.current(), "back in thread details")
    T.eq(thread.current().index, 2, "on the comment just edited")

    -- d: a reply goes, the dialog stays.
    feed("jd")
    T.eq(vim.tbl_map(function(r) return r.content end, svc:find(note.id).replies), { "first, revised" })
    T.ok(thread.current(), "still open")
    -- ...and the thread's own comment takes the thread and the dialog with it.
    feed("ggd")
    T.eq(svc:find(note.id), nil)
    T.eq(thread.current(), nil)
  end)
end)

T.test("what is on the merge request is neither edited nor deleted", function()
  T.with_tmpdir(function(dir)
    local bufnr, svc = open_fixture(dir)
    local note = svc:add_note("src/main.go", 4, 4, "mine")
    svc:add_reply(note.id, "from the MR", "user", "Reviewer")
    svc:add_reply(note.id, "mine too")
    local live = svc:find(note.id)
    publish(live.replies[1], 501)
    track.refresh(bufnr)
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    local warnings = {}
    local notify = vim.notify
    vim.notify = function(msg, level)
      if level == vim.log.levels.WARN then
        warnings[#warnings + 1] = msg
      end
    end
    local ok, err = pcall(function()
      -- The service refuses, whatever calls it.
      local reply_id = live.replies[1].id
      T.ok(not svc:update_reply(note.id, reply_id, "changed"))
      T.ok(not svc:remove_reply(note.id, reply_id))
      T.ok(not svc:remove_note(note.id), "the root would take the published reply with it")
      T.eq(svc:find(note.id).replies[1].content, "from the MR")

      -- The dialog says why instead.
      vim.cmd("Incomm list")
      local thread = require("incomm.ui.thread")
      T.ok(table.concat(vim.api.nvim_buf_get_lines(thread.current().buf, 0, -1, false), "\n"):find("on the MR", 1, true),
        "the published comment is marked")
      feed("je")
      T.eq(composer_win(), nil, "no composer")
      feed("d")
      T.eq(#svc:find(note.id).replies, 2, "nothing deleted")
      feed("kd")
      T.ok(svc:find(note.id), "the thread stays")
      T.eq(#warnings, 3, vim.inspect(warnings))
      T.ok(warnings[1]:find("merge request", 1, true), warnings[1])
      feed("jjd")
      T.eq(#svc:find(note.id).replies, 1, "an unpublished reply still goes")
      feed("<Esc>")

      -- The commands: edit skips it, delete refuses the thread.
      actions.edit()
      local _, buf = composer_win()
      T.eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "mine" }, "only the root is left to edit")
      compose("mine, revised")
      actions.delete_thread()
      T.ok(svc:find(note.id), "delete refuses a thread with a published reply")
    end)
    vim.notify = notify
    if not ok then
      error(err, 0)
    end
  end)
end)

T.test(":Incomm thread <audience> starts a thread only its audience sees", function()
  T.with_tmpdir(function(dir)
    local _, svc = open_fixture(dir)
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    vim.cmd("Incomm thread private")
    local win = composer_win()
    T.ok(vim.api.nvim_win_get_config(win).title[1][1]:find("private", 1, true), "the composer says who will see it")
    compose("a note to self")
    T.eq(svc:all_notes()[1].audience, "private")

    vim.cmd("3,4Incomm thread agent+external")
    compose("for the MR")
    local note = svc:all_notes()[2]
    T.eq({ note.audience, note.startLine, note.endLine }, { "agent+external", 3, 4 }, "a range and an audience together")

    vim.cmd("Incomm thread")
    compose("plain")
    T.eq(svc:all_notes()[3].audience, "agent", "none given: the default")

    local notify = vim.notify
    local said
    vim.notify = function(msg) said = msg end
    vim.cmd("Incomm thread nonsense")
    vim.notify = notify
    T.eq(composer_win(), nil, "a name that is not an audience opens nothing")
    T.ok(said and said:find("must be one of", 1, true), tostring(said))

    -- A mapping can pass it straight to the action, too.
    actions.start_thread(nil, nil, "external")
    compose("hidden from the agent")
    T.eq(svc:all_notes()[4].audience, "external")
  end)
end)

T.test(":Incomm reply <audience> answers for that audience only", function()
  T.with_tmpdir(function(dir)
    local bufnr, svc = open_fixture(dir)
    local note = svc:add_note("src/main.go", 4, 4, "root")
    svc:set_audience(note.id, nil, "agent+external")
    track.refresh(bufnr)
    vim.api.nvim_win_set_cursor(0, { 4, 0 })

    vim.cmd("Incomm reply private")
    T.ok(vim.api.nvim_win_get_config((composer_win())).title[1][1]:find("· private", 1, true), "the composer says so")
    compose("an aside")
    vim.cmd("Incomm reply")
    compose("inherits")
    vim.cmd("Incomm reply external")
    compose("for the MR only")
    local replies = svc:find(note.id).replies
    T.eq(vim.tbl_map(function(r) return r.audience end, replies), { "private", "agent+external", "external" })

    -- It reaches the file as it is, not as the default.
    svc:reload({ publish = false })
    T.eq(svc:find(note.id).replies[1].audience, "private")

    local notify = vim.notify
    local said
    vim.notify = function(msg) said = msg end
    vim.cmd("Incomm reply nonsense")
    vim.notify = notify
    T.eq(composer_win(), nil)
    T.ok(said and said:find("must be one of", 1, true), tostring(said))
  end)
end)

T.test("the keymap set starts and answers threads for each audience on two keys", function()
  local saved = vim.g.mapleader
  vim.g.mapleader = " "
  incomm.setup({ watch = false, keymaps = { prefix = "<leader>i" } })
  local want = {
    ["<leader>icc"] = ":Incomm thread<cr>",
    ["<leader>icp"] = ":Incomm thread private<cr>",
    ["<leader>irr"] = "<cmd>Incomm reply<cr>",
    ["<leader>irp"] = "<cmd>Incomm reply private<cr>",
    ["<leader>ire"] = "<cmd>Incomm reply external<cr>",
    ["<leader>irb"] = "<cmd>Incomm reply agent+external<cr>",
  }
  for lhs, rhs in pairs(want) do
    T.eq(vim.fn.maparg(lhs, "n"):lower(), rhs:lower(), lhs)
  end
  T.eq(vim.fn.maparg("<leader>ic", "n"), "", "nothing waits on a single key")
  T.eq(vim.fn.maparg("<leader>ir", "n"), "")
  for lhs in pairs(want) do
    pcall(vim.keymap.del, "n", lhs)
  end
  vim.g.mapleader = saved
end)

service.reset()
