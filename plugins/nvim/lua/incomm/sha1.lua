-- SHA-1, in pure Lua on LuaJIT's bit ops.
--
-- The shared spec (AGENTS.md §11.3) pins a note's anchor checksum to
-- `sha1:<hex>` of the anchored block. Neovim ships `vim.fn.sha256` and nothing
-- else, so the hash has to be computed here: getting it wrong means this plugin
-- scores candidate lines differently from the Go CLI and the IntelliJ plugin,
-- and the three would disagree about where a note lives.
--
-- LuaJIT's `bit` normalises every operation to a signed 32-bit integer, which
-- is exactly the arithmetic SHA-1 is defined in. Plain Lua additions are done
-- on doubles first (exact well past 2^32 for the five-term sums below) and
-- folded back with `bit.tobit`.

local bit = require("bit")

local band, bor, bxor, bnot = bit.band, bit.bor, bit.bxor, bit.bnot
local lshift, rol, tobit, tohex = bit.lshift, bit.rol, bit.tobit, bit.tohex

local M = {}

--- Big-endian 64-bit length in bits, as 8 bytes.
---@param len integer byte length of the message
---@return string
local function length_bytes(len)
  local hi = math.floor(len / 0x20000000) -- len * 8 / 2^32
  local lo = (len * 8) % 0x100000000
  local out = {}
  for i = 7, 0, -1 do
    local shift = 2 ^ (8 * (i % 4))
    local word = i < 4 and lo or hi
    out[#out + 1] = string.char(math.floor(word / shift) % 256)
  end
  return table.concat(out)
end

--- Hex SHA-1 digest of `msg`.
---@param msg string
---@return string hex 40 lowercase hex chars
function M.hex(msg)
  local h0, h1, h2, h3, h4 = 0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0

  local len = #msg
  -- 0x80, then zeros up to 56 mod 64, then the bit length.
  msg = msg .. "\128" .. string.rep("\0", (55 - len) % 64) .. length_bytes(len)

  local w = {}
  for chunk = 1, #msg, 64 do
    for j = 0, 15 do
      local a, b, c, d = msg:byte(chunk + j * 4, chunk + j * 4 + 3)
      w[j] = bor(lshift(a, 24), lshift(b, 16), lshift(c, 8), d)
    end
    for j = 16, 79 do
      w[j] = rol(bxor(w[j - 3], w[j - 8], w[j - 14], w[j - 16]), 1)
    end

    local a, b, c, d, e = h0, h1, h2, h3, h4
    for j = 0, 79 do
      local f, k
      if j < 20 then
        f, k = bor(band(b, c), band(bnot(b), d)), 0x5A827999
      elseif j < 40 then
        f, k = bxor(b, c, d), 0x6ED9EBA1
      elseif j < 60 then
        f, k = bor(band(b, c), band(b, d), band(c, d)), 0x8F1BBCDC
      else
        f, k = bxor(b, c, d), 0xCA62C1D6
      end
      local temp = tobit(rol(a, 5) + f + e + k + w[j])
      e, d, c, b, a = d, c, rol(b, 30), a, temp
    end

    h0 = tobit(h0 + a)
    h1 = tobit(h1 + b)
    h2 = tobit(h2 + c)
    h3 = tobit(h3 + d)
    h4 = tobit(h4 + e)
  end

  return tohex(h0) .. tohex(h1) .. tohex(h2) .. tohex(h3) .. tohex(h4)
end

return M
