local map = vim.keymap.set

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

map("n", "<Esc>", "<cmd>nohlsearch<CR>", { desc = "Clear search highlight" })
map("n", "<leader>w", "<cmd>write<CR>", { desc = "Write buffer" })
map("n", "<leader>q", "<cmd>quit<CR>", { desc = "Quit window" })
map("n", "<leader>Q", "<cmd>qa!<CR>", { desc = "Quit all" })
map("n", "<D-Left>", "<C-o>", { desc = "Jump back" })
map("n", "<D-Right>", "<C-i>", { desc = "Jump forward" })
map("n", "<leader>e", "<cmd>NvimTreeToggle<CR>", { desc = "Toggle file tree" })
map("n", "<leader>E", "<cmd>NvimTreeFocus<CR>", { desc = "Focus file tree" })
map("n", "<Tab>", "<cmd>BufferLineCycleNext<CR>", { desc = "Next buffer tab" })
map("n", "<S-Tab>", "<cmd>BufferLineCyclePrev<CR>", { desc = "Previous buffer tab" })
map("n", "<leader>bd", "<cmd>bdelete<CR>", { desc = "Close buffer" })
map("n", "<leader>gd", "<cmd>DiffviewOpen<CR>", { desc = "Open diff view" })
map("n", "<leader>gh", "<cmd>DiffviewFileHistory %<CR>", { desc = "Current file history" })
map("n", "<leader>gq", "<cmd>DiffviewClose<CR>", { desc = "Close diff view" })
map("n", "<leader>gx", function()
  local ok, git_workspace = pcall(require, "config.git_workspace")
  if ok and git_workspace and git_workspace.close then
    git_workspace.close()
    return
  end

  vim.cmd("DiffviewClose")
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
