-- Headless test runner: `nvim --headless -l tests/run.lua [spec ...]`.
--
-- Deliberately dependency-free (no plenary): the CLI's tests are `go test` and
-- the IntelliJ plugin's are Gradle, so the Neovim side should also run from a
-- clean checkout with nothing but Neovim on the box.

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path
-- On the runtimepath, so `plugin/incomm.lua` is sourced and `:Incomm` exists
-- here exactly as it does once a plugin manager has loaded the directory.
vim.opt.runtimepath:prepend(root)
vim.cmd.runtime("plugin/incomm.lua")

local T = {}
_G.T = T

T.root = root
T.repo_root = vim.fn.fnamemodify(root, ":h:h") -- plugins/nvim -> repo root
T.failures = {}
T.passed = 0
T.current = "?"

---@param name string
---@param fn fun()
function T.test(name, fn)
  T.current = name
  local ok, err = pcall(fn)
  if ok then
    T.passed = T.passed + 1
    io.write("  ok   " .. name .. "\n")
  else
    T.failures[#T.failures + 1] = name .. ": " .. tostring(err)
    io.write("  FAIL " .. name .. "\n       " .. tostring(err):gsub("\n", "\n       ") .. "\n")
  end
end

---@param cond any
---@param msg? string
function T.ok(cond, msg)
  if not cond then
    error(msg or "expected truthy value", 2)
  end
end

---@param got any
---@param want any
---@param msg? string
function T.eq(got, want, msg)
  if type(got) == "table" and type(want) == "table" then
    if vim.deep_equal(got, want) then
      return
    end
  elseif got == want then
    return
  end
  error(
    string.format("%sgot %s, want %s", msg and (msg .. ": ") or "", vim.inspect(got), vim.inspect(want)),
    2
  )
end

--- A throwaway directory under $TMPDIR, removed when `fn` returns.
---@param fn fun(dir: string)
function T.with_tmpdir(fn)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local ok, err = pcall(fn, dir)
  vim.fn.delete(dir, "rf")
  if not ok then
    error(err, 0)
  end
end

local specs = {}
for i = 1, #(_G.arg or {}) do
  specs[#specs + 1] = _G.arg[i]
end
if #specs == 0 then
  specs = vim.fn.glob(root .. "/tests/*_spec.lua", false, true)
  table.sort(specs)
end

for _, spec in ipairs(specs) do
  io.write(vim.fn.fnamemodify(spec, ":t") .. "\n")
  local chunk, load_err = loadfile(spec)
  if not chunk then
    T.failures[#T.failures + 1] = spec .. ": " .. tostring(load_err)
    io.write("  FAIL could not load: " .. tostring(load_err) .. "\n")
  else
    local ok, err = pcall(chunk)
    if not ok then
      T.failures[#T.failures + 1] = spec .. ": " .. tostring(err)
      io.write("  FAIL " .. tostring(err) .. "\n")
    end
  end
end

io.write(string.format("\n%d passed, %d failed\n", T.passed, #T.failures))
vim.cmd(#T.failures == 0 and "qall!" or "cquit 1")
