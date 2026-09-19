-- Anchoring parity with the Go CLI and the IntelliJ plugin.
--
-- The cases come from `fixtures/anchor/cases.json`, the same file
-- `cli/internal/anchor/anchor_test.go` and `AnchoringTest.kt` load. If this
-- file passes, the three implementations place notes identically.

local T = _G.T
local anchor = require("incomm.anchor")

local dir = T.repo_root .. "/fixtures/anchor"
local cases = vim.json.decode(table.concat(vim.fn.readfile(dir .. "/cases.json"), "\n"))
local lines = vim.fn.readfile(dir .. "/" .. cases.file)

for _, c in ipairs(cases.cases) do
  T.test("fixture: " .. c.name, function()
    local note = {
      startLine = c.startLine,
      endLine = c.endLine,
      anchor = c.anchor,
      orphaned = false,
    }
    anchor.reanchor(note, lines)
    T.eq({ note.startLine, note.endLine }, { c.expectStartLine, c.expectEndLine }, "lines")
    T.eq(note.orphaned, c.expectOrphaned, "orphaned")
  end)
end

T.test("compute captures prefixes, context and checksum", function()
  local a = anchor.compute(lines, 9, 9)
  T.eq(a.startPrefix, "func doThing(ctx context.Context) error {")
  T.eq(a.endPrefix, "func doThing(ctx context.Context) error {")
  T.eq(a.contextBefore, "// entrypoint")
  T.eq(a.contextAfter, 'fmt.Println("thinking")')
  T.eq(a.checksum, "sha1:e7f9a47b23031d32705582501e7640ed851188be")
end)

T.test("checksums match the Go CLI byte for byte", function()
  -- Golden values printed by `anchor.Checksum` in cli/internal/anchor over the
  -- same fixture. A mismatch means this plugin loses the +80 checksum bonus the
  -- other implementations award, and scores candidate lines differently.
  T.eq(anchor.checksum(lines, 9, 12), "sha1:64ca25debd0df5a3a8a9810311f843d6d7a879a7")
  T.eq(anchor.checksum(lines, 1, 3), "sha1:d6631cce7132129361cc7418cbba804ddef8b954")
  T.eq(anchor.checksum(lines, 14, 20), "sha1:d55984ce3958da7ad8dc605dc4d9f5aeb75f8ac5")
  -- Out-of-range requests clamp, exactly as the Go version does.
  T.eq(anchor.checksum(lines, 14, 9999), anchor.checksum(lines, 14, #lines))
end)

T.test("prefixes are capped in code points, not bytes", function()
  local wide = { string.rep("ě", 100) }
  local a = anchor.compute(wide, 1, 1)
  T.eq(vim.fn.strchars(a.startPrefix), anchor.PREFIX_LEN)
end)

T.test("a too-weak prefix orphans instead of guessing", function()
  local note = {
    startLine = 1,
    endLine = 1,
    orphaned = false,
    anchor = { startPrefix = "})", endPrefix = "})", contextBefore = "", contextAfter = "", checksum = "" },
  }
  anchor.reanchor(note, { "x", "})", "y" })
  T.eq(note.orphaned, true)
end)

T.test("split_lines drops one trailing newline and normalises CRLF", function()
  T.eq(anchor.split_lines("a\r\nb\n"), { "a", "b" })
  T.eq(anchor.split_lines(""), {})
  T.eq(anchor.split_lines("a\n\n"), { "a", "" })
end)
