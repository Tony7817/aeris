local map = vim.keymap.set

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

local function jump_back()
  local before = location_state()
  vim.cmd("silent! normal! " .. vim.keycode("<C-o>"))
  local after = location_state()

  if not same_location(before, after) then
    return
  end

  local ok, code_navigation = pcall(require, "config.code_navigation")
  if ok and code_navigation.jump_back and code_navigation.jump_back() then
    return
  end

  vim.cmd("silent! normal! " .. vim.keycode("<C-o>"))
end

local function goto_git_change(direction)
  local ok_workspace, git_workspace = pcall(require, "config.git_workspace")
  if ok_workspace and git_workspace.jump_change and git_workspace.jump_change(direction) then
    return
  end

  if vim.wo.diff then
    local command = direction == "next" and "]c" or "[c"
    vim.cmd("normal! " .. command)
    return
  end

  local ok, gitsigns = pcall(require, "gitsigns")
  if not ok then
    return
  end

  gitsigns.nav_hunk(direction, { target = "all" })
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

local function widen_file_tree()
  local tree_width = require("config.tree_width")
  tree_width.widen_with_repeat()
end

local function repeat_widen_file_tree()
  local tree_width = require("config.tree_width")
  if not tree_width.repeat_active() then
    return "]"
  end

  tree_width.widen_with_repeat()
  return ""
end

map("n", "<Esc>", "<cmd>nohlsearch<CR>", { desc = "Clear search highlight" })
map("n", "<leader>w", "<cmd>write<CR>", { desc = "Write buffer" })
map("n", "<leader>q", "<cmd>quit<CR>", { desc = "Quit window" })
map("n", "<leader>Q", "<cmd>qa!<CR>", { desc = "Quit all" })
map("n", "gb", jump_back, { desc = "Jump back" })
map("n", "<D-Left>", jump_back, { desc = "Jump back" })
map("n", "<D-Right>", "<C-i>", { desc = "Jump forward" })
map("n", "<leader>e", "<cmd>NvimTreeToggle<CR>", { desc = "Toggle file tree" })
map("n", "<leader>E", "<cmd>NvimTreeFocus<CR>", { desc = "Focus file tree" })
map("n", "<leader>]", widen_file_tree, { desc = "Widen file tree" })
map("n", "]", repeat_widen_file_tree, { expr = true, remap = true, desc = "Repeat widen file tree" })
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
  require("config.terminals").new_terminal()
end, { desc = "New terminal" })
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
  require("telescope.builtin").find_files({
    hidden = true,
    attach_mappings = function(prompt_bufnr)
      return attach_telescope_statusline(prompt_bufnr)
    end,
  })
end, { desc = "Find files" })

map("n", "<leader>fg", function()
  require("telescope.builtin").live_grep()
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
map("n", "<leader>cd", vim.diagnostic.open_float, { desc = "Line diagnostics" })
map("n", "]h", function()
  goto_git_change("next")
end, { desc = "Next Git change" })
map("n", "[h", function()
  goto_git_change("prev")
end, { desc = "Previous Git change" })
