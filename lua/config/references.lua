local api = vim.api

local M = {}

local state = {
  tabpage = nil,
  origin_win = nil,
  origin = nil,
  list_win = nil,
  preview_win = nil,
  list_buf = nil,
  preview_buf = nil,
  items = {},
  line_items = {},
}

local group = api.nvim_create_augroup("erwin_references_panel", { clear = true })

local function is_valid_tab(tabpage)
  return tabpage ~= nil and api.nvim_tabpage_is_valid(tabpage)
end

local function is_valid_win(win)
  return win ~= nil and api.nvim_win_is_valid(win)
end

local function is_valid_buf(buf)
  return buf ~= nil and api.nvim_buf_is_valid(buf)
end

local function in_panel_tab(win)
  return is_valid_tab(state.tabpage) and is_valid_win(win) and api.nvim_win_get_tabpage(win) == state.tabpage
end

local function is_panel_win(win)
  return win == state.list_win or win == state.preview_win
end

local function capture_origin(win)
  if not is_valid_win(win) or is_panel_win(win) then
    state.origin = nil
    state.origin_win = nil
    return
  end

  local ok_cursor, cursor = pcall(api.nvim_win_get_cursor, win)
  local ok_view, view = pcall(api.nvim_win_call, win, vim.fn.winsaveview)

  state.origin = {
    tabpage = api.nvim_win_get_tabpage(win),
    win = win,
    bufnr = api.nvim_win_get_buf(win),
    cursor = ok_cursor and cursor or nil,
    view = ok_view and view or nil,
  }
  state.origin_win = win
end

local function restore_origin(origin)
  if type(origin) ~= "table" then
    return
  end

  if is_valid_tab(origin.tabpage) then
    pcall(api.nvim_set_current_tabpage, origin.tabpage)
  end

  local win = origin.win
  if not is_valid_win(win) then
    return
  end

  pcall(api.nvim_set_current_win, win)

  if is_valid_buf(origin.bufnr) and api.nvim_win_get_buf(win) ~= origin.bufnr then
    pcall(api.nvim_win_set_buf, win, origin.bufnr)
  end

  if type(origin.view) == "table" then
    pcall(api.nvim_win_call, win, function()
      vim.fn.winrestview(origin.view)
    end)
  elseif type(origin.cursor) == "table" then
    pcall(api.nvim_win_set_cursor, win, origin.cursor)
  end
end

local function reset_closed_handles()
  if not is_valid_tab(state.tabpage) then
    state.tabpage = nil
    state.origin_win = nil
    state.origin = nil
    state.list_win = nil
    state.preview_win = nil
  end

  if not in_panel_tab(state.origin_win) then
    state.origin_win = nil
  end
  if type(state.origin) == "table" then
    if not is_valid_tab(state.origin.tabpage) or not is_valid_win(state.origin.win) then
      state.origin = nil
    end
  end
  if not in_panel_tab(state.list_win) then
    state.list_win = nil
  end
  if not in_panel_tab(state.preview_win) then
    state.preview_win = nil
  end
  if not is_valid_buf(state.list_buf) then
    state.list_buf = nil
  end
  if not is_valid_buf(state.preview_buf) then
    state.preview_buf = nil
  end
end

local function close_window(win)
  if is_valid_win(win) then
    pcall(api.nvim_win_close, win, true)
  end
end

local function ensure_scratch_buffer(buf, filetype)
  if not is_valid_buf(buf) then
    buf = api.nvim_create_buf(false, true)
  end

  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].buflisted = false
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = filetype
  return buf
end

local function panel_wins()
  local wins = {}

  if not is_valid_tab(state.tabpage) then
    return wins
  end

  for _, win in ipairs(api.nvim_tabpage_list_wins(state.tabpage)) do
    if win == state.list_win or win == state.preview_win then
      table.insert(wins, win)
    end
  end

  return wins
end

local function fallback_origin_win()
  if not is_valid_tab(state.tabpage) then
    return nil
  end

  for _, win in ipairs(api.nvim_tabpage_list_wins(state.tabpage)) do
    if win ~= state.list_win and win ~= state.preview_win then
      return win
    end
  end

  return nil
end

local function set_winbar(win, text)
  if is_valid_win(win) then
    vim.wo[win].winbar = text
  end
end

local function configure_list_window(win, buf)
  api.nvim_win_set_buf(win, buf)
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].cursorline = true
  vim.wo[win].signcolumn = "no"
  vim.wo[win].wrap = false
  vim.wo[win].spell = false
  vim.wo[win].winfixheight = true
  vim.wo[win].winfixwidth = false
  set_winbar(win, "References")
end

local function configure_preview_window(win, buf)
  api.nvim_win_set_buf(win, buf)
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].cursorline = true
  vim.wo[win].signcolumn = "no"
  vim.wo[win].wrap = false
  vim.wo[win].spell = false
  vim.wo[win].winfixheight = true
  vim.wo[win].winfixwidth = false
  set_winbar(win, "Preview")
end

local function balance_panel_widths()
  if not is_valid_win(state.list_win) or not is_valid_win(state.preview_win) then
    return
  end

  local total_width = api.nvim_win_get_width(state.list_win) + api.nvim_win_get_width(state.preview_win)
  if total_width < 2 then
    return
  end

  api.nvim_win_set_width(state.list_win, math.floor(total_width / 2))
end

local function list_label(item)
  local path = vim.fn.fnamemodify(item.filename, ":.")
  local text = vim.trim((item.text or ""):gsub("%s+", " "))
  if text == "" then
    text = "(no text)"
  end
  if vim.fn.strchars(text) > 72 then
    text = vim.fn.strcharpart(text, 0, 71) .. "…"
  end

  return string.format("%s:%d  %s", path, item.lnum, text)
end

local function current_item()
  if not is_valid_win(state.list_win) then
    return nil
  end

  local line = api.nvim_win_get_cursor(state.list_win)[1]
  return state.line_items[line]
end

local function jump_to_item(item)
  if not item then
    return
  end

  local target_win = state.origin_win
  if not in_panel_tab(target_win) then
    target_win = fallback_origin_win()
  end

  M.close({ restore_origin = false })

  if not is_valid_win(target_win) then
    return
  end

  api.nvim_set_current_win(target_win)
  vim.cmd("edit " .. vim.fn.fnameescape(item.filename))
  pcall(api.nvim_win_set_cursor, target_win, { item.lnum, math.max(item.col - 1, 0) })
  vim.cmd("normal! zz")
end

local function render_preview()
  local item = current_item()
  if not is_valid_buf(state.preview_buf) then
    return
  end

  vim.bo[state.preview_buf].modifiable = true

  if item == nil then
    api.nvim_buf_set_lines(state.preview_buf, 0, -1, false, { "No preview available" })
    vim.bo[state.preview_buf].modifiable = false
    return
  end

  vim.fn.bufload(item.bufnr)

  local total_lines = math.max(api.nvim_buf_line_count(item.bufnr), 1)
  local start_line = math.max(item.lnum - 4, 1)
  local end_line = math.min(item.lnum + 4, total_lines)
  local raw_lines = api.nvim_buf_get_lines(item.bufnr, start_line - 1, end_line, false)
  local width = math.max(#tostring(end_line), 2)
  local lines = {
    string.format("%s:%d", vim.fn.fnamemodify(item.filename, ":."), item.lnum),
    "",
  }

  for index, text in ipairs(raw_lines) do
    local line_no = start_line + index - 1
    table.insert(lines, string.format("%" .. width .. "d │ %s", line_no, text))
  end

  api.nvim_buf_set_lines(state.preview_buf, 0, -1, false, lines)
  api.nvim_buf_clear_namespace(state.preview_buf, -1, 0, -1)
  api.nvim_buf_add_highlight(state.preview_buf, -1, "Title", 0, 0, -1)

  local target_line = item.lnum - start_line + 2
  api.nvim_buf_add_highlight(state.preview_buf, -1, "Visual", target_line, 0, -1)

  local filetype = vim.filetype.match({
    filename = item.filename,
    buf = item.bufnr,
  }) or vim.bo[item.bufnr].filetype or ""

  vim.bo[state.preview_buf].filetype = filetype
  vim.bo[state.preview_buf].syntax = filetype
  vim.bo[state.preview_buf].modifiable = false

  if is_valid_win(state.preview_win) then
    api.nvim_win_set_cursor(state.preview_win, { math.max(target_line + 1, 1), 0 })
    api.nvim_win_call(state.preview_win, function()
      vim.fn.winrestview({
        topline = math.max(target_line - 2, 1),
        leftcol = 0,
      })
    end)
  end
end

local function render_list()
  if not is_valid_buf(state.list_buf) then
    return
  end

  local lines = {}
  state.line_items = {}

  for index, item in ipairs(state.items) do
    lines[index] = list_label(item)
    state.line_items[index] = item
  end

  vim.bo[state.list_buf].modifiable = true
  api.nvim_buf_set_lines(state.list_buf, 0, -1, false, lines)
  vim.bo[state.list_buf].modifiable = false
end

local function bind_list_buffer(buf)
  vim.keymap.set("n", "<CR>", function()
    jump_to_item(current_item())
  end, { buffer = buf, desc = "Open selected reference", nowait = true, silent = true })

  vim.keymap.set("n", "o", function()
    jump_to_item(current_item())
  end, { buffer = buf, desc = "Open selected reference", nowait = true, silent = true })

  vim.keymap.set("n", "q", function()
    M.close()
  end, { buffer = buf, desc = "Close references panel", nowait = true, silent = true })

  vim.keymap.set("n", "<Esc>", function()
    M.close()
  end, { buffer = buf, desc = "Cancel references panel", nowait = true, silent = true })

  api.nvim_create_autocmd({ "CursorMoved", "BufEnter" }, {
    group = group,
    buffer = buf,
    callback = function()
      render_preview()
    end,
  })
end

local function bind_preview_buffer(buf)
  vim.keymap.set("n", "q", function()
    M.close()
  end, { buffer = buf, desc = "Close references panel", nowait = true, silent = true })

  vim.keymap.set("n", "<Esc>", function()
    M.close()
  end, { buffer = buf, desc = "Cancel references panel", nowait = true, silent = true })
end

local function ensure_layout()
  reset_closed_handles()

  local current_tab = api.nvim_get_current_tabpage()
  local current_win = api.nvim_get_current_win()
  local origin_win = current_win

  if is_panel_win(origin_win) or not is_valid_win(origin_win) then
    origin_win = fallback_origin_win()
  end

  if state.tabpage == current_tab and is_valid_win(state.list_win) and is_valid_win(state.preview_win) then
    capture_origin(origin_win)
    balance_panel_widths()
    return
  end

  M.close({ restore_origin = false })

  state.tabpage = current_tab
  capture_origin(origin_win)
  state.list_buf = ensure_scratch_buffer(state.list_buf, "erwin-references")
  state.preview_buf = ensure_scratch_buffer(state.preview_buf, "erwin-reference-preview")

  vim.cmd.cclose()
  vim.cmd("botright 14new")
  local panel_left = api.nvim_get_current_win()
  vim.cmd("rightbelow vsplit")
  local panel_right = api.nvim_get_current_win()

  if api.nvim_win_get_position(panel_left)[2] > api.nvim_win_get_position(panel_right)[2] then
    panel_left, panel_right = panel_right, panel_left
  end

  state.list_win = panel_left
  state.preview_win = panel_right

  configure_list_window(state.list_win, state.list_buf)
  configure_preview_window(state.preview_win, state.preview_buf)
  balance_panel_widths()

  bind_list_buffer(state.list_buf)
  bind_preview_buffer(state.preview_buf)
end

function M.open(items)
  if items == nil or vim.tbl_isempty(items) then
    return
  end

  ensure_layout()
  state.items = items
  render_list()

  if is_valid_win(state.list_win) then
    api.nvim_set_current_win(state.list_win)
    api.nvim_win_set_cursor(state.list_win, { 1, 0 })
  end

  render_preview()
end

function M.close(opts)
  opts = opts or {}
  reset_closed_handles()
  local restore = opts.restore_origin ~= false
  local origin = state.origin

  close_window(state.preview_win)
  close_window(state.list_win)

  state.list_win = nil
  state.preview_win = nil
  state.tabpage = nil
  state.items = {}
  state.line_items = {}
  state.origin_win = nil
  state.origin = nil

  if restore then
    restore_origin(origin)
  end
end

api.nvim_create_autocmd("TabClosed", {
  group = group,
  callback = function()
    vim.schedule(reset_closed_handles)
  end,
})

return M
