# incomm.nvim

Line-anchored context threads in Neovim, reading and writing the same
`.incomm/notes_<branch>.json` the CLI and the IntelliJ plugin use.

Threads render as cards above the code they belong to, they follow the code as
you edit, and everything you do shows up immediately for an agent running
`incomm list --json` in the same checkout.

A card is indented to the first non-blank column of the line it is anchored to,
so it hangs over its own code rather than over the left margin, and it is
clamped to whatever the window has left at that depth.

```
       L10  open                                                   ← the one filled bit
      ╭──────────────────────────────────────────────────────────╮
      │ Agent (Opus 5)  2m ago                                   │  ← one box per message,
      │ This ignores the error from ReadFile, and buffers the    │    its border coloured
      │ whole file into memory.                                  │    for the author
      ╰──────────────────────────────────────────────────────────╯
        ╭────────────────────────────────────────────────────────╮
        │ Jan Tobola  1m ago                                     │  ← replies nested
        │ Fixed, thanks.                                         │
        ╰────────────────────────────────────────────────────────╯
 ●  10         data, _ := os.ReadFile("big.bin")
    11         fmt.Println(len(data))
```

## Install

The plugin lives in this repository under `plugins/nvim`, so point your plugin
manager at that directory rather than at the repository root.

**lazy.nvim**, from a local checkout:

```lua
{
  dir = vim.fn.expand("~/path/to/incomm/plugins/nvim"),
  name = "incomm",
  event = "VeryLazy",
  opts = {},
}
```

**lazy.nvim**, from GitHub — the repo root is not a Neovim plugin, so add the
subdirectory to the runtimepath yourself:

```lua
{
  "bitbyone/incomm",
  name = "incomm",
  event = "VeryLazy",
  config = function(plugin)
    vim.opt.rtp:append(plugin.dir .. "/plugins/nvim")
    require("incomm").setup({})
  end,
}
```

The CLI is not required at runtime — this plugin speaks the file format
directly — but it is what an agent uses on the other side of the conversation.

## Commands

`:Incomm <subcommand>`, completing on `<Tab>`. Each one is the counterpart of
the identically-named IntelliJ action.

| Subcommand | What it does |
|---|---|
| `thread` | Start a thread on the cursor line, or on the range: `:'<,'>Incomm thread` |
| `reply` | Reply to the thread under the cursor |
| `edit` | Edit one of your comments in the thread under the cursor |
| `resolve` | Resolve / reopen the thread under the cursor (resolving collapses its card) |
| `delete` | Delete the thread under the cursor, replies and all |
| `delete-comment` | Delete one message (a reply, or the whole thread if it is the original) |
| `audience [name]` | Change who may see a comment: one step along the cycle, or straight to `private`, `agent`, `external` or `agent+external` (see below) |
| `toggle` | Show/hide this thread's card; the sign stays |
| `toggle-all` | Show/hide every card |
| `toggle-resolved` | Show/hide resolved cards only |
| `explorer` | Fuzzy thread explorer over the branch |
| `explorer-file` | The same, limited to this file |
| `next` / `prev` | Jump to the next/previous thread in the file |
| `clear-file` | Delete every thread in this file (confirms) |
| `clear` | Delete every thread on this branch (confirms) |
| `reload` | Re-read the notes file and redraw |
| `reanchor` | Re-anchor every thread against the files on disk |
| `status` | Root, branch, notes file and thread counts |
| `toggle-watch` | Turn watching for external changes on/off |

### `:IncommWidth`

Bubble width is the one setting worth retuning by eye, against real code in a
real window, so it has a command of its own:

```vim
:IncommWidth            " what it is now
:IncommWidth 100        " this session
:IncommWidth! 100       " …and remember it for the next one
:IncommWidth reset      " back to whatever the config says
:IncommWidth! reset     " …and forget the remembered one
```

A remembered width is a single number under `stdpath("state")` (see
`state_file`) and wins over the configured default, since it is the most recent
thing you looked at and decided. Nothing else is persisted: the rest of the
configuration belongs in your dotfiles, under version control.

The composer opens as wide as the bubble the text is about to become — it
follows `card.width`, borders included — so what you type sits in the column it
will be read in.

The composer is a normal buffer in a float: write markdown, **`⌘⏎` saves** (the
IDE's key — `<C-CR>` and `<C-s>` too, for terminals that cannot send a Cmd
chord), `<Esc>` or `q` cancels, and `<CR>` is just a newline.

> **macOS:** a Cmd chord only reaches Neovim if the terminal forwards it, and
> most claim `cmd+enter` for full-screen. In Ghostty, hand it over with
> `keybind = super+enter=csi:13;9u` (`CSI 13;9u` is Enter with the super
> modifier, which Neovim decodes as `<D-CR>`); kitty and WezTerm have
> equivalents. Without that, `<C-s>` still saves.

## Keymaps

None by default — the IntelliJ plugin ships none either, and your leader tree is
yours. Pass `keymaps` to install a set:

```lua
require("incomm").setup({ keymaps = { prefix = "<leader>i" } })
```

That gives `<prefix>` + `c` thread · `r` reply · `e` edit · `x` resolve ·
`t` toggle · `d` delete · `a` all · `R` resolved · `i` explorer · `f` explorer
in file · `l` reload · `s` status · `n`/`p` next/previous, plus `]i` / `[i`.
Pass `keys` alongside `prefix` to choose your own suffixes, or map the API
directly:

```lua
vim.keymap.set("n", "<leader>ic", "<cmd>Incomm thread<cr>")
vim.keymap.set("x", "<leader>ic", ":Incomm thread<cr>")
vim.keymap.set("n", "<leader>ir", function() require("incomm").actions.reply() end)
```

## Options

```lua
require("incomm").setup({
  cards = true,            -- inline thread cards
  signs = {
    enabled = true,
    open = "●", resolved = "✓", orphaned = "⚠",
    range = "▏",           -- band down the rest of a multi-line thread; false to skip
    priority = 12,
  },
  add_hint = false,        -- "+" in the sign column on a bare cursor line
  hide_on_resolve = true,  -- resolving collapses the card
  hide_resolved = false,
  card = {
    border = "rounded",    -- "single" | "double" | "solid" | 8 glyphs | false
    width = 80,            -- fixed bubble width, whatever the text is
    align_to_code = true,  -- hang the card over the first non-blank column
    offset = 0,            -- extra left shift; number or function(win, bufnr)
    reply_indent = 2,
    trailing_blank = false,
    dim = 30,              -- % the card's text is pulled back toward the editor
  },
  composer = {
    save = { "<D-CR>", "<C-CR>", "<C-s>" },  -- Cmd-Enter, as in the IDE
    cancel = { "<Esc>", "q", "<C-c>" },
    anchor = "cursor",     -- or "center"; the explorer always centres
    width = nil,           -- total columns; nil follows card.width
    height = 5,            -- rows, growing to fit an existing comment
  },
  explorer = {
    width = 0.9,           -- fractions of the editor the explorer covers
    height = 0.85,
    list_width = 0.34,     -- how much of it the thread list gets
    icon = "▌",
    backdrop = 60,         -- % of IncommBackdrop over the editor; false for none
  },
  date_format = "relative", -- or "datetime" | "date" | "time" | a strftime string
  watch = true,             -- reload when the agent or a branch switch changes the file
  notify_agent = true,      -- notify when agent threads/replies arrive
  reanchor_delay = 400,     -- ms of idle before positions are recomputed and persisted
  author_title = nil,       -- defaults to git user.name
  state_file = vim.fn.stdpath("state") .. "/incomm/card-width", -- false to disable
  keymaps = false,
})
```

Using a Nerd Font? The IDE's icons are closer to:

```lua
signs = { open = "", resolved = "", orphaned = "" }
```

### Colours

Nothing is hard-coded. Five **base** groups link to ones your colourscheme
already defines, and everything the card paints is mixed from whatever those
resolve to:

| Base group | Default | Meaning |
|---|---|---|
| `IncommUser` | `DiagnosticInfo` | the human — blue, by convention |
| `IncommAgent` | `DiagnosticOk` | the agent — green |
| `IncommStateOpen` / `IncommStateResolved` / `IncommStateOrphaned` | `DiagnosticInfo` / `DiagnosticOk` / `DiagnosticError` | a thread's state |
| `IncommContent` | `Normal` | comment text |
| `IncommMuted` | `Comment` | timestamps, locations |
| `IncommAudiencePending` / `IncommAudiencePublished` / `IncommAudiencePrivate` | `DiagnosticWarn` / `DiagnosticOk` / `DiagnosticHint` | the hue of an audience badge's state word, and of `private` |
| `IncommSelection` / `IncommPreviewLine` | `Visual` / `CursorLine` | the explorer's selected row, and the anchored lines in its code preview |

From those it derives the bubble borders, the dimmed body text, the calmed
state words and gutter signs: `IncommBorder{User,Agent}`, `IncommName*`,
`IncommTime*`, `IncommText*`, `IncommCardState*`, `IncommSign*`, plus
`IncommCard` / `IncommCardLine` for the little header tab. Only orphaned keeps
its full strength — it is the state that means something needs doing.

Nothing inside a bubble is filled. A `virt_lines` background stops where its
text stops and cannot be made to meet the border's own cell, so a filled bubble
always showed a seam down its right edge; the border carries the author's colour
instead. The header tab (`L42  open`) is the one thing that keeps a background.

To retune, redefine a **base** group and re-derive:

```lua
vim.api.nvim_set_hl(0, "IncommUser", { link = "Type" })
require("incomm.ui.highlights").derive()
```

That is worth doing when your theme's `DiagnosticInfo` and `DiagnosticOk` are
the same family, which would otherwise make a comment and its reply look alike.
`IncommAddHint`, `IncommComposer*`, `IncommExplorer*` and `IncommBackdrop` —
the shade the explorer lays over the editor — are plain groups you can override
directly. A thread's extent is shown only in the sign column — the icon on its
first line, a thin band down the rest — so nothing ever paints over the code.

## How it behaves

* **Threads follow the code.** Each thread is backed by an extmark, so ordinary
  editing moves it. After 400ms of idle the new positions and a refreshed anchor
  are written to the notes file, so the agent always sees current line numbers.
  Position-only writes do not redraw the buffer.
* **Lost anchors orphan, and heal.** Delete the anchored lines and the thread is
  marked `orphaned` and floats to line 1 with the orphaned sign; type the code
  back and it snaps home. An agent that knows where the code went can fix it
  directly with `incomm anchor set <id> --line N`.
* **Branch-scoped.** Threads live in `notes_<branch>.json`. Switching branches
  swaps them live — `.git/HEAD` is watched.
* **Concurrent with the CLI.** Writes are atomic and merge-on-write: a thread
  the agent adds while your model is stale is never clobbered. Agent threads and
  replies arriving from outside raise a notification.
* **The explorer** is its own float layout, not a picker, because a picker
  previews a *file* and what is wanted is a *thread*. See below.

## Who sees a comment

Every comment and every reply has an **audience**, and it belongs to that one
comment, not to the thread:

| Audience | Meaning |
|---|---|
| `agent` | The agent working in the checkout. The default; a comment with none is this. |
| `agent+external` | The agent works on it, and it belongs on the merge request. |
| `external` | Meant for the merge request, and not shown to the agent. |
| `private` | You only. The CLI never returns it, in any view. |

`:Incomm audience` moves a comment one step along
`agent → agent+external → external → private → agent`. With more than one comment
in the thread it asks which — the original, one of the replies, or the whole
thread, which steps from the original's audience and moves every comment there —
and it does not ask when there is only one. `:Incomm audience private` goes
straight to a named audience. In the explorer the same flow is on `a`, so you can
mark comments while you browse them. There is no default keymap.

A bubble says so in its header line, next to the time, when it is anything but
plain `agent`: `agent + external · not published`, `external · published`,
`private`. The state word appears for what belongs on the merge request:
*published* once the comment records where it went (its `source`), *not
published* until then. It sits in the line the bubble already has, so a card is
never taller for it, and it gets shorter (`+external`, then nothing) when the
line has no room. A reply under a `private` thread shows `private` whatever it
stores; its own audience is untouched and comes back if you unlock the thread.

## Living with other plugins

A card is drawn as virtual *lines*. Anything that moves the text away from the
window's left edge without moving the window — a centring plugin, a virtual left
margin, a zen mode — usually does it with inline virtual text on the real lines,
which virtual lines never see. The card would then sit at the margin while the
code it belongs to sits in the middle of the window.

`card.offset` is the seam for that. Give it a number, or a function that is
handed the window showing the buffer:

```lua
require("incomm").setup({
  card = {
    offset = function(win)
      return require("config.center").pad(win)   -- whatever your margin is
    end,
  },
})
```

It is re-read when the window scrolls, resizes, is entered or goes idle, and the
cards are redrawn when the answer changes — so a margin that appears or moves is
followed without either plugin knowing about the other. `require("incomm").redraw()`
forces it, and also re-derives the palette.

## The explorer

`:Incomm explorer` opens a search box, the three state filters, the thread list
and a detail pane showing the code a thread is anchored to followed by the
conversation, each message in its own box — the shape the IntelliJ plugin's
explorer has. No dependency: it is built from plain floats, and the code
preview is syntax-highlighted with treesitter when a parser is installed. The
editor behind it is shaded (`explorer.backdrop`), the way a picker shades what
it covers.

In the list each thread is two lines with a coloured bar down both of them, and
the bar is the thread's **state** — blue open, green resolved, red orphaned —
the same reading as the gutter sign and the filter row above it. The selection
starts after the bar and the block cursor is hidden while the list has focus
(`IncommHiddenCursor`, restored in the search box and on close), so a selected
thread's state reads exactly like an unselected one's.

| Key | |
|---|---|
| `j` / `k` | next / previous thread |
| `<CR>` | go to the code |
| `r` / `e` | reply / edit your comment |
| `x` / `d` | resolve or reopen / delete |
| `a` | change who sees a comment |
| `/` | search (matches comments, replies, authors and paths) |
| `<C-o>` / `<C-r>` / `<C-x>` | show open / resolved / orphaned threads |
| `<C-d>` / `<C-u>` | scroll a long thread |
| `?` | the key list |
| `q` | close |

The filters start where the IDE's do: open and orphaned in, resolved out.

## API

```lua
local incomm = require("incomm")
incomm.notes()               -- every thread on this branch
incomm.service()             -- the model: :add_note, :add_reply, :set_resolved, …
incomm.actions.reply()       -- everything :Incomm can do
```

## Tests

```bash
nvim --headless -l tests/run.lua           # all specs
nvim --headless -l tests/run.lua tests/anchor_spec.lua
```

`anchor_spec` runs the shared `fixtures/anchor/cases.json` that the Go and
Kotlin suites run, so re-anchoring is provably identical across the three
implementations. `store_spec` and the CLI-dependent parts of `service_spec` and
`interactive_spec` shell out to a real `incomm` binary when one is on `$PATH`
and are skipped otherwise; they check that what this plugin writes is
byte-identical to what the CLI writes, and that neither loses the other's work.

See [AGENTS.md](../../AGENTS.md) §11 for the shared schema and the anchoring
algorithm every integration implements.

## File format versions

The notes file carries a format `version`, and this plugin understands up to
version 2 (which adds `audience` and `source` to comments). A file written in a
newer format is refused: no threads are drawn from it, nothing is written over
it, and you get one notification naming the file and the version. Update the
plugin (or the CLI, if it is the one that is behind) and reload. Every save
stamps the current version.
