local api = vim.api

local M = {}

local return_stack = {}

local function is_valid_tab(tabpage)
  return tabpage ~= nil and api.nvim_tabpage_is_valid(tabpage)
end

local function is_valid_win(win)
  return win ~= nil and api.nvim_win_is_valid(win)
end

local function current_file_context()
  local ok, lib = pcall(require, "diffview.lib")
  if not ok then
    return nil
  end

  local view = lib.get_current_view()
  if view == nil or type(view.infer_cur_file) ~= "function" then
    return nil
  end

  local ok_file, file = pcall(view.infer_cur_file, view)
  if not ok_file or file == nil or type(file.absolute_path) ~= "string" or file.absolute_path == "" then
    return nil
  end

  local win = api.nvim_get_current_win()

  return {
    path = file.absolute_path,
    tabpage = api.nvim_get_current_tabpage(),
    win = win,
    buf = api.nvim_get_current_buf(),
    cursor = api.nvim_win_get_cursor(win),
  }
end

local function push_return_location(location)
  return_stack[#return_stack + 1] = location
end

local function previous_non_view_tabpage()
  local ok, lib = pcall(require, "diffview.lib")
  if not ok or type(lib.get_current_view) ~= "function" or lib.get_current_view() == nil then
    return nil
  end

  if type(lib.get_prev_non_view_tabpage) ~= "function" then
    return nil
  end

  return lib.get_prev_non_view_tabpage()
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

local function edit_real_file(path, cursor, target_tab)
  target_tab = target_tab or previous_non_view_tabpage()

  if target_tab ~= nil and is_valid_tab(target_tab) then
    api.nvim_set_current_tabpage(target_tab)
    vim.cmd("keepalt keepjumps edit " .. vim.fn.fnameescape(path))
  else
    vim.cmd("tabnew")

    local temp_buf = api.nvim_get_current_buf()
    vim.cmd("keepalt keepjumps edit " .. vim.fn.fnameescape(path))

    if temp_buf ~= api.nvim_get_current_buf() and api.nvim_buf_is_valid(temp_buf) then
      pcall(api.nvim_buf_delete, temp_buf, { force = true })
    end
  end

  if cursor ~= nil then
    pcall(api.nvim_win_set_cursor, 0, cursor)
  end

  return api.nvim_get_current_buf()
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

    local matches = vim.fn.bufnr(vim.fn.fnameescape(path))
    if type(matches) == "number" and matches > 0 and api.nvim_buf_is_valid(matches) then
      return matches
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
      vim.notify("No LSP definition available for this diff entry", vim.log.levels.WARN)
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

  local return_location = opts.return_location
  if return_location ~= nil then
    push_return_location(return_location)
  end

  local bufnr = edit_real_file(path, opts.cursor, opts.target_tab)
  when_lsp_ready(bufnr, path, "textDocument/definition", function(ready_buf)
    focus_buffer(ready_buf)
    vim.lsp.buf.definition()
  end)
end

function M.goto_definition()
  local location = current_file_context()
  if location == nil then
    vim.lsp.buf.definition()
    return
  end

  M.goto_definition_from({
    path = location.path,
    cursor = location.cursor,
    return_location = location,
  })
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
