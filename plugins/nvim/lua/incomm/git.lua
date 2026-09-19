-- Branch and identity detection, straight off the filesystem.
--
-- A port of `cli/internal/git`. No `git` binary is spawned: the CLI reads
-- `.git/HEAD` and the config files directly, and so does this. That keeps
-- branch detection synchronous and cheap enough to run on `FocusGained` and on
-- every notes reload, with no process spawn on the UI path.

local uv = vim.uv or vim.loop

local M = {}

---@param path string
---@return string?
local function read_file(path)
  local fd = uv.fs_open(path, "r", 438)
  if not fd then
    return nil
  end
  local stat = uv.fs_fstat(fd)
  local data = stat and uv.fs_read(fd, stat.size, 0) or nil
  uv.fs_close(fd)
  return data
end

M.read_file = read_file

--- Walk up from `dir` looking for `.git` -- a directory, or a worktree pointer
--- file ("gitdir: <path>"). Returns the resolved git directory, or nil.
---@param dir string
---@return string?
local function find_git_dir(dir)
  while true do
    local candidate = dir .. "/.git"
    local stat = uv.fs_stat(candidate)
    if stat then
      if stat.type == "directory" then
        return candidate
      end
      -- `.git` is a file -> worktree pointer.
      local data = read_file(candidate)
      local target = data and data:match("^gitdir:%s*(.-)%s*$")
      if target then
        if not target:match("^/") then
          target = dir .. "/" .. target
        end
        local tstat = uv.fs_stat(target)
        if tstat and tstat.type == "directory" then
          return target
        end
      end
    end
    local parent = vim.fn.fnamemodify(dir, ":h")
    if parent == dir then
      return nil
    end
    dir = parent
  end
end

M.find_git_dir = find_git_dir

--- The branch name from a HEAD file's contents.
--- "ref: refs/heads/feature/thing" -> "feature/thing"; a raw sha (detached) -> "".
---@param head string
---@return string
local function parse_branch(head)
  return vim.trim(head):match("^ref: refs/heads/(.+)$") or ""
end

M.parse_branch = parse_branch

--- Current branch for a directory, or "" when not in a repo / detached HEAD.
---@param start_dir string
---@return string
function M.detect_branch(start_dir)
  local git_dir = find_git_dir(start_dir)
  if not git_dir then
    return ""
  end
  local head = read_file(git_dir .. "/HEAD")
  return head and parse_branch(head) or ""
end

--- Path of the HEAD file to watch for branch switches, or nil.
---@param start_dir string
---@return string?
function M.head_path(start_dir)
  local git_dir = find_git_dir(start_dir)
  return git_dir and (git_dir .. "/HEAD") or nil
end

--- Branch name as a filename component: slashes become underscores, so
--- `feature/cool-thing` scopes to `notes_feature_cool-thing.json`.
---@param branch string
---@return string
function M.sanitize_branch(branch)
  return (branch:gsub("/", "_"))
end

--- `user.name` from the repo config, falling back to the global one.
---@param path string
---@return string?
local function read_config_user_name(path)
  local data = read_file(path)
  if not data then
    return nil
  end
  local in_user = false
  for line in (data .. "\n"):gmatch("(.-)\n") do
    line = vim.trim(line)
    if line ~= "" and not line:match("^[#;]") then
      if line:match("^%[") then
        -- `[user]` exactly. git allows subsections (`[user "x"]`), but not for
        -- `name`, so any other section header simply closes this one.
        in_user = line:lower() == "[user]"
      elseif in_user then
        local key, value = line:match("^([^=]+)=(.*)$")
        if key and vim.trim(key):lower() == "name" then
          return vim.trim(value)
        end
      end
    end
  end
  return nil
end

--- Display name for user-authored comments (`authorTitle`).
---@param start_dir string
---@return string?
function M.detect_user_name(start_dir)
  local git_dir = find_git_dir(start_dir)
  if git_dir then
    local name = read_config_user_name(git_dir .. "/config")
    if name and name ~= "" then
      return name
    end
  end
  local home = uv.os_homedir()
  if home then
    local name = read_config_user_name(home .. "/.gitconfig")
    if name and name ~= "" then
      return name
    end
  end
  return nil
end

return M
