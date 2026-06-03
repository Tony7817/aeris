local M = {}

local log_root = vim.fn.stdpath("config") .. "/log"
local group = vim.api.nvim_create_augroup("aeris_log", { clear = true })

local function current_project_root()
  local cwd = vim.fn.getcwd()
  local git_dir = vim.fs.find(".git", {
    path = cwd,
    upward = true,
  })[1]

  if git_dir ~= nil then
    return vim.fs.normalize(vim.fs.dirname(git_dir))
  end

  return vim.fs.normalize(cwd)
end

local function project_slug(root)
  local normalized = vim.fs.normalize(vim.fn.fnamemodify(root, ":p")):gsub("/$", "")
  local base = vim.fs.basename(normalized) or "workspace"
  base = base:gsub("[^%w._-]", "_")
  if base == "" then
    base = "workspace"
  end

  return string.format("%s-%s", base, vim.fn.sha256(normalized):sub(1, 12))
end

local function current_log_dir()
  return log_root .. "/" .. project_slug(current_project_root())
end

local function current_log_path()
  return current_log_dir() .. "/nvim.log"
end

local function stringify(value)
  if value == nil then
    return ""
  end

  if type(value) == "string" then
    return value
  end

  local ok, encoded = pcall(vim.json.encode, value)
  if ok then
    return encoded
  end

  return vim.inspect(value)
end

local function append(level, event, fields)
  if vim.g.aeris_log_enabled == false then
    return
  end

  local path = current_log_path()
  local line = string.format(
    "%s\t%s\t%s\t%s",
    os.date("%Y-%m-%d %H:%M:%S"),
    level,
    tostring(event or ""),
    stringify(fields)
  )

  vim.fn.mkdir(vim.fs.dirname(path), "p")
  pcall(vim.fn.writefile, { line }, path, "a")
end

function M.path()
  return current_log_path()
end

function M.project_root()
  return current_project_root()
end

function M.info(event, fields)
  append("INFO", event, fields)
end

function M.warn(event, fields)
  append("WARN", event, fields)
end

function M.error(event, fields)
  append("ERROR", event, fields)
end

function M.setup()
  vim.api.nvim_create_user_command("AerisLog", function()
    local path = current_log_path()
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    vim.cmd("botright split " .. vim.fn.fnameescape(path))
  end, {
    desc = "Open Aeris Neovim diagnostic log",
  })

  vim.api.nvim_create_user_command("AerisLogPath", function()
    local path = current_log_path()
    vim.fn.setreg("+", path)
    print(path)
  end, {
    desc = "Print and copy Aeris Neovim diagnostic log path",
  })

  vim.api.nvim_create_user_command("AerisLogClear", function()
    local path = current_log_path()
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    vim.fn.writefile({}, path)
    print("Cleared " .. path)
  end, {
    desc = "Clear Aeris Neovim diagnostic log",
  })

  M.info("nvim.start", {
    argv = vim.fn.argv(),
    cwd = vim.fn.getcwd(),
    project_root = current_project_root(),
    version = vim.version(),
  })

  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      M.info("nvim.leave", {
        cwd = vim.fn.getcwd(),
        project_root = current_project_root(),
      })
    end,
  })
end

return M
