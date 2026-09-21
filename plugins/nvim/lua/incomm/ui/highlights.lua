-- Every colour incomm paints, in one place.
--
-- Two layers. The **base** groups link to ones the colourscheme already
-- defines, so nothing is hard-coded and a theme (or the user) can redefine any
-- of them. The **derived** groups are then computed from whatever those base
-- groups actually resolve to: bubble backgrounds are the editor background
-- mixed a little toward the author's accent, and the text on them is pulled
-- back toward the background so a card reads as a quiet block beside the code
-- rather than as the brightest thing on screen.
--
-- That is the same construction `ui/IncommColors.kt` uses in the IDE -- mix the
-- surface toward a semantic accent, never name an RGB value -- and it keeps the
-- semantic mapping: the human reads as info/blue, the agent as success/green,
-- an orphaned note as error/red, a resolved one as green.
--
-- Without `termguicolors` there are no 24-bit colours to mix, so the derived
-- groups simply fall back to the base ones and the cards render unfilled.

local M = {}

-- Base groups: the palette's inputs. Redefining one of these (in a
-- colourscheme, or after `setup`) changes everything derived from it.
local links = {
  IncommUser = "DiagnosticInfo", -- the human: blue
  IncommAgent = "DiagnosticOk", -- the agent: green
  IncommContent = "Normal",
  IncommMuted = "Comment", -- timestamps, locations, hints
  IncommStateOpen = "DiagnosticInfo",
  IncommStateResolved = "DiagnosticOk",
  IncommStateOrphaned = "DiagnosticError",
  IncommAddHint = "Comment",
  IncommComposerTitle = "FloatTitle",
  IncommComposerHint = "Comment",
  IncommExplorer = "NormalFloat",
  IncommExplorerBorder = "FloatBorder",
  IncommExplorerTitle = "FloatTitle",
  IncommSelection = "Visual", -- the highlighted row in the thread list
  -- The anchored lines in the explorer's code preview. `CursorLine` is the
  -- band the editor itself puts behind the line you are on, which is what the
  -- preview is showing: mixing a colour of our own here made the code read as
  -- a selection rather than as code.
  IncommPreviewLine = "CursorLine",
  IncommDetailPath = "Title", -- where a thread lives, above its code
  IncommHelpKey = "Special",
}

--- The resolved attributes of a highlight group, following links.
---@param name string
---@return table
local function resolved(name)
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
  return (ok and type(hl) == "table") and hl or {}
end

---@param name string
---@param attr "fg"|"bg"
---@return integer?
local function color_of(name, attr)
  local value = resolved(name)[attr]
  return type(value) == "number" and value or nil
end

---@param rgb integer
---@return integer, integer, integer
local function split(rgb)
  return math.floor(rgb / 0x10000) % 0x100, math.floor(rgb / 0x100) % 0x100, rgb % 0x100
end

--- `fg` mixed over `bg`, with `alpha` the weight of `fg` (0..1).
---
--- Stays in 24-bit integers rather than hex strings, because the results feed
--- straight back in as the background of the next mix -- a string here is how
--- half this palette once ended up unset.
---@param fg integer
---@param bg integer
---@param alpha number
---@return integer
local function blend(fg, bg, alpha)
  local fr, fg_, fb = split(fg)
  local br, bg_, bb = split(bg)
  local function mix(a, b)
    return math.min(255, math.max(0, math.floor(a * alpha + b * (1 - alpha) + 0.5)))
  end
  return mix(fr, br) * 0x10000 + mix(fg_, bg_) * 0x100 + mix(fb, bb)
end

--- Compute the card palette from the base groups and install it.
local function derive()
  local card = require("incomm.config").options.card
  local surface = color_of("Normal", "bg")
  if not vim.o.termguicolors or not surface then
    -- Nothing to mix with: the derived groups borrow the base ones. Cards are
    -- still legible, just not tuned to the theme.
    vim.api.nvim_set_hl(0, "IncommCard", { link = "Normal" })
    vim.api.nvim_set_hl(0, "IncommCardLine", { link = "IncommMuted" })
    for _, author in ipairs({ "User", "Agent" }) do
      vim.api.nvim_set_hl(0, "IncommBorder" .. author, { link = "Incomm" .. author })
      vim.api.nvim_set_hl(0, "IncommName" .. author, { link = "Incomm" .. author })
      vim.api.nvim_set_hl(0, "IncommTime" .. author, { link = "IncommMuted" })
      vim.api.nvim_set_hl(0, "IncommText" .. author, { link = "IncommContent" })
    end
    for _, state in ipairs({ "Open", "Resolved", "Orphaned" }) do
      vim.api.nvim_set_hl(0, "IncommCardState" .. state, { link = "IncommState" .. state })
      vim.api.nvim_set_hl(0, "IncommSign" .. state, { link = "IncommState" .. state })
    end
    return
  end

  local keep = 1 - (card.dim or 30) / 100 -- how much of a foreground survives

  local text = color_of("IncommContent", "fg") or color_of("Normal", "fg") or 0xd0d0d0
  local muted = color_of("IncommMuted", "fg") or text
  local muted_italic = resolved("IncommMuted").italic == true

  local accents = {
    User = color_of("IncommUser", "fg") or text,
    Agent = color_of("IncommAgent", "fg") or text,
  }
  local states = {
    Open = color_of("IncommStateOpen", "fg") or accents.User,
    Resolved = color_of("IncommStateResolved", "fg") or accents.Agent,
    Orphaned = color_of("IncommStateOrphaned", "fg") or text,
  }

  -- The only filled thing on a card: the little tab naming the line and state.
  local card_bg = blend(text, surface, 0.05)
  vim.api.nvim_set_hl(0, "IncommCard", { bg = card_bg })
  vim.api.nvim_set_hl(0, "IncommCardLine", { fg = blend(muted, surface, keep), bg = card_bg, italic = muted_italic })

  for state, accent in pairs(states) do
    -- The state word keeps its own hue so open and resolved stay tellable
    -- apart at a glance, but only orphaned is allowed to shout: it is the one
    -- that means something needs doing.
    local strength = state == "Orphaned" and 0.9 or (state == "Resolved" and 0.55 or 0.6)
    vim.api.nvim_set_hl(0, "IncommCardState" .. state, { fg = blend(accent, surface, strength), bg = card_bg })
    -- The gutter sign sits in the code's own margin, so it is calmed too.
    vim.api.nvim_set_hl(0, "IncommSign" .. state, { fg = blend(accent, surface, strength) })
  end

  for author, accent in pairs(accents) do
    -- The box is what says who wrote this, so it keeps a decent share of the
    -- accent; everything inside it is pulled back toward the editor.
    vim.api.nvim_set_hl(0, "IncommBorder" .. author, { fg = blend(accent, surface, 0.6) })
    vim.api.nvim_set_hl(0, "IncommName" .. author, { fg = blend(accent, surface, 0.85), bold = true })
    -- Three steps, deliberately: the comment's text sits below the code it
    -- hangs over, the timestamp below that. `dim` sets the whole ladder, and
    -- the timestamp starts from the muted colour, so it stays the quietest
    -- thing on the card without the body text having to be as faint as a
    -- code comment.
    vim.api.nvim_set_hl(0, "IncommTime" .. author, { fg = blend(muted, surface, keep - 0.1), italic = muted_italic })
    vim.api.nvim_set_hl(0, "IncommText" .. author, { fg = blend(text, surface, keep) })
  end
end

function M.setup()
  for group, target in pairs(links) do
    -- `default = true`: a colourscheme that defines its own IncommUser wins.
    vim.api.nvim_set_hl(0, group, { link = target, default = true })
  end
  -- The shade the explorer lays over the editor. Not a link, because no
  -- colourscheme defines "the colour to dim everything with", and it is only
  -- ever seen through a `winblend`: plain black, or white on a light
  -- background, which is what every picker's backdrop is.
  -- What the cursor becomes while the explorer's list has focus: nothing at
  -- all. `blend = 100` is transparency, not a colour, so it works over
  -- whatever the cell under it happens to be.
  vim.api.nvim_set_hl(0, "IncommHiddenCursor", { blend = 100, nocombine = true, default = true })
  vim.api.nvim_set_hl(0, "IncommBackdrop", {
    bg = vim.o.background == "light" and "#ffffff" or "#000000",
    default = true,
  })
  local ok, err = pcall(derive)
  if not ok then
    vim.notify("incomm: could not derive the card palette: " .. tostring(err), vim.log.levels.WARN)
  end
end

--- Recompute the derived palette (after a config change).
M.derive = derive

--- The bubble/name/text group suffix for one author.
---@param author string
---@return string
function M.author_suffix(author)
  return author == "agent" and "Agent" or "User"
end

--- The bar/name highlight for one author.
---@param author string
---@return string
function M.for_author(author)
  return "Incomm" .. M.author_suffix(author)
end

--- The state suffix for one note.
---@param note incomm.Note
---@return string
function M.state_suffix(note)
  if note.orphaned then
    return "Orphaned"
  elseif note.resolved then
    return "Resolved"
  end
  return "Open"
end

--- The state highlight for one note.
---@param note incomm.Note
---@return string
function M.for_state(note)
  return "IncommState" .. M.state_suffix(note)
end

--- The sign highlight for one note.
---@param note incomm.Note
---@return string
function M.sign_for_state(note)
  return "IncommSign" .. M.state_suffix(note)
end

return M
