local map = vim.keymap.set
local GIT_CHANGE_REPEAT_TIMEOUT_MS = 1200
local git_change_repeat = {
  deadline = 0,
  direction = nil,
  kind = nil,
  tabpage = nil,
}

local function location_state()
  return {
    tabpage = vim.api.nvim_get_current_tabpage(),
    bufnr = vim.api.nvim_get_current_buf(),
    cursor = vim.api.nvim_win_get_cursor(0),
  }
end

local function same_location(a, b)
  if a == nil or b == nil then
    return false
  end

  return a.tabpage == b.tabpage
    and a.bufnr == b.bufnr
    and a.cursor[1] == b.cursor[1]
    and a.cursor[2] == b.cursor[2]
end

local function now_ms()
  local uv = vim.uv or vim.loop
  return uv.now()
end

local function clear_git_change_repeat()
  git_change_repeat.deadline = 0
  git_change_repeat.direction = nil
  git_change_repeat.kind = nil
  git_change_repeat.tabpage = nil
end

local function current_git_change_repeat_kind()
  local name = vim.api.nvim_buf_get_name(0)
  if type(name) == "string" and vim.startswith(name, "git-workspace://") and name:match("%.diff$") then
    return "git_workspace_diff"
  end

  if vim.wo.diff then
    return "vim_diff"
  end

  return nil
end

local function arm_git_change_repeat(direction)
  local kind = current_git_change_repeat_kind()
  if kind == nil then
    clear_git_change_repeat()
    return
  end

  git_change_repeat.deadline = now_ms() + GIT_CHANGE_REPEAT_TIMEOUT_MS
  git_change_repeat.direction = direction
  git_change_repeat.kind = kind
  git_change_repeat.tabpage = vim.api.nvim_get_current_tabpage()
end

local function git_change_repeat_active()
  if git_change_repeat.deadline <= 0 or now_ms() > git_change_repeat.deadline then
    clear_git_change_repeat()
    return false
  end

  if git_change_repeat.tabpage ~= vim.api.nvim_get_current_tabpage() then
    clear_git_change_repeat()
    return false
  end

  if git_change_repeat.kind ~= current_git_change_repeat_kind() then
    clear_git_change_repeat()
    return false
  end

  return git_change_repeat.direction == "next" or git_change_repeat.direction == "prev"
end

local function jump_back()
  local before = location_state()
  vim.cmd("silent! normal! " .. vim.keycode("<C-o>"))
  local after = location_state()

  local ok, code_navigation = pcall(require, "config.code_navigation")
  if ok and code_navigation.after_jumplist_back and code_navigation.after_jumplist_back(after) then
    return
  end

  if not same_location(before, after) then
    return
  end

  if ok and code_navigation.jump_back and code_navigation.jump_back() then
    return
  end

  vim.cmd("silent! normal! " .. vim.keycode("<C-o>"))
end

local function goto_git_change(direction)
  local before = location_state()
  local ok_workspace, git_workspace = pcall(require, "config.git_workspace")
  if ok_workspace and git_workspace.jump_change and git_workspace.jump_change(direction) then
    return true
  end

  if vim.wo.diff then
    local command = direction == "next" and "]c" or "[c"
    vim.cmd("normal! " .. command)
    return not same_location(before, location_state())
  end

  local ok, gitsigns = pcall(require, "gitsigns")
  if not ok then
    return false
  end

  gitsigns.nav_hunk(direction, { target = "all" })
  return not same_location(before, location_state())
end

local function goto_git_conflict(direction)
  local ok_workspace, git_workspace = pcall(require, "config.git_workspace")
  if ok_workspace and git_workspace.jump_conflict and git_workspace.jump_conflict(direction) then
    return
  end

  local command = direction == "next" and "]x" or "[x"
  vim.cmd("normal! " .. command)
end

local function goto_git_change_with_repeat(direction)
  if goto_git_change(direction) then
    arm_git_change_repeat(direction)
    return
  end

  clear_git_change_repeat()
end

local function repeat_git_change_h()
  if git_change_repeat_active() then
    if goto_git_change(git_change_repeat.direction) then
      arm_git_change_repeat(git_change_repeat.direction)
    else
      clear_git_change_repeat()
    end
    return
  end

  clear_git_change_repeat()
  vim.cmd("normal! " .. vim.v.count1 .. "h")
end

local function refresh_lualine_statusline()
  local ok, lualine = pcall(require, "lualine")
  if ok then
    lualine.refresh({
      place = { "statusline" },
      scope = "all",
    })
  end
end

local function set_telescope_status_path(path)
  vim.g.aeris_telescope_status_path = path or ""
  refresh_lualine_statusline()
end

local function open_focused_diagnostic_float()
  local max_width = math.max(72, math.min(120, vim.o.columns - 8))
  local max_height = math.max(8, math.floor(vim.o.lines * 0.4))
  local _, winid = vim.diagnostic.open_float({
    scope = "line",
    focusable = true,
    border = "rounded",
    source = "if_many",
    max_width = max_width,
    max_height = max_height,
  })

  if not winid or not vim.api.nvim_win_is_valid(winid) then
    return
  end

  vim.api.nvim_set_current_win(winid)
  vim.wo[winid].wrap = true
  vim.wo[winid].linebreak = true
  vim.wo[winid].breakindent = true
end

local function telescope_entry_path(entry)
  if type(entry) ~= "table" then
    return ""
  end

  local path = entry.path or entry.filename or entry.value
  if type(path) ~= "string" or path == "" then
    return ""
  end

  return vim.fn.fnamemodify(path, ":p")
end

local function attach_telescope_statusline(prompt_bufnr)
  local action_state = require("telescope.actions.state")
  local picker = action_state.get_current_picker(prompt_bufnr)
  if picker == nil then
    return true
  end

  local function update()
    set_telescope_status_path(telescope_entry_path(action_state.get_selected_entry()))
  end

  local original_set_selection = picker.set_selection
  picker.set_selection = function(self, row)
    original_set_selection(self, row)
    update()
  end

  vim.api.nvim_create_autocmd({ "BufLeave", "BufWipeout" }, {
    buffer = prompt_bufnr,
    once = true,
    callback = function()
      set_telescope_status_path("")
    end,
  })

  vim.schedule(update)
  return true
end

local open_find_files
local open_live_grep

local function attach_find_files_mappings(prompt_bufnr, strict_case)
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  attach_telescope_statusline(prompt_bufnr)

  local function reopen_with_case(next_strict_case)
    local query = action_state.get_current_line()
    actions.close(prompt_bufnr)
    vim.schedule(function()
      open_find_files({
        strict_case = next_strict_case,
        default_text = query,
      })
    end)
  end

  local function toggle_case_mode()
    reopen_with_case(not strict_case)
  end

  for _, mode in ipairs({ "i", "n" }) do
    vim.keymap.set(mode, "<C-s>", toggle_case_mode, {
      buffer = prompt_bufnr,
      nowait = true,
      silent = true,
      desc = strict_case and "Disable strict case matching" or "Enable strict case matching",
    })
  end

  return true
end

open_find_files = function(opts)
  opts = opts or {}
  local strict_case = opts.strict_case == true

  require("telescope.builtin").find_files({
    hidden = true,
    case_mode = strict_case and "respect_case" or "ignore_case",
    default_text = opts.default_text,
    prompt_title = strict_case and "Find Files [Case]" or "Find Files",
    attach_mappings = function(prompt_bufnr)
      return attach_find_files_mappings(prompt_bufnr, strict_case)
    end,
  })
end

local function attach_live_grep_mappings(prompt_bufnr, strict_case)
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  attach_telescope_statusline(prompt_bufnr)

  local function reopen_with_case(next_strict_case)
    local query = action_state.get_current_line()
    actions.close(prompt_bufnr)
    vim.schedule(function()
      open_live_grep({
        strict_case = next_strict_case,
        default_text = query,
      })
    end)
  end

  local function toggle_case_mode()
    reopen_with_case(not strict_case)
  end

  for _, mode in ipairs({ "i", "n" }) do
    vim.keymap.set(mode, "<C-s>", toggle_case_mode, {
      buffer = prompt_bufnr,
      nowait = true,
      silent = true,
      desc = strict_case and "Disable strict case grep" or "Enable strict case grep",
    })
    vim.keymap.set(mode, "<C-Space>", actions.to_fuzzy_refine, {
      buffer = prompt_bufnr,
      nowait = true,
      silent = true,
      desc = "Fuzzy refine live grep",
    })
  end

  return true
end

open_live_grep = function(opts)
  opts = opts or {}
  local strict_case = opts.strict_case == true

  require("telescope.builtin").live_grep({
    default_text = opts.default_text,
    additional_args = function()
      return { strict_case and "--case-sensitive" or "--ignore-case" }
    end,
    prompt_title = strict_case and "Live Grep [Case]" or "Live Grep",
    attach_mappings = function(prompt_bufnr)
      return attach_live_grep_mappings(prompt_bufnr, strict_case)
    end,
  })
end

local function widen_file_tree()
  local tree_width = require("config.tree_width")
  tree_width.widen_with_repeat()
end

local function narrow_file_tree()
  local tree_width = require("config.tree_width")
  tree_width.narrow_with_repeat()
end

local function repeat_widen_file_tree()
  local tree_width = require("config.tree_width")
  if not tree_width.repeat_active() then
    return "]"
  end

  tree_width.widen_with_repeat()
  return ""
end

local function repeat_narrow_file_tree()
  local tree_width = require("config.tree_width")
  if not tree_width.repeat_active() then
    return "["
  end

  tree_width.narrow_with_repeat()
  return ""
end

map("n", "<Esc>", "<cmd>nohlsearch<CR>", { desc = "Clear search highlight" })
map("n", "<leader>w", "<cmd>write<CR>", { desc = "Write buffer" })
map("n", "<leader>q", "<cmd>quit<CR>", { desc = "Quit window" })
map("n", "<leader>Q", "<cmd>qa!<CR>", { desc = "Quit all" })
map("n", "c", '"_c', { desc = "Change without yanking" })
map("x", "c", '"_c', { desc = "Change selection without yanking" })
map("n", "C", '"_C', { desc = "Change to line end without yanking" })
map("n", "gb", jump_back, { desc = "Jump back" })
map("n", "<D-Left>", jump_back, { desc = "Jump back" })
map("n", "<D-Right>", "<C-i>", { desc = "Jump forward" })
map("n", "<leader>e", "<cmd>NvimTreeToggle<CR>", { desc = "Toggle file tree" })
map("n", "<leader>E", "<cmd>NvimTreeFocus<CR>", { desc = "Focus file tree" })
map("n", "<leader>]", widen_file_tree, { desc = "Widen file tree", nowait = true })
map("n", "<leader>[", narrow_file_tree, { desc = "Narrow file tree", nowait = true })
map("n", "[", repeat_narrow_file_tree, { expr = true, remap = true, nowait = true, desc = "Repeat narrow file tree" })
map("n", "]", repeat_widen_file_tree, { expr = true, remap = true, nowait = true, desc = "Repeat widen file tree" })
map("n", "h", repeat_git_change_h, { nowait = true, silent = true, desc = "Repeat Git change jump" })
map("n", "<Tab>", "<cmd>BufferLineCycleNext<CR>", { desc = "Next buffer tab" })
map("n", "<S-Tab>", "<cmd>BufferLineCyclePrev<CR>", { desc = "Previous buffer tab" })
map("n", "<leader>bd", "<cmd>bdelete<CR>", { desc = "Close buffer" })
map("n", "<leader>gx", function()
  require("config.git_workspace").close()
end, { desc = "Exit Git workspace" })
map("n", "<leader>gw", function()
  require("config.git_workspace").open()
end, { desc = "Open Git workspace" })
map("n", "<leader>tt", function()
  require("config.terminals").open_or_new()
end, { desc = "Open terminal" })
map("n", "<leader>tn", function()
  require("config.terminals").new_terminal()
end, { desc = "New terminal" })
map("n", "<leader>t]", function()
  require("config.terminals").increase_size()
end, { desc = "Increase terminal size" })
map("n", "<leader>t[", function()
  require("config.terminals").decrease_size()
end, { desc = "Decrease terminal size" })
map("n", "<leader>th", function()
  require("config.terminals").hide_current()
end, { desc = "Hide current terminal" })
map("n", "<leader>tl", function()
  require("config.terminals").toggle_sidebar()
end, { desc = "Toggle terminal list" })

map("n", "<M-h>", "<C-w><C-h>", { desc = "Focus left split" })
map("n", "<M-j>", "<C-w><C-j>", { desc = "Focus lower split" })
map("n", "<M-k>", "<C-w><C-k>", { desc = "Focus upper split" })
map("n", "<M-l>", "<C-w><C-l>", { desc = "Focus right split" })
map("n", "<C-h>", "<C-w><C-h>", { desc = "Focus left split" })
map("n", "<C-j>", "<C-w><C-j>", { desc = "Focus lower split" })
map("n", "<C-k>", "<C-w><C-k>", { desc = "Focus upper split" })
map("n", "<C-l>", "<C-w><C-l>", { desc = "Focus right split" })

map("t", "<Esc><Esc>", "<C-\\><C-n>", { desc = "Exit terminal mode" })
map("t", "<leader>t]", function()
  require("config.terminals").increase_size()
end, { desc = "Increase terminal size" })
map("t", "<leader>t[", function()
  require("config.terminals").decrease_size()
end, { desc = "Decrease terminal size" })
map("t", "<leader>th", function()
  require("config.terminals").hide_current()
end, { desc = "Hide current terminal" })
map("t", "<M-h>", "<Cmd>wincmd h<CR>", { desc = "Focus left split" })
map("t", "<M-j>", "<Cmd>wincmd j<CR>", { desc = "Focus lower split" })
map("t", "<M-k>", "<Cmd>wincmd k<CR>", { desc = "Focus upper split" })
map("t", "<M-l>", "<Cmd>wincmd l<CR>", { desc = "Focus right split" })
map("t", "<C-h>", "<Cmd>wincmd h<CR>", { desc = "Focus left split" })
map("t", "<C-j>", "<Cmd>wincmd j<CR>", { desc = "Focus lower split" })
map("t", "<C-k>", "<Cmd>wincmd k<CR>", { desc = "Focus upper split" })
map("t", "<C-l>", "<Cmd>wincmd l<CR>", { desc = "Focus right split" })

map("n", "<leader>ff", function()
  open_find_files()
end, { desc = "Find files" })

map("n", "<leader>fg", function()
  open_live_grep()
end, { desc = "Live grep" })

map("n", "<leader>fb", function()
  require("telescope.builtin").buffers()
end, { desc = "Find buffers" })

map("n", "<leader>fr", function()
  require("telescope.builtin").oldfiles()
end, { desc = "Recent files" })

map("n", "<leader>fd", function()
  require("telescope.builtin").diagnostics()
end, { desc = "Find diagnostics" })

map("n", "<leader>mp", "<cmd>MarkdownPreview<CR>", { desc = "Markdown preview" })
map("n", "<leader>ms", "<cmd>MarkdownPreviewStop<CR>", { desc = "Stop Markdown preview" })
map("n", "<leader>mt", "<cmd>MarkdownPreviewToggle<CR>", { desc = "Toggle Markdown preview" })
map("n", "<leader>mr", function()
  require("config.markdown_render").toggle()
end, { desc = "Toggle Markdown render" })

for index = 1, 9 do
  map("n", "<leader>" .. index, function()
    require("bufferline").go_to(index, true)
  end, { desc = "Go to buffer " .. index })
end

map("n", "<leader>ca", vim.lsp.buf.code_action, { desc = "Code action" })
map("n", "<leader>rn", vim.lsp.buf.rename, { desc = "Rename symbol" })
map("n", "<leader>cf", function()
  require("conform").format({
    async = true,
    lsp_fallback = true,
  })
end, { desc = "Format buffer" })

map("n", "[d", vim.diagnostic.goto_prev, { desc = "Previous diagnostic" })
map("n", "]d", vim.diagnostic.goto_next, { desc = "Next diagnostic" })
map("n", "<leader>cd", open_focused_diagnostic_float, { desc = "Line diagnostics" })
map("n", "]h", function()
  goto_git_change_with_repeat("next")
end, { desc = "Next Git change" })
map("n", "[h", function()
  goto_git_change_with_repeat("prev")
end, { desc = "Previous Git change" })
map("n", "]x", function()
  goto_git_conflict("next")
end, { desc = "Next Git conflict" })
map("n", "[x", function()
  goto_git_conflict("prev")
end, { desc = "Previous Git conflict" })
