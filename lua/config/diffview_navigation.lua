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

local function edit_real_file(path, cursor)
  local ok, lib = pcall(require, "diffview.lib")
  local target_tab = ok and lib.get_prev_non_view_tabpage and lib.get_prev_non_view_tabpage() or nil

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

local function when_lsp_ready(bufnr, method, callback)
  if #vim.lsp.get_clients({ bufnr = bufnr, method = method }) > 0 then
    callback()
    return
  end

  local fired = false
  local augroup = api.nvim_create_augroup("erwin_diffview_navigation", { clear = false })

  local function try_callback()
    if fired or not api.nvim_buf_is_valid(bufnr) then
      return false
    end

    if #vim.lsp.get_clients({ bufnr = bufnr, method = method }) == 0 then
      return false
    end

    fired = true
    callback()
    return true
  end

  local autocmd
  autocmd = api.nvim_create_autocmd("LspAttach", {
    group = augroup,
    buffer = bufnr,
    callback = function(event)
      local client = vim.lsp.get_client_by_id(event.data.client_id)
      if client == nil or not client:supports_method(method, { bufnr = bufnr }) then
        return
      end

      if try_callback() and autocmd ~= nil then
        pcall(api.nvim_del_autocmd, autocmd)
      end
    end,
  })

  vim.defer_fn(function()
    if try_callback() and autocmd ~= nil then
      pcall(api.nvim_del_autocmd, autocmd)
      return
    end

    if autocmd ~= nil then
      pcall(api.nvim_del_autocmd, autocmd)
    end

    vim.notify("No LSP definition available for this diff entry", vim.log.levels.WARN)
  end, 1000)
end

function M.goto_definition()
  local location = current_file_context()
  if location == nil then
    vim.lsp.buf.definition()
    return
  end

  push_return_location(location)

  local bufnr = edit_real_file(location.path, location.cursor)
  when_lsp_ready(bufnr, "textDocument/definition", function()
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
