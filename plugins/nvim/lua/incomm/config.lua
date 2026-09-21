-- User-facing configuration and its defaults.
--
-- The IntelliJ plugin ships no default keyboard shortcuts and resolves every
-- colour from the active theme (AGENTS.md §7.9). This one follows both rules:
-- `keymaps` is empty unless asked for, and every highlight links to a group the
-- colourscheme already defines, so incomm looks native in whatever theme is
-- loaded.

local M = {}

---@class incomm.Config
local defaults = {
  --- Show thread cards inline above the code they anchor to.
  cards = true,

  --- Sign-column icons per state. Author/state colouring follows the shared
  --- convention: open = blue, resolved = green, orphaned = red.
  signs = {
    enabled = true,
    open = "●",
    resolved = "✓",
    orphaned = "⚠",
    --- Continue the icon down the rest of a multi-line thread as a thin band,
    --- the way the IDE paints the gutter over a note's whole range. Set to
    --- false to mark only the first line.
    range = "▏",
    priority = 12,
  },

  --- A "+" hint in the sign column on the cursor line when it carries no
  --- thread, mirroring the IDE's hover affordance. Off by default: it redraws
  --- the sign column on every cursor move, which is noisier in a terminal.
  add_hint = false,

  --- Resolving a thread also collapses its card, as in the IDE.
  hide_on_resolve = true,

  --- Hide resolved threads' cards on load.
  hide_resolved = false,

  --- Card appearance.
  card = {
    --- Border drawn around every bubble, so a reply is visibly its own
    --- message: "rounded", "single", "double", "solid", a table of eight
    --- glyphs, or false for no box.
    border = "rounded",
    --- Fixed bubble width in columns. A card is this wide whether the comment
    --- is one word or five lines, which keeps a file full of threads from
    --- looking ragged. Clamped to what the window can give once the card has
    --- been indented to match its code.
    width = 80,
    --- Line the card up with the first non-blank character of the line it is
    --- anchored to, the way the IDE hangs a comment over its own code. False
    --- pins every card to the left margin instead.
    align_to_code = true,
    --- Extra columns to shift every card right, on top of the code's own
    --- indent. A number, or `function(win, bufnr) -> integer`.
    ---
    --- This is the seam for anything that moves the *text* away from the
    --- window's left edge without moving the window: a centring plugin, a
    --- virtual left margin, a zen mode. Such margins are usually inline
    --- virtual text on real lines, which a card -- drawn as virtual *lines* --
    --- knows nothing about, so it would sit at the margin while the code it
    --- belongs to sits in the middle of the window.
    ---
    ---     offset = function(win)
    ---       return require("config.center").pad(win)
    ---     end
    ---
    --- It is re-read whenever the window scrolls, resizes or goes idle, and a
    --- card is redrawn when the answer changes; call `require("incomm").redraw()`
    --- to force it.
    offset = 0,
    --- Indent applied to replies, in spaces.
    reply_indent = 2,
    --- Blank line after the last bubble, to separate the card from the code.
    trailing_blank = false,
    --- Percent that the card's text is pulled back toward the editor, so a
    --- thread reads more quietly than the code it hangs over.
    dim = 30,
  },

  --- The composer: the float a comment is written in.
  composer = {
    --- Keys that save. Cmd-Enter is the IDE's, and reaches Neovim when the
    --- terminal speaks the kitty keyboard protocol (Ghostty, WezTerm, kitty);
    --- the others are there for terminals that do not.
    save = { "<D-CR>", "<C-CR>", "<C-s>" },
    --- Keys that throw the draft away.
    cancel = { "<Esc>", "q", "<C-c>" },
    --- Where it opens: "cursor" next to the code, "center" in the editor.
    --- The explorer always centres, since there is no cursor to sit beside.
    anchor = "cursor",
    --- Total width in columns, borders included, so it matches a bubble
    --- exactly. nil follows `card.width`: what you type is as wide as what it
    --- becomes. Clamped to the editor.
    width = nil,
    --- Height in rows, excluding borders. Grows to fit an existing comment.
    height = 5,
  },

  --- The thread explorer's float layout.
  explorer = {
    --- Fractions of the editor the whole thing takes.
    width = 0.9,
    height = 0.85,
    --- Fraction of that given to the thread list; the rest is the detail pane.
    list_width = 0.34,
    --- Glyph in front of a thread in the list.
    icon = "▌",
    --- Dim the editor behind the explorer while it is open, the way a picker
    --- shades what it covers: the percentage of `IncommBackdrop` (black by
    --- default) laid over everything else, or false for no backdrop. It is a
    --- window of its own, so it needs `termguicolors` and costs nothing when
    --- the explorer is closed.
    backdrop = 60,
  },

  --- Timestamp rendering: "relative" (2h ago), "datetime", "date", "time", or
  --- a strftime string.
  date_format = "relative",

  --- Watch `.incomm/` and `.git/HEAD` for external changes (the agent writing
  --- through the CLI, or a branch switch) and reload live.
  watch = true,

  --- Notify when agent-authored threads or replies arrive from outside.
  notify_agent = true,

  --- Idle delay in ms after the last keystroke before live positions are
  --- recomputed and persisted. Matches the IntelliJ plugin's 400ms.
  reanchor_delay = 400,

  --- Author title written into comments made from this editor. nil = the repo's
  --- git user.name, falling back to the OS user.
  author_title = nil,

  --- Where `:IncommWidth!` remembers a bubble width across sessions. Set to
  --- false to keep the width session-only however it is changed.
  state_file = vim.fn.stdpath("state") .. "/incomm/card-width",

  --- Set `{ prefix = "<leader>i" }` (or a full table, see README) to install
  --- the default keymaps. Nothing is mapped otherwise.
  keymaps = false,
}

---@type incomm.Config
M.options = vim.deepcopy(defaults)

M.defaults = defaults

---@param opts? table
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
  return M.options
end

-- ---------------------------------------------------------------------------
-- The one setting that can outlive a session
-- ---------------------------------------------------------------------------
--
-- Card width is the setting people actually retune by eye, against real code in
-- a real window, so `:IncommWidth!` writes it here and `setup` reads it back.
-- Nothing else is persisted: the rest belongs in your config, under version
-- control, where a setting you meant to keep should live.

--- The remembered width, or nil when none was saved.
---@return integer?
function M.load_width()
  local path = M.options.state_file
  if not path then
    return nil
  end
  local ok, lines = pcall(vim.fn.readfile, path)
  local value = ok and tonumber(vim.trim(lines[1] or "")) or nil
  return value and math.floor(value) or nil
end

--- Remember `width` for future sessions, or forget it when nil.
---@param width integer?
---@return boolean ok, string? error
function M.save_width(width)
  local path = M.options.state_file
  if not path then
    return false, "no state_file configured"
  end
  if not width then
    pcall(vim.fn.delete, path)
    return true
  end
  local dir = vim.fn.fnamemodify(path, ":h")
  if vim.fn.isdirectory(dir) == 0 and vim.fn.mkdir(dir, "p") == 0 then
    return false, "could not create " .. dir
  end
  local ok, err = pcall(vim.fn.writefile, { tostring(width) }, path)
  if not ok then
    return false, tostring(err)
  end
  return true
end

return M
