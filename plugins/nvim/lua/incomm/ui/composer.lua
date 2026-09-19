-- The inline composer: a small floating buffer for writing a comment.
--
-- The IDE embeds a real editor in the card so every editing key works
-- (`EditorTextField`, AGENTS.md §7.3). In Neovim the same requirement is met by
-- making the composer a normal buffer in a float: motions, undo, registers and
-- whatever plugins the user has all behave, which a `vim.ui.input` prompt could
-- never offer for multi-line markdown.
--
-- Keys mirror the IDE's: Cmd-Enter saves (with Ctrl-Enter and Ctrl-S for
-- terminals that cannot deliver a Cmd chord), Esc or q cancels, and plain Enter
-- stays a newline.

local config = require("incomm.config")

local M = {}

--- The save hint: the first configured key, in a form worth reading. The rest
--- are fallbacks for terminals that cannot send a Cmd chord, and listing all of
--- them turns the footer into a paragraph.
---@param keys string[]
---@return string
local function pretty_key(keys)
  for _, key in ipairs(keys) do
    if key == "<D-CR>" then
      if vim.fn.has("mac") == 1 then
        return "⌘⏎"
      end
    elseif key == "<D-s>" then
      if vim.fn.has("mac") == 1 then
        return "⌘s"
      end
    else
      return key == "<C-CR>" and "<C-CR>" or key
    end
  end
  return "<C-s>"
end

---@class incomm.ComposerOpts
---@field title string
---@field text? string initial contents (editing an existing comment)
---@field hint? string
---@field anchor? "cursor"|"center" where the float opens
---@field on_submit fun(text: string)
---@field on_cancel? fun()

--- Open the composer.
---@param opts incomm.ComposerOpts
function M.open(opts)
  local text = opts.text or ""
  local lines = vim.split(text, "\n", { plain = true })
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].filetype = "markdown"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.b[bufnr].incomm_composer = true

  local settings = config.options.composer
  local width = math.min(math.max(60, math.floor(vim.o.columns * 0.5)), vim.o.columns - 8)
  local height = math.min(math.max(#lines + 1, 5), math.max(5, vim.o.lines - 8))
  local placement = (opts.anchor or settings.anchor) == "center"
      and {
        relative = "editor",
        row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
        col = math.max(0, math.floor((vim.o.columns - width) / 2)),
      }
    or { relative = "cursor", row = 1, col = 0 }
  local win = vim.api.nvim_open_win(bufnr, true, vim.tbl_extend("force", placement, {
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " " .. opts.title .. " ",
    title_pos = "left",
    footer = " " .. (opts.hint or (pretty_key(settings.save) .. " save   <Esc> cancel")) .. " ",
    footer_pos = "right",
    zindex = 70, -- above the explorer's floats
  }))
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].winhighlight = "FloatTitle:IncommComposerTitle,FloatFooter:IncommComposerHint"

  local closed = false
  local function close()
    if closed then
      return
    end
    closed = true
    -- Leave insert mode first: closing the float while insert-mode is active
    -- drops the user back into their *code* buffer still inserting, where the
    -- next keystrokes would edit the file.
    if vim.fn.mode():match("^i") then
      vim.cmd.stopinsert()
    end
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  local function submit()
    local content = vim.trim(table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n"))
    close()
    if content == "" then
      vim.notify("incomm: empty comment, nothing saved", vim.log.levels.INFO)
      if opts.on_cancel then
        opts.on_cancel()
      end
      return
    end
    opts.on_submit(content)
  end

  local function cancel()
    close()
    if opts.on_cancel then
      opts.on_cancel()
    end
  end

  local map_opts = { buffer = bufnr, nowait = true, silent = true }
  for _, key in ipairs(settings.save) do
    -- In insert mode too: a comment is written in insert mode, and reaching for
    -- Esc first before saving is exactly the friction the IDE does not have.
    pcall(vim.keymap.set, { "n", "i" }, key, submit, map_opts)
  end
  for _, key in ipairs(settings.cancel) do
    -- Normal mode only, so Esc keeps meaning "leave insert" while typing.
    pcall(vim.keymap.set, "n", key, cancel, map_opts)
  end
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    once = true,
    callback = function()
      if not closed then
        closed = true
        if opts.on_cancel then
          opts.on_cancel()
        end
      end
    end,
  })

  -- A new comment starts in insert mode; an edit starts in normal mode with the
  -- cursor at the end, so the existing text is there to work on.
  vim.api.nvim_win_set_cursor(win, { #lines, #(lines[#lines] or "") })
  if text == "" then
    -- Scheduled, not called outright: `startinsert` issued from inside a
    -- mapping's callback is undone when the mapping finishes, which left the
    -- composer in normal mode and ate the first character typed into it.
    vim.schedule(function()
      if vim.api.nvim_get_current_buf() == bufnr then
        vim.cmd.startinsert()
      end
    end)
  end
  return win, bufnr
end

return M
