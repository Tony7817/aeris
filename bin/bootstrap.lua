-- Run by install.sh after system dependencies and the config link are ready.
local ok, err = xpcall(function()
  local plugins = require("lazy.core.config").plugins
  local function opts(name)
    return require("lazy.core.plugin").values(assert(plugins[name], "Missing plugin: " .. name), "opts", false)
  end

  print("Installing Neovim plugins...")
  require("lazy").install({ wait = true })
  for name, plugin in pairs(plugins) do
    assert(plugin._.installed, "Plugin not installed: " .. name)
    for _, task in ipairs(plugin._.tasks or {}) do
      assert(not task:has_errors(), "Plugin task failed: " .. name .. " " .. task.name)
    end
  end

  print("Installing language servers and formatters...")
  local mason_opts = vim.deepcopy(opts("mason-tool-installer.nvim"))
  mason_opts.run_on_start = false
  mason_opts.debounce_hours = nil
  require("mason-tool-installer").setup(mason_opts)
  vim.cmd("MasonToolsInstallSync")
  local registry = require("mason-registry")
  for _, name in ipairs(mason_opts.ensure_installed) do
    assert(registry.is_installed(name), "Mason tool not installed: " .. name)
  end

  print("Installing Treesitter parsers...")
  local treesitter = require("nvim-treesitter")
  local installed = treesitter.get_installed("parsers")
  local missing = vim.tbl_filter(function(lang)
    return not vim.tbl_contains(installed, lang)
  end, opts("nvim-treesitter").ensure_installed)
  if #missing > 0 then
    assert(treesitter.install(missing, { summary = true }):wait(600000), "Treesitter parser installation failed")
  end
end, debug.traceback)

if not ok then
  io.stderr:write("Installation failed: " .. tostring(err) .. "\n")
  vim.cmd("cquit 1")
end
