local M = {}

local uv = vim.uv

local function normalize_path(path)
  if path == nil or path == "" then
    return nil
  end

  return vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
end

local function canonical_path(path)
  path = normalize_path(path)
  if path == nil then
    return nil
  end

  local realpath = uv.fs_realpath(path)
  return realpath and vim.fs.normalize(realpath) or path
end

local function file_exists(path)
  local stat = path and uv.fs_stat(path)
  return stat ~= nil and stat.type == "file"
end

local function is_go_filetype(bufnr)
  local filetype = vim.bo[bufnr].filetype
  return filetype == "go" or filetype == "gomod" or filetype == "gowork" or filetype == "gotmpl"
end

local function ignored_project_dir(name)
  return name == ".git"
    or name == ".cache"
    or name == ".idea"
    or name == ".vscode"
    or name == "node_modules"
    or name == "dist"
    or name == "build"
    or name == "tmp"
    or name == "vendor"
end

local function rank_go_root(a, b)
  if a.depth ~= b.depth then
    return a.depth < b.depth
  end

  if a.kind ~= b.kind then
    return a.kind < b.kind
  end

  return a.root < b.root
end

local function downward_go_root(path, max_depth)
  local root = canonical_path(path)
  if root == nil then
    return nil
  end

  local queue = { { path = root, depth = 0 } }
  local head = 1
  local seen = { [root] = true }
  local candidates = {}

  while head <= #queue do
    local current = queue[head]
    head = head + 1

    local go_work = current.path .. "/go.work"
    if file_exists(go_work) then
      table.insert(candidates, {
        root = current.path,
        depth = current.depth,
        kind = 0,
      })
    end

    local go_mod = current.path .. "/go.mod"
    if file_exists(go_mod) then
      table.insert(candidates, {
        root = current.path,
        depth = current.depth,
        kind = 1,
      })
    end

    if current.depth < max_depth then
      for name, entry_type in vim.fs.dir(current.path) do
        if entry_type == "directory" and not ignored_project_dir(name) then
          local child = canonical_path(current.path .. "/" .. name)
          if child ~= nil and not seen[child] then
            seen[child] = true
            table.insert(queue, {
              path = child,
              depth = current.depth + 1,
            })
          end
        end
      end
    end
  end

  if vim.tbl_isempty(candidates) then
    return nil
  end

  table.sort(candidates, rank_go_root)
  return candidates[1].root
end

local function find_go_project_root(path)
  path = canonical_path(path)
  if path == nil then
    return nil
  end

  local search_root = path
  if vim.fn.isdirectory(search_root) ~= 1 then
    search_root = vim.fs.dirname(search_root)
  end

  if search_root == nil then
    return nil
  end

  local upward = vim.fs.find({ "go.work", "go.mod" }, {
    path = search_root,
    upward = true,
    stop = uv.os_homedir() or "/",
  })[1]

  if upward ~= nil then
    return canonical_path(vim.fs.dirname(upward))
  end

  return downward_go_root(search_root, 3)
end

local function gopls_config()
  local config = vim.lsp.config.gopls
  return type(config) == "table" and config or nil
end

local function ensure_gopls_for_root(root, opts)
  root = canonical_path(root)
  if root == nil then
    return false
  end

  local config = gopls_config()
  if config == nil then
    return false
  end

  local bufnr = opts and opts.bufnr or 0
  local attach = not (opts and opts.attach == false)

  for _, client in ipairs(vim.lsp.get_clients({ name = "gopls" })) do
    if canonical_path(client.root_dir) == root then
      if attach
        and type(bufnr) == "number"
        and vim.api.nvim_buf_is_valid(bufnr)
        and vim.api.nvim_buf_is_loaded(bufnr)
        and not vim.lsp.buf_is_attached(bufnr, client.id)
      then
        vim.lsp.buf_attach_client(bufnr, client.id)
      end
      return true
    end
  end

  local start_config = vim.deepcopy(config)
  start_config.root_dir = root

  local start_opts = {
    silent = true,
  }

  if type(bufnr) == "number" and vim.api.nvim_buf_is_valid(bufnr) then
    start_opts.bufnr = bufnr
  end

  if not attach then
    start_opts.attach = false
  end

  return vim.lsp.start(start_config, start_opts) ~= nil
end

function M.ensure_go_buffer(bufnr)
  bufnr = vim._resolve_bufnr(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) then
    return false
  end

  if not is_go_filetype(bufnr) or vim.bo[bufnr].buftype ~= "" then
    return false
  end

  local path = canonical_path(vim.api.nvim_buf_get_name(bufnr))
  if path == nil then
    return false
  end

  local root = find_go_project_root(path)
  if root == nil then
    return false
  end

  return ensure_gopls_for_root(root, { bufnr = bufnr })
end

function M.ensure_go_project(path)
  local root = find_go_project_root(path or vim.fn.getcwd())
  if root == nil then
    return false
  end

  return ensure_gopls_for_root(root, {
    bufnr = vim.api.nvim_get_current_buf(),
    attach = false,
  })
end

function M.find_go_project_root(path)
  return find_go_project_root(path)
end

return M
