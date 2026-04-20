local api = vim.api

local M = {}

local return_stack = {}

local function is_valid_tab(tabpage)
  return tabpage ~= nil and api.nvim_tabpage_is_valid(tabpage)
end

local function is_valid_win(win)
  return win ~= nil and api.nvim_win_is_valid(win)
end

local function push_return_location(location)
  return_stack[#return_stack + 1] = location
end

local function restore_return_location(location)
  if not is_valid_tab(location.tabpage) then
    return false
  end

  api.nvim_set_current_tabpage(location.tabpage)

  local win = location.win
  if not is_valid_win(win) or api.nvim_win_get_tabpage(win) ~= location.tabpage then
    for _, candidate in ipairs(api.nvim_tabpage_list_wins(location.tabpage)) do
      if location.buf ~= nil and api.nvim_win_get_buf(candidate) == location.buf then
        win = candidate
        break
      end
    end
  end

  if not is_valid_win(win) then
    local wins = api.nvim_tabpage_list_wins(location.tabpage)
    win = wins[1]
  end

  if not is_valid_win(win) then
    return false
  end

  api.nvim_set_current_win(win)

  if location.cursor ~= nil then
    local function restore_cursor()
      if is_valid_win(win) and api.nvim_win_get_tabpage(win) == location.tabpage then
        pcall(api.nvim_win_set_cursor, win, location.cursor)
      end
    end

    restore_cursor()
    vim.schedule(restore_cursor)
    vim.defer_fn(restore_cursor, 50)
    vim.defer_fn(restore_cursor, 150)
  end

  return true
end

local function open_workspace_file(path, cursor, workspace_root)
  vim.cmd("tabnew")

  local content_win = api.nvim_get_current_win()
  if workspace_root and workspace_root ~= "" and vim.fn.isdirectory(workspace_root) == 1 then
    vim.cmd("tcd " .. vim.fn.fnameescape(workspace_root))
  end

  vim.cmd("keepalt keepjumps edit " .. vim.fn.fnameescape(path))

  local bufnr = api.nvim_get_current_buf()
  if cursor ~= nil then
    pcall(api.nvim_win_set_cursor, content_win, cursor)
  end

  local ok, tree_api = pcall(require, "nvim-tree.api")
  if ok then
    local tree_width = require("config.tree_width").get()
    vim.cmd(string.format("topleft vertical %dnew", tree_width))

    local tree_win = api.nvim_get_current_win()
    tree_api.tree.open({
      current_window = true,
      path = workspace_root and workspace_root ~= "" and workspace_root or vim.fn.getcwd(),
    })
    vim.cmd(string.format("vertical resize %d", tree_width))

    if api.nvim_win_is_valid(tree_win) then
      vim.wo[tree_win].winfixwidth = true
    end

    tree_api.tree.find_file({
      buf = bufnr,
      focus = false,
      open = false,
      update_root = true,
    })

    if api.nvim_win_is_valid(content_win) then
      api.nvim_set_current_win(content_win)
    end
  end

  return bufnr
end

local function focus_buffer(bufnr)
  if not api.nvim_buf_is_valid(bufnr) then
    return false
  end

  if api.nvim_get_current_buf() == bufnr then
    return true
  end

  local win = vim.fn.bufwinid(bufnr)
  if win == -1 or not is_valid_win(win) then
    return false
  end

  api.nvim_set_current_win(win)
  return true
end

local function when_lsp_ready(bufnr, path, method, callback)
  local attempts_remaining = 50

  local function resolved_bufnr()
    if api.nvim_buf_is_valid(bufnr) and api.nvim_buf_get_name(bufnr) == path then
      return bufnr
    end

    local current = api.nvim_get_current_buf()
    if api.nvim_buf_is_valid(current) and api.nvim_buf_get_name(current) == path then
      return current
    end

    local match = vim.fn.bufnr(vim.fn.fnameescape(path))
    if type(match) == "number" and match > 0 and api.nvim_buf_is_valid(match) then
      return match
    end

    return bufnr
  end

  local function poll()
    local ready_buf = resolved_bufnr()
    if api.nvim_buf_is_valid(ready_buf) and #vim.lsp.get_clients({ bufnr = ready_buf, method = method }) > 0 then
      callback(ready_buf)
      return
    end

    attempts_remaining = attempts_remaining - 1
    if attempts_remaining <= 0 then
      vim.notify("No LSP definition available for this entry", vim.log.levels.WARN)
      return
    end

    vim.defer_fn(poll, 100)
  end

  poll()
end

function M.goto_definition_from(opts)
  opts = opts or {}

  local path = opts.path
  if type(path) ~= "string" or path == "" then
    vim.lsp.buf.definition()
    return
  end

  if vim.fn.filereadable(path) ~= 1 then
    vim.notify("Cannot jump to definition: source file is not available on disk", vim.log.levels.WARN)
    return
  end

  if opts.return_location ~= nil then
    push_return_location(opts.return_location)
  end

  local bufnr = open_workspace_file(path, opts.cursor, opts.workspace_root)
  when_lsp_ready(bufnr, path, "textDocument/definition", function(ready_buf)
    focus_buffer(ready_buf)
    vim.lsp.buf.definition()
  end)
end

function M.jump_back()
  while #return_stack > 0 do
    local location = table.remove(return_stack)
    if restore_return_location(location) then
      return true
    end
  end

  return false
end

return M
