vim.g.mapleader = " "
vim.g.maplocalleader = ","

if vim.list == nil then
  vim.list = {}
end

if vim.list.unique == nil then
  function vim.list.unique(items)
    local seen = {}
    local result = {}

    for _, item in ipairs(items) do
      if not seen[item] then
        seen[item] = true
        table.insert(result, item)
      end
    end

    return result
  end
end

local opt = vim.opt

opt.number = true
opt.relativenumber = true
opt.mouse = "a"
opt.showmode = false
opt.showcmd = false
opt.clipboard = "unnamedplus"
opt.breakindent = true
opt.undofile = true
opt.hidden = true
opt.ignorecase = true
opt.smartcase = true
opt.signcolumn = "yes"
opt.showtabline = 2
opt.updatetime = 250
opt.timeoutlen = 300
opt.splitright = true
opt.splitbelow = true
opt.inccommand = "split"
opt.cursorline = true
opt.scrolloff = 6
opt.sidescrolloff = 8
opt.list = true
opt.listchars = {
  tab = "> ",
  trail = ".",
  nbsp = "+",
}
opt.expandtab = true
opt.shiftwidth = 2
opt.tabstop = 2
opt.softtabstop = 2
opt.smartindent = true
opt.wrap = false
opt.linebreak = true
opt.termguicolors = true
opt.confirm = true
opt.cmdheight = 0
opt.ruler = false
opt.completeopt = {
  "menu",
  "menuone",
  "noselect",
}
opt.fillchars = {
  eob = " ",
  horiz = "─",
  horizdown = "┬",
  horizup = "┴",
  vert = "│",
  verthoriz = "┼",
  vertleft = "┤",
  vertright = "├",
}
opt.winborder = "rounded"

vim.filetype.add({
  extension = {
    api = "goctlapi",
    tpl = "gotmpl",
  },
})

vim.treesitter.language.register("bash", { "sh", "zsh" })
vim.treesitter.language.register("json", { "jsonc" })
