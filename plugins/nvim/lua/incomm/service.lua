-- The in-memory notes model and everything that mutates or persists it.
--
-- The Neovim counterpart of `store/NotesService.kt`. Every read and write goes
-- through here, and every change notifies listeners so the editor layer can
-- redraw. Three behaviours are carried over from the IntelliJ plugin because
-- the shared file format demands them (AGENTS.md §7.7, §11.6):
--
--  * **Merge-on-write.** Before saving we reload the file and fold in notes we
--    do not know about -- comments the agent added through the CLI while our
--    model was stale. A plain "serialize my model over the file" write deletes
--    the agent's work.
--  * **Self-write suppression.** We remember the exact bytes we wrote, so the
--    watcher can tell our own write from someone else's and skip the reload
--    (and the redraw it would cause).
--  * **Quiet position writes.** Re-anchoring after an edit persists without
--    notifying: the extmarks already render in the right place, so a redraw
--    would only make the buffer flicker. Listeners are told only when
--    something visible actually changed.
--
-- Unlike the IntelliJ plugin there is no writer thread: Lua in Neovim is
-- single-threaded, and these files are small enough that a synchronous atomic
-- write is not worth the complexity of an async queue.

local anchor = require("incomm.anchor")
local git = require("incomm.git")
local model = require("incomm.model")
local store = require("incomm.store")

local uv = vim.uv or vim.loop

local M = {}

--- `.incomm/<file>` as the messages name it.
---@param st incomm.Store
---@return string
local function model_relative(st)
  return store.DIR_NAME .. "/" .. st:notes_file_name()
end

---@class incomm.Service
---@field store incomm.Store
---@field model incomm.NotesFile
local Service = {}
Service.__index = Service

--- Services by root path. Neovim, unlike IntelliJ, has no "project" -- a single
--- instance can hold buffers from several checkouts -- so one service per
--- discovered root keeps their notes files apart.
---@type table<string, incomm.Service>
local services = {}

--- Create (or return) the service rooted at `root`.
---@param root string
---@param branch? string
---@return incomm.Service
function M.for_root(root, branch)
  root = vim.fn.fnamemodify(root, ":p"):gsub("/+$", "")
  local existing = services[root]
  if existing then
    return existing
  end
  local self = setmetatable({
    store = store.open(root, branch),
    model = model.new_file(),
    change_listeners = {},
    news_listeners = {},
    -- Ids deleted locally whose deletion may not have reached disk yet; the
    -- merge step must not resurrect them from the still-current file.
    locally_deleted = {},
    last_written = nil, ---@type string?
    author_title = nil, ---@type string?
    -- Set while the notes file is in a newer format than this build understands:
    -- nothing is read from it and nothing is written over it.
    blocked = nil, ---@type incomm.Incompat?
    warned = nil, ---@type string? "<path>@<version>" already announced
  }, Service)
  services[self.store.root] = self
  services[root] = self
  self:reload({ publish = false })
  return self
end

--- The service for the current working directory, i.e. "this project".
---@return incomm.Service
function M.primary()
  local cwd = uv.cwd() or "."
  return M.for_root(store.find_existing(cwd) or cwd)
end

--- The service that owns `path`, or nil when the file belongs to no project
--- incomm knows about.
---@param path string
---@return incomm.Service?
function M.for_path(path)
  if path == nil or path == "" then
    return nil
  end
  local abs = vim.fn.fnamemodify(path, ":p")
  local primary = M.primary()
  if primary.store:rel_file(abs) then
    return primary
  end
  local dir = vim.fn.fnamemodify(abs, ":h")
  local root = store.find_existing(dir)
  if root then
    return M.for_root(root)
  end
  return nil
end

--- Called after every successful save. The watcher subscribes so it can arm
--- itself the moment `.incomm/` first appears -- before the first thread exists
--- there is no directory to watch.
---@type fun(svc: incomm.Service)[]
M.saved_listeners = {}

--- Subscribe to "a notes file was just written".
---@param fn fun(svc: incomm.Service)
function M.on_saved(fn)
  table.insert(M.saved_listeners, fn)
end

--- Every live service (used by the watchers and by `:Incomm reload`).
---@return incomm.Service[]
function M.all()
  local seen, out = {}, {}
  for _, svc in pairs(services) do
    if not seen[svc] then
      seen[svc] = true
      out[#out + 1] = svc
    end
  end
  return out
end

--- Drop every service (tests, and `:Incomm reload` after a root change).
function M.reset()
  for _, svc in ipairs(M.all()) do
    if svc.stop_watching then
      svc:stop_watching()
    end
  end
  services = {}
end

-- ---- events ---------------------------------------------------------------

--- Subscribe to "the model changed, redraw". Returns an unsubscribe function.
---@param fn fun(self: incomm.Service)
---@return fun()
function Service:on_change(fn)
  table.insert(self.change_listeners, fn)
  return function()
    for i, f in ipairs(self.change_listeners) do
      if f == fn then
        table.remove(self.change_listeners, i)
        return
      end
    end
  end
end

--- Subscribe to "new agent-authored content arrived from outside".
---@param fn fun(news: incomm.AgentNews[])
function Service:on_agent_news(fn)
  table.insert(self.news_listeners, fn)
end

function Service:publish_changed()
  for _, fn in ipairs(vim.list_slice(self.change_listeners)) do
    local ok, err = pcall(fn, self)
    if not ok then
      vim.notify("incomm: listener failed: " .. tostring(err), vim.log.levels.WARN)
    end
  end
end

-- ---- reads ----------------------------------------------------------------

---@return incomm.Note[]
function Service:all_notes()
  return self.model.notes
end

--- Set who may see one comment: the thread's own (`reply_id` nil) or a reply.
--- The default audience is stored as `agent`, like any other, so the file stays
--- what the CLI would have written.
---@param note_id string
---@param reply_id string? nil for the thread's first comment
---@param audience string private | agent | external | agent+external
---@return boolean changed
function Service:set_audience(note_id, reply_id, audience)
  if self.blocked or model.normalize_audience(audience) ~= audience then
    return false
  end
  local hit = false
  self:mutate(note_id, function(note)
    local target = note
    if reply_id then
      target = nil
      for _, reply in ipairs(note.replies) do
        if reply.id == reply_id then
          target = reply
        end
      end
    end
    if target then
      target.audience = model.stored_audience(audience)
      note.updatedAt = model.now_utc()
      hit = true
    end
  end)
  return hit
end

--- Set the audience of every comment in a thread in one write.
---@param note_id string
---@param audience string
---@return boolean changed
function Service:set_thread_audience(note_id, audience)
  if self.blocked or model.normalize_audience(audience) ~= audience then
    return false
  end
  return self:mutate(note_id, function(note)
    local stored = model.stored_audience(audience)
    note.audience = stored
    for _, reply in ipairs(note.replies) do
      reply.audience = stored
    end
    note.updatedAt = model.now_utc()
  end)
end

---@param rel string
---@return incomm.Note[]
function Service:notes_for_file(rel)
  local out = {}
  for _, note in ipairs(self.model.notes) do
    if note.file == rel then
      out[#out + 1] = note
    end
  end
  return out
end

---@param id string
---@return incomm.Note?
function Service:find(id)
  return model.find(self.model, id)
end

---@return boolean
function Service:is_empty()
  return #self.model.notes == 0
end

--- The note whose range covers `line` in `rel`, preferring the innermost one
--- (the tightest range wins when threads overlap).
---@param rel string
---@param line integer 1-based
---@return incomm.Note?
function Service:note_at(rel, line)
  local best
  for _, note in ipairs(self.model.notes) do
    if note.file == rel then
      local start_line, end_line = note.startLine, note.endLine
      if note.orphaned and not note.resolved then
        -- Orphaned notes float to line 1 for display; match them there too.
        start_line, end_line = 1, 1
      end
      if line >= start_line and line <= end_line then
        if not best or (end_line - start_line) < (best.endLine - best.startLine) then
          best = note
        end
      end
    end
  end
  return best
end

--- Current lines of a project file: the buffer's when one is loaded (unsaved
--- edits included -- that is what the user sees), otherwise what is on disk.
---@param rel string
---@return string[]?
function Service:lines_for(rel)
  local abs = self.store:abs_file(rel)
  local bufnr = vim.fn.bufnr(abs)
  if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
    return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  end
  return self.store:read_lines(rel)
end

--- Display name for comments this editor writes.
---@return string
function Service:default_author_title()
  if not self.author_title then
    local configured = require("incomm.config").options.author_title
    local ok, passwd = pcall(uv.os_get_passwd)
    self.author_title = configured
      or git.detect_user_name(self.store.root)
      or (ok and passwd and passwd.username)
      or vim.env.USER
      or "User"
  end
  return self.author_title
end

-- ---- lifecycle ------------------------------------------------------------

---@class incomm.AgentNews
---@field file string
---@field startLine integer
---@field content string
---@field is_reply boolean

--- Every agent-authored note or reply present in `new` but absent from `old`.
--- A port of `AgentNotifier.diff`.
---@param old incomm.NotesFile
---@param new incomm.NotesFile
---@return incomm.AgentNews[]
function M.diff_agent_news(old, new)
  local old_notes, old_replies = {}, {}
  for _, note in ipairs(old.notes) do
    old_notes[note.id] = true
    local ids = {}
    for _, reply in ipairs(note.replies) do
      ids[reply.id] = true
    end
    old_replies[note.id] = ids
  end

  local out = {}
  for _, note in ipairs(new.notes) do
    if not old_notes[note.id] then
      if note.author == model.AUTHOR_AGENT then
        out[#out + 1] = { file = note.file, startLine = note.startLine, content = note.content, is_reply = false }
      end
    else
      local known = old_replies[note.id] or {}
      for _, reply in ipairs(note.replies) do
        if not known[reply.id] and reply.author == model.AUTHOR_AGENT then
          out[#out + 1] = { file = note.file, startLine = note.startLine, content = reply.content, is_reply = true }
        end
      end
    end
  end
  return out
end

--- Reload from disk. Skips the notification when the file already matches
--- memory (our own write, or a no-op touch), so self-writes never cause a
--- refresh loop.
---@param opts? { publish?: boolean }
---@return boolean changed
function Service:reload(opts)
  opts = opts or {}
  local publish = opts.publish ~= false
  local loaded, err, incompat = self.store:load()
  if incompat then
    return self:block(incompat, publish)
  end
  if self.blocked then
    self.blocked = nil
    self.warned = nil
  end
  if err then
    vim.notify("incomm: could not read " .. self.store:notes_path() .. ": " .. err, vim.log.levels.WARN)
    return false
  end

  -- Don't resurrect notes deleted locally but not yet flushed.
  if next(self.locally_deleted) then
    local kept = {}
    for _, note in ipairs(loaded.notes) do
      if not self.locally_deleted[note.id] then
        kept[#kept + 1] = note
      end
    end
    loaded.notes = kept
  end

  if vim.deep_equal(self.model, loaded) then
    return false
  end

  local news = M.diff_agent_news(self.model, loaded)
  self.model = loaded
  if publish then
    self:publish_changed()
    if #news > 0 then
      for _, fn in ipairs(self.news_listeners) do
        pcall(fn, news)
      end
    end
  end
  return true
end

--- Refuse a notes file written in a newer format: empty the model so no card
--- is drawn from it, tell the user once per file and version, and stop writes.
---@param incompat incomm.Incompat
---@param publish boolean
---@return boolean changed
function Service:block(incompat, publish)
  local path = self.store:notes_path()
  local key = path .. "@" .. incompat.found
  local already = self.blocked ~= nil and self.warned == key
  local had_notes = #self.model.notes > 0
  self.blocked = incompat
  self.model = model.new_file()
  self.locally_deleted = {}
  self.last_written = nil
  if not already then
    self.warned = key
    vim.notify(self:blocked_message(), vim.log.levels.ERROR)
  end
  if publish and had_notes then
    self:publish_changed()
  end
  return had_notes
end

--- Why nothing can be read or written, in the words the user needs.
---@return string
function Service:blocked_message()
  local incompat = self.blocked
  return string.format(
    "incomm: %s is format v%d, this plugin understands up to v%d - update the incomm plugin",
    model_relative(self.store),
    incompat and incompat.found or 0,
    incompat and incompat.supported or model.SCHEMA_VERSION
  )
end

--- False (after telling the user) while the notes file is in a format this
--- build cannot write. Every action that changes notes asks first.
---@return boolean
function Service:check_writable()
  if self.blocked then
    vim.notify(self:blocked_message(), vim.log.levels.ERROR)
    return false
  end
  return true
end

--- Re-detect the git branch and, if it changed, switch to that branch's notes
--- file. Always publishes: switching to an empty branch must clear the cards
--- the previous branch left on screen.
---@return boolean switched
function Service:check_branch()
  local raw = git.detect_branch(self.store.root)
  if raw == self.store.raw_branch then
    return false
  end
  self.store.raw_branch = raw
  self.store.branch = raw ~= "" and git.sanitize_branch(raw) or ""
  self.model = model.new_file()
  self.locally_deleted = {}
  self.last_written = nil
  self:reload({ publish = false })
  self:publish_changed()
  return true
end

-- ---- persistence ----------------------------------------------------------

--- Merge-on-write save. Folds in any notes the file has and we do not (the
--- agent wrote them while we held a stale model) before serializing.
---@param notify boolean whether to publish a change to listeners
function Service:persist(notify)
  if self.blocked then
    return -- a newer format: never write over it
  end
  if notify then
    self:publish_changed() -- immediate UI for the local change
  end

  local disk = self.store:load()
  local known = {}
  for _, note in ipairs(self.model.notes) do
    known[note.id] = true
  end
  local external_appeared = false
  for _, note in ipairs(disk.notes) do
    if not known[note.id] and not self.locally_deleted[note.id] then
      table.insert(self.model.notes, model.copy(note))
      external_appeared = true
    end
  end

  local written, err = self.store:save(self.model)
  if not written then
    vim.notify("incomm: save failed: " .. tostring(err), vim.log.levels.ERROR)
    return
  end
  self.last_written = written
  -- Those deletions are on disk now; stop guarding them.
  self.locally_deleted = {}
  for _, fn in ipairs(M.saved_listeners) do
    pcall(fn, self)
  end

  if external_appeared and not notify then
    self:publish_changed()
  end
end

--- Persist without a redraw. Used for live position tracking, where the
--- extmarks already render correctly.
function Service:persist_quietly()
  self:persist(false)
end

--- True when `raw` is exactly what we last wrote -- i.e. the watcher is seeing
--- our own file event.
---@param raw string?
---@return boolean
function Service:is_own_write(raw)
  return raw ~= nil and raw == self.last_written
end

-- ---- mutations ------------------------------------------------------------

---@param id string
---@param fn fun(note: incomm.Note)
---@return boolean
function Service:mutate(id, fn)
  local note = self:find(id)
  if not note then
    return false
  end
  fn(note)
  self:persist(true)
  return true
end

--- Create a thread on `rel` spanning [start_line, end_line].
---@param rel string
---@param start_line integer
---@param end_line integer
---@param content string
---@param author? string defaults to `user` -- a human is typing in the editor
---@param author_title? string
---@return incomm.Note
function Service:add_note(rel, start_line, end_line, content, author, author_title)
  author = author or model.AUTHOR_USER
  local lines = self:lines_for(rel) or {}
  local now = model.now_utc()
  local note = {
    id = model.new_id(),
    file = rel,
    startLine = start_line,
    endLine = end_line,
    anchor = anchor.compute(lines, start_line, end_line),
    content = content,
    resolved = false,
    orphaned = false,
    author = author,
    authorTitle = author_title or (author == model.AUTHOR_USER and self:default_author_title() or nil),
    audience = model.AUDIENCE_AGENT,
    createdAt = now,
    updatedAt = now,
    replies = {},
  }
  table.insert(self.model.notes, note)
  self:persist(true)
  return note
end

---@param id string
---@param content string
function Service:update_content(id, content)
  return self:mutate(id, function(note)
    note.content = content
    note.updatedAt = model.now_utc()
  end)
end

---@param id string
---@param content string
---@param author? string
---@param author_title? string
function Service:add_reply(id, content, author, author_title, audience)
  author = author or model.AUTHOR_USER
  return self:mutate(id, function(note)
    table.insert(note.replies, {
      id = model.new_id(),
      author = author,
      authorTitle = author_title or (author == model.AUTHOR_USER and self:default_author_title() or nil),
      -- A reply is addressed like the comment it answers, unless told otherwise.
      audience = audience or model.normalize_audience(note.audience),
      content = content,
      createdAt = model.now_utc(),
    })
    note.updatedAt = model.now_utc()
  end)
end

---@param note_id string
---@param reply_id string
---@param content string
function Service:update_reply(note_id, reply_id, content)
  return self:mutate(note_id, function(note)
    for _, reply in ipairs(note.replies) do
      if reply.id == reply_id then
        reply.content = content
        note.updatedAt = model.now_utc()
        return
      end
    end
  end)
end

---@param note_id string
---@param reply_id string
function Service:remove_reply(note_id, reply_id)
  return self:mutate(note_id, function(note)
    for i, reply in ipairs(note.replies) do
      if reply.id == reply_id then
        table.remove(note.replies, i)
        note.updatedAt = model.now_utc()
        return
      end
    end
  end)
end

---@param id string
---@param resolved boolean
function Service:set_resolved(id, resolved)
  return self:mutate(id, function(note)
    note.resolved = resolved
    note.updatedAt = model.now_utc()
  end)
end

---@param id string
---@return boolean
function Service:remove_note(id)
  if not model.remove(self.model, id) then
    return false
  end
  self.locally_deleted[id] = true
  self:persist(true)
  return true
end

--- Delete every thread anchored to one file. Returns how many went.
---@param rel string
---@return integer
function Service:remove_notes_for_file(rel)
  local kept, removed = {}, 0
  for _, note in ipairs(self.model.notes) do
    if note.file == rel then
      self.locally_deleted[note.id] = true
      removed = removed + 1
    else
      kept[#kept + 1] = note
    end
  end
  if removed > 0 then
    self.model.notes = kept
    self:persist(true)
  end
  return removed
end

--- Delete every thread on this branch by removing its notes file.
function Service:clear_all()
  self.model = model.new_file()
  self.locally_deleted = {}
  self.last_written = nil
  self.store:clear()
  self:publish_changed()
end

--- Persist new positions for one file after an edit.
---
--- `positions` maps note id -> {start, end} for notes whose extmark survived;
--- a note missing from it lost its mark (its lines were deleted outright) and
--- is re-anchored by text instead. Position-only changes persist quietly; a
--- redraw is published only when something visible changed -- a note
--- un-orphaned, or a dead mark had to be re-anchored and its sign rebuilt.
---@param rel string
---@param lines string[]
---@param positions table<string, integer[]>
---@return boolean changed
function Service:apply_saved_positions(rel, lines, positions)
  local changed, needs_rebuild = false, false
  for _, note in ipairs(self.model.notes) do
    if note.file == rel then
      local pos = positions[note.id]
      if pos then
        -- Recompute the anchor too, so editing the anchored line's *text*
        -- (not just shifting it) refreshes the anchor live.
        local new_anchor = anchor.compute(lines, pos[1], pos[2])
        if
          note.startLine ~= pos[1]
          or note.endLine ~= pos[2]
          or note.orphaned
          or not anchor.anchor_equal(note.anchor, new_anchor)
        then
          if note.orphaned then
            needs_rebuild = true -- un-orphaning changes the sign
          end
          note.startLine, note.endLine = pos[1], pos[2]
          note.anchor = new_anchor
          note.orphaned = false
          changed = true
        end
      else
        if anchor.reanchor(note, lines) then
          changed, needs_rebuild = true, true
        end
      end
    end
  end
  if changed then
    if needs_rebuild then
      self:persist(true)
    else
      self:persist_quietly()
    end
  end
  return changed
end

--- Move a note to an explicit position, recomputing its anchor (the editor's
--- equivalent of `incomm anchor set <id> --line N`).
---@param id string
---@param start_line integer
---@param end_line integer
function Service:update_position(id, start_line, end_line)
  return self:mutate(id, function(note)
    local lines = self:lines_for(note.file) or {}
    note.startLine = start_line
    note.endLine = math.max(start_line, end_line)
    note.anchor = anchor.compute(lines, note.startLine, note.endLine)
    note.orphaned = false
  end)
end

--- Re-anchor notes against their files' current contents. `rels` limits the
--- work to some files; omit it for all of them. Missing files orphan their
--- notes, exactly as the IntelliJ plugin does.
---@param rels? table<string, boolean>
---@return boolean changed
function Service:reanchor_from_disk(rels)
  local changed = false
  local cache = {}
  for _, note in ipairs(self.model.notes) do
    if not rels or rels[note.file] then
      local lines = cache[note.file]
      if lines == nil then
        lines = self:lines_for(note.file) or false
        cache[note.file] = lines
      end
      if lines == false then
        if not note.orphaned then
          note.orphaned = true
          changed = true
        end
      elseif anchor.reanchor(note, lines) then
        changed = true
      end
    end
  end
  if changed then
    self:persist(true)
  end
  return changed
end

M.Service = Service

return M
