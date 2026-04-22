local api = vim.api
local fn = vim.fn

local M = {}

local state = {
  active_id = nil,
  last_main_win = nil,
  line_to_id = {},
  sidebar_buf = nil,
  sidebar_win = nil,
  sidebar_width = 34,
}

local group = api.nvim_create_augroup("erwin_terminal_manager", { clear = true })

local function terminals()
  return require("toggleterm.terminal")
end

local function is_valid_buf(buf)
  return buf ~= nil and api.nvim_buf_is_valid(buf)
end

local function is_valid_win(win)
  return win ~= nil and api.nvim_win_is_valid(win)
end

local function window_filetype(win)
  if not is_valid_win(win) then
    return nil
  end

  return vim.bo[api.nvim_win_get_buf(win)].filetype
end

local function window_buftype(win)
  if not is_valid_win(win) then
    return nil
  end

  return vim.bo[api.nvim_win_get_buf(win)].buftype
end

local function window_name(win)
  if not is_valid_win(win) then
    return nil
  end

  return api.nvim_buf_get_name(api.nvim_win_get_buf(win))
end

local function is_primary_window(win)
  local filetype = window_filetype(win)
  local buftype = window_buftype(win)
  local name = window_name(win) or ""

  if filetype == "NvimTree"
    or filetype == "erwin-terminals"
    or filetype == "erwin-git-workspace"
    or filetype == "erwin-git-workspace-conflicts"
    or filetype == "toggleterm"
  then
    return false
  end

  if buftype == "terminal" then
    return false
  end

  if vim.startswith(name, "git-workspace://") then
    return false
  end

  return true
end

local function sidebar_is_open()
  return is_valid_win(state.sidebar_win)
end

local function close_sidebar_window()
  if sidebar_is_open() then
    api.nvim_win_close(state.sidebar_win, true)
  end
  state.sidebar_win = nil
end

local function get_term(id)
  return terminals().get(id, true)
end

local function get_terms()
  return terminals().get_all(true)
end

local function current_window_term_id()
  local bufnr = api.nvim_get_current_buf()
  if vim.bo[bufnr].filetype ~= "toggleterm" then
    return nil
  end

  local term_id = vim.b[bufnr].toggle_number
  return type(term_id) == "number" and term_id or nil
end

local function remember_main_window()
  local win = api.nvim_get_current_win()
  if (sidebar_is_open() and win == state.sidebar_win) or not is_primary_window(win) then
    return
  end
  state.last_main_win = win
end

local function focus_window(win)
  if not is_valid_win(win) then
    return false
  end

  local tabpage = api.nvim_win_get_tabpage(win)
  if api.nvim_get_current_tabpage() ~= tabpage then
    api.nvim_set_current_tabpage(tabpage)
  end
  api.nvim_set_current_win(win)
  state.last_main_win = win
  return true
end

local function current_git_workspace_host_window()
  local tabpage = api.nvim_get_current_tabpage()
  local has_sidebar = false
  local preferred = nil
  local fallback = nil

  for _, win in ipairs(api.nvim_tabpage_list_wins(tabpage)) do
    local buf = api.nvim_win_get_buf(win)
    local filetype = vim.bo[buf].filetype
    local buftype = vim.bo[buf].buftype
    local name = api.nvim_buf_get_name(buf)

    if filetype == "erwin-git-workspace" then
      has_sidebar = true
    elseif filetype ~= "erwin-git-workspace-conflicts" and filetype ~= "toggleterm" and buftype ~= "terminal" then
      if type(name) == "string" and vim.startswith(name, "git-workspace://") then
        preferred = win
      elseif fallback == nil then
        fallback = win
      end
    end
  end

  if not has_sidebar then
    return nil
  end

  return preferred or fallback
end

local function term_visible_in_tab(term, tabpage)
  return term
    and term:is_open()
    and is_valid_win(term.window)
    and api.nvim_win_get_tabpage(term.window) == tabpage
end

local function open_term_in_host(term, host_win)
  if not focus_window(host_win) then
    return false
  end

  local ui = require("toggleterm.ui")
  local config = require("toggleterm.config")

  ui.set_origin_window()
  vim.cmd("rightbelow split")

  local term_win = api.nvim_get_current_win()
  term.window = term_win

  if not term.bufnr or not api.nvim_buf_is_valid(term.bufnr) then
    term.bufnr = ui.create_buf()
  end

  api.nvim_win_set_buf(term_win, term.bufnr)
  term:__set_options()
  api.nvim_set_current_buf(term.bufnr)
  ui.resize_split(term)

  if not term.job_id then
    term:spawn()
  end

  ui.hl_term(term)
  if term.on_open then
    term:on_open()
  end

  if config.get("start_in_insert") and term.window == api.nvim_get_current_win() then
    vim.cmd("startinsert")
  end

  return true
end

local function active_term_id()
  local focused = terminals().get_focused_id()
  if focused then
    state.active_id = focused
    return focused
  end

  if state.active_id and get_term(state.active_id) then
    return state.active_id
  end

  local items = get_terms()
  return items[1] and items[1].id or nil
end

local function get_sidebar_line_for_term(term_id)
  for line, mapped_id in pairs(state.line_to_id) do
    if mapped_id == term_id then
      return line
    end
  end

  return nil
end

local function focus_main_window(preferred_win)
  if focus_window(preferred_win) then
    return
  end

  if is_valid_win(state.last_main_win) and state.last_main_win ~= state.sidebar_win and is_primary_window(state.last_main_win) then
    focus_window(state.last_main_win)
    return
  end

  local current_tabpage = api.nvim_get_current_tabpage()
  local function scan_tab(tabpage)
    for _, win in ipairs(api.nvim_tabpage_list_wins(tabpage)) do
      if (not sidebar_is_open() or win ~= state.sidebar_win) and is_primary_window(win) then
        return focus_window(win)
      end
    end
    return false
  end

  if scan_tab(current_tabpage) then
    return
  end

  for _, tabpage in ipairs(api.nvim_list_tabpages()) do
    if tabpage ~= current_tabpage and scan_tab(tabpage) then
      return
    end
  end
end

local function find_tree_window()
  for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
    if window_filetype(win) == "NvimTree" then
      return win
    end
  end
end

local function restore_tree_column_layout()
  local tree_win = find_tree_window()
  if not is_valid_win(tree_win) then
    return
  end

  local current_win = api.nvim_get_current_win()
  api.nvim_set_current_win(tree_win)
  vim.cmd("wincmd H")
  vim.cmd(string.format("vertical resize %d", require("config.tree_width").get()))
  vim.wo[tree_win].winfixwidth = true

  if is_valid_win(current_win) and current_win ~= tree_win then
    api.nvim_set_current_win(current_win)
  end
end

local function close_other_terms(keep_id)
  for _, term in ipairs(get_terms()) do
    if term.id ~= keep_id and term:is_open() then
      term:close()
    end
  end
end

local function current_sidebar_term_id()
  if not sidebar_is_open() or api.nvim_get_current_win() ~= state.sidebar_win then
    return nil
  end

  local line = api.nvim_win_get_cursor(state.sidebar_win)[1]
  return state.line_to_id[line]
end

local function selected_term_id()
  return current_sidebar_term_id() or active_term_id()
end

local function focus_sidebar_window()
  if not sidebar_is_open() then
    return false
  end

  remember_main_window()
  api.nvim_set_current_win(state.sidebar_win)
  return true
end

local function apply_sidebar_mappings(buf)
  local map = function(lhs, rhs, desc)
    vim.keymap.set("n", lhs, rhs, {
      buffer = buf,
      desc = desc,
      nowait = true,
      silent = true,
    })
  end

  map("<CR>", M.open_selected, "Open terminal")
  map("o", M.open_selected, "Open terminal")
  map("n", M.new_terminal, "New terminal")
  map("r", M.rename_selected, "Rename terminal")
  map("x", M.close_selected, "Close terminal")
  map("q", M.toggle_sidebar, "Hide terminal list")
end

local function ensure_sidebar_buf()
  if is_valid_buf(state.sidebar_buf) then
    return state.sidebar_buf
  end

  local buf = api.nvim_create_buf(false, true)
  state.sidebar_buf = buf

  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].buflisted = false
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].filetype = "erwin-terminals"
  vim.bo[buf].swapfile = false

  apply_sidebar_mappings(buf)

  return buf
end

local function configure_sidebar_window(win)
  vim.wo[win].cursorline = true
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].spell = false
  vim.wo[win].winfixwidth = true
  vim.wo[win].wrap = false
  vim.wo[win].winblend = 0
  vim.wo[win].winhighlight =
    "Normal:TerminalSidebarNormal,NormalNC:TerminalSidebarNormal,EndOfBuffer:TerminalSidebarEndOfBuffer,WinSeparator:WinSeparator,CursorLine:Visual"
end

local function attach_sidebar(term)
  if not is_valid_win(term.window) then
    return
  end

  local buf = ensure_sidebar_buf()
  local host_width = api.nvim_win_get_width(term.window)
  local width = math.min(state.sidebar_width, math.max(24, host_width - 6))

  close_sidebar_window()
  state.sidebar_win = api.nvim_open_win(buf, false, {
    split = "right",
    vertical = true,
    win = term.window,
    width = width,
  })
  configure_sidebar_window(state.sidebar_win)
end

function M.render_sidebar()
  if not is_valid_buf(state.sidebar_buf) then
    return
  end

  local items = get_terms()
  local current_id = active_term_id()
  local lines = {
    " Terminals",
    "",
  }

  state.line_to_id = {}

  if #items == 0 then
    table.insert(lines, "  No terminals yet")
  else
    for _, term in ipairs(items) do
      local marker = term.id == current_id and ">" or " "
      local status = term:is_open() and "open" or "hidden"
      local dir = term.dir and fn.fnamemodify(term.dir, ":~") or fn.getcwd()

      table.insert(lines, string.format("%s %d  %s [%s]", marker, term.id, term:_display_name(), status))
      state.line_to_id[#lines] = term.id
      table.insert(lines, "    " .. dir)
    end
  end

  table.insert(lines, "")
  table.insert(lines, "  <CR> open   n new")
  table.insert(lines, "  r rename   x close")
  table.insert(lines, "  q hide")

  vim.bo[state.sidebar_buf].modifiable = true
  api.nvim_buf_set_lines(state.sidebar_buf, 0, -1, false, lines)
  vim.bo[state.sidebar_buf].modifiable = false

  api.nvim_buf_clear_namespace(state.sidebar_buf, -1, 0, -1)
  api.nvim_buf_add_highlight(state.sidebar_buf, -1, "Title", 0, 1, -1)

  local hint_start = math.max(#lines - 2, 0)
  for line = hint_start, #lines - 1 do
    api.nvim_buf_add_highlight(state.sidebar_buf, -1, "Comment", line, 0, -1)
  end

  if sidebar_is_open() then
    local target_line = get_sidebar_line_for_term(current_id) or 3
    pcall(api.nvim_win_set_cursor, state.sidebar_win, { target_line, 0 })
  end
end

function M.open_sidebar(opts)
  opts = opts or {}

  if sidebar_is_open() then
    if opts.focus then
      focus_sidebar_window()
    end
    return
  end

  local source_win = api.nvim_get_current_win()
  local term_id = active_term_id()
  if not term_id then
    M.new_terminal()
    return
  end

  local term = get_term(term_id)
  if not term then
    M.new_terminal()
    return
  end

  if not term:is_open() then
    focus_main_window()
    close_other_terms(term.id)
    term:open()
  end

  if not is_valid_win(term.window) then
    return
  end

  remember_main_window()
  restore_tree_column_layout()
  attach_sidebar(term)
  M.render_sidebar()

  if opts.focus and sidebar_is_open() then
    api.nvim_set_current_win(state.sidebar_win)
  elseif is_valid_win(source_win) then
    api.nvim_set_current_win(source_win)
  end
end

function M.toggle_sidebar()
  if sidebar_is_open() then
    if api.nvim_get_current_win() ~= state.sidebar_win then
      focus_sidebar_window()
      return
    end

    close_sidebar_window()
    return
  end

  M.open_sidebar({ focus = true })
end

function M.open_terminal(term_id)
  local term = get_term(term_id)
  if not term then
    return
  end

  local host_win = current_git_workspace_host_window()
  local host_tab = is_valid_win(host_win) and api.nvim_win_get_tabpage(host_win) or nil

  focus_main_window(host_win)
  close_other_terms(term.id)

  if host_tab and term_visible_in_tab(term, host_tab) then
    term:focus()
  elseif host_win then
    if term:is_open() then
      term:close()
    end
    if not open_term_in_host(term, host_win) then
      return
    end
  else
    if term:is_open() then
      term:close()
    end
    term:open()
  end

  state.active_id = term.id
  vim.schedule(function()
    restore_tree_column_layout()
    if sidebar_is_open() then
      attach_sidebar(term)
    end
    M.render_sidebar()
  end)
end

function M.open_selected()
  local term_id = selected_term_id()
  if term_id then
    M.open_terminal(term_id)
  end
end

function M.open_or_new()
  local term_id = active_term_id()
  if term_id then
    M.open_terminal(term_id)
    return
  end

  M.new_terminal()
end

function M.hide_current()
  local term_id = current_window_term_id() or active_term_id()
  local term = term_id and get_term(term_id) or nil

  close_sidebar_window()

  if not term or not term:is_open() then
    focus_main_window()
    return
  end

  state.active_id = term.id
  term:close()
  vim.schedule(focus_main_window)
end

function M.new_terminal()
  local term = terminals().Terminal:new({
    close_on_exit = false,
    direction = "horizontal",
    dir = fn.getcwd(),
    on_close = function(closed_term)
      if state.active_id == closed_term.id then
        state.active_id = nil
      end
      vim.schedule(M.render_sidebar)
    end,
    on_exit = function()
      vim.schedule(M.render_sidebar)
    end,
    on_open = function(opened_term)
      state.active_id = opened_term.id
      vim.schedule(function()
        restore_tree_column_layout()
        if sidebar_is_open() then
          attach_sidebar(opened_term)
        end
        M.render_sidebar()
      end)
    end,
  })

  term.display_name = string.format("terminal-%d", term.id)
  local keep_sidebar = sidebar_is_open()
  local host_win = current_git_workspace_host_window()
  focus_main_window(host_win)
  close_other_terms(term.id)
  if host_win then
    if not open_term_in_host(term, host_win) then
      return
    end
  else
    term:open()
  end
  state.active_id = term.id
  if not keep_sidebar then
    vim.schedule(M.open_sidebar)
  else
    vim.schedule(function()
      restore_tree_column_layout()
      local opened_term = get_term(term.id)
      if opened_term and opened_term:is_open() then
        attach_sidebar(opened_term)
      end
      M.render_sidebar()
    end)
  end
end

function M.rename_selected()
  local term = get_term(selected_term_id())
  if not term then
    return
  end

  vim.ui.input({
    default = term:_display_name(),
    prompt = "Terminal name: ",
  }, function(input)
    if input == nil then
      return
    end

    input = vim.trim(input)
    term.display_name = input ~= "" and input or nil
    M.render_sidebar()
  end)
end

function M.close_selected()
  local term_id = selected_term_id()
  local term = get_term(term_id)
  if not term then
    return
  end

  local items = get_terms()
  local replacement_id = nil
  local was_active = term:is_open() or state.active_id == term.id

  for index, candidate in ipairs(items) do
    if candidate.id == term.id then
      local replacement = items[index + 1] or items[index - 1]
      replacement_id = replacement and replacement.id or nil
      break
    end
  end

  term:shutdown()

  if was_active and replacement_id then
    M.open_terminal(replacement_id)
  else
    state.active_id = active_term_id()
    M.render_sidebar()
  end
end

api.nvim_create_autocmd("BufEnter", {
  group = group,
  callback = function(args)
    if vim.bo[args.buf].filetype ~= "toggleterm" then
      return
    end

    local term_id = vim.b[args.buf].toggle_number
    if type(term_id) == "number" then
      state.active_id = term_id
      vim.schedule(M.render_sidebar)
    end
  end,
})

api.nvim_create_autocmd("WinEnter", {
  group = group,
  callback = remember_main_window,
})

api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
  group = group,
  callback = function()
    if not sidebar_is_open() then
      return
    end

    local term = get_term(active_term_id())
    if not term or not term:is_open() then
      close_sidebar_window()
      return
    end

    M.render_sidebar()
  end,
})

return M
