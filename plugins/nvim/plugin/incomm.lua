-- `:Incomm <subcommand>` -- every action the IntelliJ plugin registers, plus
-- the CLI-flavoured ones (reanchor, status). Nothing is bound to a key here;
-- see `keymaps` in the README.

if vim.g.loaded_incomm then
  return
end
vim.g.loaded_incomm = true

---@type table<string, fun(opts: table)>
local subcommands = {}

local function act(name)
  return function()
    require("incomm.actions")[name]()
  end
end

subcommands.thread = function(opts)
  -- `:'<,'>Incomm thread` anchors the thread to the selected lines.
  local has_range = opts.range and opts.range > 0
  require("incomm.actions").start_thread(has_range and opts.line1 or nil, has_range and opts.line2 or nil)
end
subcommands.reply = act("reply")
subcommands.edit = act("edit")
-- `:Incomm audience` steps the cycle; `:Incomm audience private` names the target.
subcommands.audience = function(opts)
  require("incomm.actions").audience(opts.fargs[2])
end
subcommands.resolve = act("resolve")
subcommands.delete = act("delete_thread")
subcommands["delete-comment"] = act("delete_comment")
subcommands.toggle = act("toggle_thread")
subcommands["toggle-all"] = act("toggle_all")
subcommands["toggle-resolved"] = act("toggle_resolved")
subcommands["clear-file"] = act("clear_file")
subcommands.clear = act("clear_all")
subcommands.explorer = act("explorer")
subcommands["explorer-file"] = act("explorer_file")
subcommands.reload = act("reload")
subcommands.reanchor = act("reanchor")
subcommands.status = act("status")
subcommands["toggle-watch"] = act("toggle_watch")
subcommands.next = function()
  require("incomm.actions").goto_thread(1)
end
subcommands.prev = function()
  require("incomm.actions").goto_thread(-1)
end

local names = vim.tbl_keys(subcommands)
table.sort(names)

--- `:IncommWidth [N|reset]` -- the one setting worth retuning by eye, so it has
--- a command of its own. With `!` the width is remembered for future sessions.
vim.api.nvim_create_user_command("IncommWidth", function(opts)
  require("incomm").ensure()
  require("incomm.actions").set_width(vim.trim(opts.args), opts.bang)
end, {
  nargs = "?",
  bang = true,
  desc = "incomm: bubble width for this session (! to remember it)",
  complete = function(lead)
    return vim.tbl_filter(function(value)
      return value:find(lead, 1, true) == 1
    end, { "reset", "60", "80", "100", "120" })
  end,
})

vim.api.nvim_create_user_command("Incomm", function(opts)
  require("incomm").ensure()
  local sub = opts.fargs[1] or "explorer"
  local fn = subcommands[sub]
  if not fn then
    vim.notify("incomm: unknown subcommand '" .. sub .. "'\navailable: " .. table.concat(names, ", "), vim.log.levels.ERROR)
    return
  end
  fn(opts)
end, {
  nargs = "*",
  range = true,
  desc = "incomm: line-anchored context threads",
  complete = function(lead, line)
    local words = vim.split(vim.trim(line), "%s+")
    local second = #words > 2 or (#words == 2 and line:match("%s$"))
    local candidates = names
    if second then
      -- Only `audience` takes an argument.
      candidates = words[2] == "audience" and require("incomm.model").AUDIENCE_CYCLE or {}
    end
    return vim.tbl_filter(function(name)
      return name:find(lead, 1, true) == 1
    end, candidates)
  end,
})
