-- incomm for Neovim: line-anchored context threads, shared with the CLI and the
-- IntelliJ plugin through `.incomm/notes_<branch>.json`.
--
--     require("incomm").setup()            -- defaults; no keymaps
--     require("incomm").setup({ keymaps = { prefix = "<leader>i" } })
--
-- See README.md in this directory, and AGENTS.md at the repo root for the
-- shared format and the anchoring algorithm every integration implements.

local config = require("incomm.config")

local M = {}

M.actions = setmetatable({}, {
  __index = function(_, key)
    return require("incomm.actions")[key]
  end,
})

local did_setup = false

--- Default keymaps, installed only when `keymaps` is set. The IDE ships none
--- either -- every action there is user-assignable -- so nothing is bound
--- unless asked for.
---@param spec table|{prefix: string}
local function install_keymaps(spec)
  local prefix = type(spec) == "table" and spec.prefix or "<leader>i"
  local actions = require("incomm.actions")
  ---@type table<string, {rhs: function, desc: string, mode?: string|string[]}>
  local defaults = {
    c = { rhs = ":Incomm thread<cr>", desc = "Start thread", mode = { "n", "x" } },
    r = { rhs = actions.reply, desc = "Reply to thread" },
    e = { rhs = actions.edit, desc = "Edit comment" },
    x = { rhs = actions.resolve, desc = "Resolve / reopen thread" },
    t = { rhs = actions.toggle_thread, desc = "Show/hide thread" },
    d = { rhs = actions.delete_thread, desc = "Delete thread" },
    a = { rhs = actions.toggle_all, desc = "Show/hide all threads" },
    R = { rhs = actions.toggle_resolved, desc = "Show/hide resolved threads" },
    i = { rhs = actions.explorer, desc = "Thread explorer" },
    f = { rhs = actions.explorer_file, desc = "Thread explorer (this file)" },
    l = { rhs = actions.reload, desc = "Reload state" },
    s = { rhs = actions.status, desc = "Status" },
    n = { rhs = function() actions.goto_thread(1) end, desc = "Next thread" },
    p = { rhs = function() actions.goto_thread(-1) end, desc = "Previous thread" },
  }
  local keys = type(spec) == "table" and spec.keys or nil
  for suffix, entry in pairs(keys or defaults) do
    local rhs = entry.rhs or entry[1]
    if type(rhs) == "string" and rhs:sub(1, 1) == ":" then
      vim.keymap.set(entry.mode or "n", prefix .. suffix, rhs, { desc = "incomm: " .. entry.desc, silent = true })
    else
      vim.keymap.set(entry.mode or "n", prefix .. suffix, rhs, { desc = "incomm: " .. entry.desc })
    end
  end
  -- Motion pair, in the usual Vim shape.
  vim.keymap.set("n", "]i", function()
    actions.goto_thread(1)
  end, { desc = "incomm: next thread" })
  vim.keymap.set("n", "[i", function()
    actions.goto_thread(-1)
  end, { desc = "incomm: previous thread" })
end

---@param opts? incomm.Config
function M.setup(opts)
  config.setup(opts)
  -- A width saved with `:IncommWidth!` is the most recent thing the user
  -- actually looked at and decided, so it wins over the configured default.
  -- `:IncommWidth! reset` forgets it and hands the setting back to the config.
  local remembered = config.load_width()
  if remembered then
    config.options.card.width = remembered
  end
  did_setup = true

  require("incomm.ui.highlights").setup()
  local track = require("incomm.track")
  local service = require("incomm.service")
  local watch = require("incomm.watch")

  local augroup = vim.api.nvim_create_augroup("incomm", { clear = true })

  vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile", "BufEnter" }, {
    group = augroup,
    callback = function(args)
      local svc_before = #service.all()
      track.attach(args.buf)
      if #service.all() ~= svc_before then
        -- A buffer from a project we had not seen: start watching it too.
        watch.start()
      end
    end,
  })

  -- A colourscheme change re-establishes the links and repaints the cards.
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = augroup,
    callback = function()
      require("incomm.ui.highlights").setup()
      track.redraw_all()
    end,
  })

  -- `:cd` elsewhere means a different project: re-resolve and re-attach.
  vim.api.nvim_create_autocmd("DirChanged", {
    group = augroup,
    callback = function()
      service.primary()
      track.attach_all()
      watch.start()
    end,
  })

  service.primary()
  track.attach_all()
  watch.start()

  if config.options.keymaps then
    install_keymaps(config.options.keymaps)
  end
end

--- Set up with defaults if the user never called `setup` (so the plugin works
--- straight from `:Incomm`).
function M.ensure()
  if not did_setup then
    M.setup()
  end
end

--- Redraw every tracked buffer. Call this after changing anything the plugin
--- cannot see for itself -- a `card.offset` that depends on some other
--- plugin's state, say, or a highlight override.
function M.redraw()
  require("incomm.ui.highlights").derive()
  require("incomm.track").redraw_all()
end

--- The service for the current project (root, branch, notes, mutations).
---@return incomm.Service
function M.service()
  M.ensure()
  return require("incomm.service").primary()
end

--- Every thread on the current branch.
---@return incomm.Note[]
function M.notes()
  return M.service():all_notes()
end

return M
