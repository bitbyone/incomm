-- Watching for changes made outside this editor.
--
-- Two things can change under us: the agent writing `.incomm/notes_*.json`
-- through the CLI, and the user switching git branches (which switches the
-- whole notes file, AGENTS.md §11.1). The IntelliJ plugin uses VFS listeners
-- plus an on-activation re-sync; here it is a libuv watch on the `.incomm/`
-- directory and on `.git/HEAD`, plus the same belt-and-braces re-sync on
-- `FocusGained`.
--
-- A reload triggered by our *own* write would redraw the buffer for nothing, so
-- the service compares the file against the bytes it last wrote and stays quiet
-- when they match.

local config = require("incomm.config")
local format = require("incomm.ui.format")
local service = require("incomm.service")
local track = require("incomm.track")

local uv = vim.uv or vim.loop

local M = {}

---@type table<string, table> per-root watch handles
local handles = {}
local augroup = vim.api.nvim_create_augroup("incomm_watch", { clear = true })

---@param svc incomm.Service
local function reload_from_disk(svc)
  -- Our own atomic write, echoing back through the watcher: ignore it.
  if svc:is_own_write(svc.store:read_raw()) then
    return
  end
  if svc:reload() then
    track.refresh_all()
  end
end

---@param svc incomm.Service
local function on_branch_change(svc)
  if svc:check_branch() then
    track.refresh_all()
  end
end

--- Arm (or re-arm) the watchers for one service. Safe to call repeatedly: the
-- `.incomm/` directory only exists once the first thread is written, so this
-- runs again after every save and on focus.
---@param svc incomm.Service
function M.ensure(svc)
  if not config.options.watch then
    return
  end
  local root = svc.store.root
  handles[root] = handles[root] or {}
  local h = handles[root]

  if not h.notes and uv.fs_stat(svc.store:dir()) then
    local handle = uv.new_fs_event()
    if handle then
      local ok = handle:start(svc.store:dir(), {}, function(err)
        if err then
          -- The directory went away (`incomm clear`): drop the handle so the
          -- next `ensure` re-arms once it is recreated.
          vim.schedule(function()
            pcall(function()
              handle:stop()
              handle:close()
            end)
            handles[root].notes = nil
          end)
          return
        end
        vim.schedule(function()
          reload_from_disk(svc)
        end)
      end)
      if ok then
        h.notes = handle
      else
        handle:close()
      end
    end
  end

  -- Before the first thread exists there is no `.incomm/` to watch, and the
  -- first writer may well be the agent rather than us. Watch the project root
  -- until the directory appears, then hand over to the real watch above.
  if not h.notes and not h.root then
    local handle = uv.new_fs_event()
    if handle then
      local ok = handle:start(root, {}, function(err, filename)
        if err then
          return
        end
        if filename == nil or filename == ".incomm" then
          vim.schedule(function()
            if uv.fs_stat(svc.store:dir()) then
              pcall(function()
                handle:stop()
                handle:close()
              end)
              handles[root].root = nil
              M.ensure(svc)
              reload_from_disk(svc)
            end
          end)
        end
      end)
      if ok then
        h.root = handle
      else
        handle:close()
      end
    end
  elseif h.notes and h.root then
    -- The directory watch took over; stop listening to the whole project root.
    pcall(function()
      h.root:stop()
      h.root:close()
    end)
    h.root = nil
  end

  -- ...and a slow timer behind it, for as long as `.incomm/` is missing.
  --
  -- The root watch gets exactly one event announcing that directory, and a
  -- scheduled callback that happens to look a moment before it is visible has
  -- spent that one chance: everything after it happens *inside* `.incomm/`,
  -- one level down, where the root watch cannot see. Under load that lost
  -- roughly one first-note-from-the-agent in fifteen. A stat every couple of
  -- seconds closes the hole for good, and stops itself the moment the real
  -- directory watch is armed.
  if not h.notes and not h.poll then
    local timer = uv.new_timer()
    if timer then
      timer:start(2000, 2000, function()
        vim.schedule(function()
          local live = handles[root]
          if not live or live.poll ~= timer then
            return
          end
          if uv.fs_stat(svc.store:dir()) then
            M.ensure(svc) -- arms the directory watch and stops this timer
            reload_from_disk(svc)
          end
        end)
      end)
      h.poll = timer
    end
  elseif h.notes and h.poll then
    pcall(function()
      h.poll:stop()
      h.poll:close()
    end)
    h.poll = nil
  end

  if not h.head then
    local head = require("incomm.git").head_path(root)
    if head and uv.fs_stat(head) then
      local handle = uv.new_fs_event()
      if handle then
        -- Watch the directory holding HEAD: git rewrites the file by rename on
        -- checkout, which would drop a watch on the file itself.
        local ok = handle:start(vim.fn.fnamemodify(head, ":h"), {}, function(_, filename)
          if filename == nil or filename == "HEAD" then
            vim.schedule(function()
              on_branch_change(svc)
            end)
          end
        end)
        if ok then
          h.head = handle
        else
          handle:close()
        end
      end
    end
  end
end

--- Notify about agent-authored threads and replies that arrived from outside.
---@param news incomm.AgentNews[]
local function report(news)
  if not config.options.notify_agent then
    return
  end
  local lines = {}
  for _, item in ipairs(news) do
    lines[#lines + 1] = string.format(
      "%s %s:%d  %s",
      item.is_reply and "replied" or "new thread",
      item.file,
      item.startLine,
      format.preview(item.content, 60)
    )
  end
  vim.notify("incomm: agent activity\n" .. table.concat(lines, "\n"), vim.log.levels.INFO)
end

---@param svc incomm.Service
function M.subscribe(svc)
  if svc._news_subscribed then
    return
  end
  svc._news_subscribed = true
  svc:on_agent_news(report)
end

--- Start watching every known project, and keep doing so as new ones appear.
function M.start()
  for _, svc in ipairs(service.all()) do
    M.subscribe(svc)
    M.ensure(svc)
  end

  -- `.incomm/` only exists once something has been written to it, so the first
  -- save is the moment a directory watch becomes possible. `ensure` is a no-op
  -- when the handle is already armed.
  if not M._on_saved_hooked then
    M._on_saved_hooked = true
    service.on_saved(function(svc)
      if config.options.watch then
        M.ensure(svc)
      end
    end)
  end

  vim.api.nvim_create_autocmd({ "FocusGained", "VimResume" }, {
    group = augroup,
    callback = function()
      if not config.options.watch then
        return
      end
      for _, svc in ipairs(service.all()) do
        M.ensure(svc)
        on_branch_change(svc)
        reload_from_disk(svc)
        -- Files edited outside the editor (the agent working through the CLI)
        -- are re-anchored here, the way `IncommSourceFileWatcher` does it.
        svc:reanchor_from_disk()
      end
      track.refresh_all()
    end,
  })
end

function M.stop()
  -- Emptied in place rather than rebound: `M.handles` hands this table out, and
  -- a fresh one would leave every holder looking at a table nothing writes to.
  for root, h in pairs(handles) do
    for key, handle in pairs(h) do
      pcall(function()
        handle:stop()
        handle:close()
      end)
      h[key] = nil
    end
    handles[root] = nil
  end
  pcall(vim.api.nvim_clear_autocmds, { group = augroup })
end

-- Exposed for diagnostics.
M.handles = handles

return M
