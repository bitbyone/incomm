-- Disk IO for `.incomm/notes[_<branch>].json` -- a port of `cli/internal/store`.
--
-- Root resolution matches the CLI exactly: walk up from the starting directory
-- looking for an existing `.incomm/`, and fall back to the starting directory
-- itself (where `.incomm/` will be created on the first save). Writes are
-- atomic (temp file + rename) because the CLI and this plugin may both be
-- writing, and a reader must never see half a file.

local uv = vim.uv or vim.loop
local git = require("incomm.git")
local model = require("incomm.model")

local M = {}

M.DIR_NAME = ".incomm"
M.FILE_NAME = "notes.json" -- fallback when no branch is detected

---@class incomm.Store
---@field root string absolute path of the directory holding (or to hold) .incomm/
---@field raw_branch string raw git branch name, written into the JSON
---@field branch string filename-safe branch, "" for the legacy notes.json
local Store = {}
Store.__index = Store

--- Walk up from `dir` looking for a directory that contains `.incomm/`.
---@param dir string
---@return string?
local function find_existing(dir)
  while true do
    local stat = uv.fs_stat(dir .. "/" .. M.DIR_NAME)
    if stat and stat.type == "directory" then
      return dir
    end
    local parent = vim.fn.fnamemodify(dir, ":h")
    if parent == dir then
      return nil
    end
    dir = parent
  end
end

M.find_existing = find_existing

--- Resolve the project root and open a store for it.
---@param start_dir? string defaults to the current working directory
---@param explicit_branch? string skips auto-detection when given
---@return incomm.Store
function M.open(start_dir, explicit_branch)
  local base = vim.fn.fnamemodify(start_dir or uv.cwd() or ".", ":p")
  base = base:gsub("/+$", "")
  local root = find_existing(base) or base
  local raw_branch = explicit_branch or git.detect_branch(root)
  return setmetatable({
    root = root,
    raw_branch = raw_branch,
    branch = raw_branch ~= "" and git.sanitize_branch(raw_branch) or "",
  }, Store)
end

---@return string
function Store:dir()
  return self.root .. "/" .. M.DIR_NAME
end

--- `notes_<branch>.json`, or the legacy `notes.json` without a branch.
---@return string
function Store:notes_file_name()
  if self.branch == "" then
    return M.FILE_NAME
  end
  return "notes_" .. self.branch .. ".json"
end

---@return string
function Store:notes_path()
  return self:dir() .. "/" .. self:notes_file_name()
end

--- Raw contents of the notes file, or nil when it does not exist.
---@return string?
function Store:read_raw()
  return git.read_file(self:notes_path())
end

--- Load the branch-scoped notes file. A missing file yields an empty model.
---@return incomm.NotesFile, string? error
function Store:load()
  local data = self:read_raw()
  if not data then
    return model.new_file()
  end
  local parsed, err = model.decode(data)
  if not parsed then
    return model.new_file(), err
  end
  return parsed
end

--- Write the notes file atomically, stamping the raw branch name into the JSON.
--- Returns the exact bytes written, so the caller can recognise its own write
--- when the file watcher fires.
---@param f incomm.NotesFile
---@return string? written, string? error
function Store:save(f)
  if self.raw_branch ~= "" then
    f.branch = self.raw_branch
  end
  model.normalize(f)
  local data = model.encode(f)

  local dir = self:dir()
  if not uv.fs_stat(dir) then
    local ok = vim.fn.mkdir(dir, "p")
    if ok == 0 then
      return nil, "could not create " .. dir
    end
  end

  local tmp = string.format("%s/.notes-%d-%s.json.tmp", dir, uv.os_getpid(), model.new_id())
  local fd, open_err = uv.fs_open(tmp, "w", 420) -- 0644
  if not fd then
    return nil, open_err or ("could not open " .. tmp)
  end
  local ok, write_err = pcall(function()
    assert(uv.fs_write(fd, data, 0))
    uv.fs_fsync(fd)
  end)
  uv.fs_close(fd)
  if not ok then
    uv.fs_unlink(tmp)
    return nil, tostring(write_err)
  end
  local renamed, rename_err = uv.fs_rename(tmp, self:notes_path())
  if not renamed then
    uv.fs_unlink(tmp)
    return nil, rename_err or "rename failed"
  end
  return data
end

--- Delete the branch-scoped notes file, and `.incomm/` if it is left empty.
---@return boolean existed
function Store:clear()
  local path = self:notes_path()
  if not uv.fs_stat(path) then
    return false
  end
  uv.fs_unlink(path)
  local handle = uv.fs_scandir(self:dir())
  if handle and not uv.fs_scandir_next(handle) then
    uv.fs_rmdir(self:dir())
  end
  return true
end

--- Project-root-relative POSIX path for a file, or nil when it sits outside
--- the root (notes can only anchor inside the project).
---@param path string absolute or relative to the cwd
---@return string?
function Store:rel_file(path)
  local abs = vim.fn.fnamemodify(path, ":p")
  abs = abs:gsub("/+$", "")
  local root = self.root:gsub("/+$", "")
  if abs == root then
    return nil
  end
  if abs:sub(1, #root + 1) ~= root .. "/" then
    -- Resolve symlinks once before giving up: /tmp is a symlink on macOS, and
    -- a project opened through one would otherwise look like it is elsewhere.
    local real_abs = uv.fs_realpath(abs) or abs
    local real_root = uv.fs_realpath(root) or root
    if real_abs:sub(1, #real_root + 1) ~= real_root .. "/" then
      return nil
    end
    return real_abs:sub(#real_root + 2)
  end
  return abs:sub(#root + 2)
end

--- Absolute path of a note's project-relative file.
---@param rel string
---@return string
function Store:abs_file(rel)
  return self.root .. "/" .. rel
end

--- Lines of a project file as stored on disk, or nil when unreadable.
---@param rel string
---@return string[]?
function Store:read_lines(rel)
  local data = git.read_file(self:abs_file(rel))
  if not data then
    return nil
  end
  return require("incomm.anchor").split_lines(data)
end

return M
