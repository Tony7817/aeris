local uv = vim.uv

local function workspace_name()
  local cwd = vim.fn.getcwd(-1, -1)
  if cwd == nil or cwd == "" then
    return "[no-cwd]"
  end

  local name = vim.fs.basename(cwd)
  return name ~= "" and name or cwd
end

local function telescope_selected_path()
  local path = vim.g.aeris_telescope_status_path
  if type(path) ~= "string" or path == "" then
    return ""
  end

  return path
end

local function telescope_path_visible()
  return telescope_selected_path() ~= ""
end

local function git_workspace_selected_path()
  local path = vim.g.aeris_git_workspace_status_path
  local tabpage = vim.g.aeris_git_workspace_status_tab
  if type(path) ~= "string" or path == "" then
    return ""
  end

  if tabpage ~= vim.api.nvim_get_current_tabpage() then
    return ""
  end

  return path
end

local function git_workspace_path_visible()
  return git_workspace_selected_path() ~= ""
end

local function git_workspace_sidebar_focused()
  if not git_workspace_path_visible() then
    return false
  end

  return vim.bo[vim.api.nvim_get_current_buf()].filetype == "erwin-git-workspace"
end

local function git_workspace_branch()
  local ok, git_workspace = pcall(require, "config.git_workspace")
  if not ok or type(git_workspace.statusline_branch) ~= "function" then
    return ""
  end

  return git_workspace.statusline_branch() or ""
end

local function git_workspace_branch_visible()
  return git_workspace_branch() ~= ""
end

local statusline_branch_cache = {}
local BRANCH_CACHE_TTL_MS = 1500

local function current_workspace_path()
  local cwd = vim.fn.getcwd(-1, -1)
  if type(cwd) ~= "string" or cwd == "" then
    return nil
  end

  return vim.fs.normalize(vim.fn.fnamemodify(cwd, ":p"))
end

local function git_root_for_path(path)
  if type(path) ~= "string" or path == "" then
    return nil
  end

  local target = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
  if target == nil or target == "" then
    return nil
  end

  local cwd = vim.fn.isdirectory(target) == 1 and target or vim.fs.dirname(target)
  if type(cwd) ~= "string" or cwd == "" then
    return nil
  end

  local result = vim.system({ "git", "-C", cwd, "rev-parse", "--show-toplevel" }, {
    text = true,
  }):wait()

  if result.code ~= 0 then
    return nil
  end

  local root = vim.trim(result.stdout or "")
  if root == "" then
    return nil
  end

  return vim.fs.normalize(root)
end

local function cached_git_branch(path)
  if type(path) ~= "string" or path == "" then
    return ""
  end

  local now_ms = uv.hrtime() / 1000000
  local cached = statusline_branch_cache[path]
  if cached and (now_ms - cached.ts) < BRANCH_CACHE_TTL_MS then
    return cached.branch
  end

  local branch = ""
  local result = vim.system({ "git", "-C", path, "branch", "--show-current" }, {
    text = true,
  }):wait()

  if result.code == 0 then
    branch = vim.trim(result.stdout or "")
  end

  if branch == "" then
    local detached = vim.system({ "git", "-C", path, "rev-parse", "--short", "HEAD" }, {
      text = true,
    }):wait()
    if detached.code == 0 then
      branch = vim.trim(detached.stdout or "")
    end
  end

  statusline_branch_cache[path] = {
    branch = branch,
    ts = now_ms,
  }
  return branch
end

local function statusline_branch()
  local branch = git_workspace_branch()
  if branch ~= "" then
    return branch
  end

  local cwd = current_workspace_path()
  if cwd == nil then
    return ""
  end

  return cached_git_branch(cwd)
end

local function statusline_branch_visible()
  return statusline_branch() ~= ""
end

local function blame_branch()
  local bufnr = vim.api.nvim_get_current_buf()
  if vim.api.nvim_buf_is_valid(bufnr) then
    local name = vim.api.nvim_buf_get_name(bufnr)
    local root = git_root_for_path(name)
    if root ~= nil then
      local branch = cached_git_branch(root)
      if branch ~= "" then
        return branch
      end
    end
  end

  return statusline_branch()
end

local function shorten_blame_summary(summary, max_chars)
  summary = vim.trim(summary or "")
  if summary == "" then
    return "No commit summary"
  end

  max_chars = max_chars or 40
  if vim.fn.strchars(summary) <= max_chars then
    return summary
  end

  return vim.fn.strcharpart(summary, 0, max_chars - 1) .. "…"
end

local function format_blame_time(author_time)
  if type(author_time) ~= "number" or author_time <= 0 then
    return nil
  end

  return os.date("%Y-%m-%d %H:%M", author_time)
end

local function format_current_line_blame(_, blame_info)
  local author = vim.trim(blame_info.author or "")
  local branch = blame_branch()
  if author ~= "" and branch ~= "" then
    author = string.format("%s(%s)", author, branch)
  end

  local timestamp = format_blame_time(blame_info.author_time)
  local prefix = author ~= "" and author or (blame_info.author or "")
  if timestamp then
    prefix = string.format("%s • %s", prefix, timestamp)
  end

  return {
    {
      string.format(" %s • %s ", prefix, shorten_blame_summary(blame_info.summary, 44)),
      "GitSignsCurrentLineBlame",
    },
  }
end

local function show_in_bufferline(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end

  local name = vim.api.nvim_buf_get_name(bufnr)
  local filetype = vim.bo[bufnr].filetype
  local buftype = vim.bo[bufnr].buftype

  if name == "" then
    return false
  end

  if vim.startswith(name, "git://") or vim.startswith(name, "git-workspace://") then
    return false
  end

  if filetype == "NvimTree" or filetype == "erwin-terminals" or filetype == "erwin-git-workspace" or filetype == "qf" then
    return false
  end

  if buftype ~= "" then
    return false
  end

  return true
end

local function buffer_last_used(buffer)
  local target = type(buffer) == "table" and (buffer.id or buffer.bufnr or buffer.ordinal) or buffer
  local info = vim.fn.getbufinfo(target)[1]
  return info and info.lastused or 0
end

return {
  {
    "catppuccin/nvim",
    name = "catppuccin",
    lazy = false,
    priority = 1000,
    config = function()
      require("catppuccin").setup({
        flavour = "mocha",
        background = {
          light = "latte",
          dark = "mocha",
        },
      })
      vim.opt.background = "dark"
      vim.cmd.colorscheme("catppuccin")
    end,
  },
  {
    "nvim-tree/nvim-web-devicons",
    lazy = true,
  },
  {
    "MeanderingProgrammer/render-markdown.nvim",
    ft = { "markdown" },
    cmd = { "RenderMarkdown" },
    dependencies = {
      "nvim-treesitter/nvim-treesitter",
      "nvim-tree/nvim-web-devicons",
    },
    opts = {
      enabled = false,
      file_types = { "markdown" },
      render_modes = { "n", "c", "t" },
      completions = {
        lsp = {
          enabled = true,
        },
      },
    },
  },
  {
    "iamcco/markdown-preview.nvim",
    ft = { "markdown" },
    cmd = {
      "MarkdownPreview",
      "MarkdownPreviewStop",
      "MarkdownPreviewToggle",
    },
    build = "cd app && npm install",
    init = function()
      vim.g.mkdp_auto_start = 0
      vim.g.mkdp_auto_close = 1
      vim.g.mkdp_echo_preview_url = 1
      vim.g.mkdp_markdown_css = vim.fn.stdpath("config") .. "/after/markdown-preview.css"
      vim.g.mkdp_preview_options = {
        uml = {
          imageFormat = "svg",
        },
        maid = {
          flowchart = {
            useMaxWidth = false,
          },
          sequence = {
            useMaxWidth = false,
          },
          gantt = {
            useMaxWidth = false,
          },
        },
      }
      vim.g.mkdp_refresh_slow = 0
      vim.g.mkdp_browser = ""
      vim.g.mkdp_filetypes = { "markdown" }
      vim.g.mkdp_theme = "dark"
    end,
  },
  {
    "nvim-lualine/lualine.nvim",
    dependencies = { "nvim-tree/nvim-web-devicons" },
    opts = {
      options = {
        theme = "auto",
        globalstatus = true,
        section_separators = "",
        component_separators = "|",
      },
      sections = {
        lualine_a = { "mode" },
        lualine_b = {
          workspace_name,
          {
            git_workspace_selected_path,
            cond = git_workspace_path_visible,
          },
          {
            statusline_branch,
            cond = statusline_branch_visible,
          },
        },
        lualine_c = {
          {
            "filename",
            cond = function()
              return not telescope_path_visible() and not git_workspace_sidebar_focused()
            end,
          },
          {
            telescope_selected_path,
            cond = telescope_path_visible,
          },
        },
        lualine_x = { "encoding", "fileformat", "filetype" },
        lualine_y = { "progress" },
        lualine_z = { "location" },
      },
    },
  },
  {
    "akinsho/bufferline.nvim",
    version = "*",
    dependencies = { "nvim-tree/nvim-web-devicons" },
    opts = function()
      return {
        highlights = require("catppuccin.special.bufferline").get_theme(),
        options = {
          always_show_bufferline = true,
          hover = {
            enabled = true,
            delay = 120,
            reveal = { "close" },
          },
          max_name_length = 28,
          max_prefix_length = 18,
          separator_style = "thin",
          show_buffer_close_icons = false,
          show_close_icon = false,
          sort_by = function(buffer_a, buffer_b)
            return buffer_last_used(buffer_a) > buffer_last_used(buffer_b)
          end,
          custom_filter = show_in_bufferline,
          offsets = {
            {
              filetype = "NvimTree",
              text = "Files",
              highlight = "Directory",
              text_align = "left",
              separator = true,
            },
          },
        },
      }
    end,
  },
  {
    "folke/which-key.nvim",
    event = "VeryLazy",
    opts = {
      preset = "helix",
      delay = 300,
      spec = {
        { "<leader>b", group = "Buffers" },
        { "<leader>c", group = "Code" },
        { "<leader>f", group = "Find" },
        { "<leader>g", group = "Git" },
        { "<leader>m", group = "Markdown" },
        { "<leader>t", group = "Terminal" },
      },
    },
  },
  {
    "numToStr/Comment.nvim",
    opts = {
      toggler = {
        block = "gBC",
      },
      opleader = {
        block = "gB",
      },
    },
  },
  {
    "windwp/nvim-autopairs",
    event = "InsertEnter",
    opts = {},
  },
  {
    "nvim-tree/nvim-tree.lua",
    dependencies = { "nvim-tree/nvim-web-devicons" },
    opts = {
      actions = {
        open_file = {
          quit_on_open = false,
          resize_window = false,
        },
        remove_file = {
          close_window = false,
        },
      },
      filters = {
        dotfiles = false,
      },
      git = {
        ignore = false,
      },
      hijack_directories = {
        enable = true,
        auto_open = false,
      },
      hijack_cursor = true,
      renderer = {
        group_empty = true,
        full_name = false,
        highlight_git = true,
        root_folder_label = false,
        indent_markers = {
          enable = true,
        },
      },
      sync_root_with_cwd = true,
      update_focused_file = {
        enable = true,
        update_root = true,
      },
      view = {
        preserve_window_proportions = false,
        side = "left",
        signcolumn = "yes",
        width = function()
          return require("config.tree_width").get()
        end,
      },
    },
  },
  {
    "akinsho/toggleterm.nvim",
    version = "*",
    lazy = false,
    opts = {
      direction = "horizontal",
      close_on_exit = false,
      highlights = {
        Normal = {
          guibg = "#1F2428",
        },
        EndOfBuffer = {
          guibg = "#1F2428",
        },
        SignColumn = {
          guibg = "#1F2428",
        },
        StatusLine = {
          guibg = "#1F2428",
        },
        StatusLineNC = {
          guibg = "#1F2428",
        },
        NormalFloat = {
          guibg = "#1F2428",
        },
        FloatBorder = {
          guibg = "#1F2428",
        },
      },
      persist_size = false,
      persist_mode = true,
      shade_terminals = false,
      start_in_insert = true,
      size = function()
        return require("config.terminals").current_height()
      end,
    },
  },
  {
    "lewis6991/gitsigns.nvim",
    event = { "BufReadPre", "BufNewFile" },
    opts = {
      signcolumn = true,
      numhl = false,
      linehl = false,
      signs = {
        add = { text = "│" },
        change = { text = "│" },
        delete = { text = "▔" },
        topdelete = { text = "▔" },
        changedelete = { text = "│" },
        untracked = { text = "│" },
      },
      current_line_blame = true,
      current_line_blame_opts = {
        delay = 0,
        use_focus = true,
        virt_text_pos = "eol",
      },
      current_line_blame_formatter = format_current_line_blame,
      current_line_blame_formatter_nc = " Not committed yet ",
    },
  },
  {
    "petertriho/nvim-scrollbar",
    event = { "BufReadPre", "BufNewFile" },
    dependencies = {
      "lewis6991/gitsigns.nvim",
    },
    config = function()
      require("scrollbar").setup({
        hide_if_all_visible = false,
        set_highlights = false,
        show_in_active_only = false,
        handle = {
          blend = 0,
          color = nil,
          highlight = "ScrollbarHandle",
          hide_if_all_visible = false,
          text = " ",
        },
        marks = {
          Cursor = {
            color = nil,
            gui = nil,
            highlight = "ScrollbarCursor",
            priority = 0,
            text = "•",
          },
          GitAdd = {
            color = nil,
            gui = nil,
            highlight = "ScrollbarGitAdd",
            priority = 7,
            text = "▏",
          },
          GitChange = {
            color = nil,
            gui = nil,
            highlight = "ScrollbarGitChange",
            priority = 7,
            text = "▏",
          },
          GitDelete = {
            color = nil,
            gui = nil,
            highlight = "ScrollbarGitDelete",
            priority = 7,
            text = "▏",
          },
        },
        excluded_buftypes = {
          "prompt",
          "terminal",
        },
        excluded_filetypes = {
          "DressingInput",
          "NvimTree",
          "TelescopePrompt",
          "blink-cmp-menu",
          "cmp_docs",
          "cmp_menu",
          "dropbar_menu",
          "dropbar_menu_fzf",
          "erwin-git-workspace",
          "erwin-reference-preview",
          "erwin-references",
          "erwin-terminals",
          "noice",
        },
        handlers = {
          ale = false,
          cursor = true,
          diagnostic = false,
          gitsigns = true,
          handle = true,
          search = false,
        },
      })

      require("scrollbar.handlers.gitsigns").setup()
    end,
  },
  {
    "nvim-telescope/telescope.nvim",
    branch = "0.1.x",
    cmd = "Telescope",
    dependencies = {
      "nvim-lua/plenary.nvim",
      "nvim-tree/nvim-web-devicons",
      {
        "nvim-telescope/telescope-fzf-native.nvim",
        build = "make",
      },
    },
    opts = {
      defaults = {
        prompt_prefix = "> ",
        selection_caret = "> ",
        sorting_strategy = "ascending",
        layout_config = {
          prompt_position = "top",
        },
        file_ignore_patterns = {
          "%.git/",
          "node_modules/",
          "dist/",
          "%.venv/",
          "%.tmp/",
          "DerivedData/",
        },
      },
      extensions = {
        fzf = {
          fuzzy = true,
          override_file_sorter = true,
          override_generic_sorter = true,
          case_mode = "smart_case",
        },
      },
      pickers = {
        find_files = {
          hidden = true,
        },
      },
    },
    config = function(_, opts)
      local ok, ts_parsers = pcall(require, "nvim-treesitter.parsers")
      if ok and ts_parsers.ft_to_lang == nil then
        ts_parsers.ft_to_lang = function(filetype)
          return vim.treesitter.language.get_lang(filetype) or filetype
        end
      end
      if ok and ts_parsers.get_parser == nil then
        ts_parsers.get_parser = function(bufnr, lang)
          return vim.treesitter.get_parser(bufnr, lang)
        end
      end

      if package.loaded["nvim-treesitter.configs"] == nil then
        package.preload["nvim-treesitter.configs"] = function()
          local modules = {
            highlight = {
              additional_vim_regex_highlighting = false,
            },
          }

          return {
            get_module = function(name)
              return modules[name] or {}
            end,
            is_enabled = function(name, lang, bufnr)
              if name ~= "highlight" then
                return false
              end

              local ok_parser, parser = pcall(vim.treesitter.get_parser, bufnr, lang)
              return ok_parser and parser ~= nil
            end,
            setup = function(user_modules)
              if type(user_modules) ~= "table" then
                return
              end

              for name, module_opts in pairs(user_modules) do
                modules[name] = vim.tbl_deep_extend("force", modules[name] or {}, module_opts)
              end
            end,
          }
        end
      end

      require("telescope").setup(opts)
      pcall(require("telescope").load_extension, "fzf")
    end,
  },
  {
    "HiPhish/rainbow-delimiters.nvim",
    event = { "BufReadPost", "BufNewFile" },
    config = function()
      local rainbow_delimiters = require("rainbow-delimiters")

      vim.g.rainbow_delimiters = {
        strategy = {
          [""] = rainbow_delimiters.strategy["global"],
        },
        query = {
          [""] = "rainbow-delimiters",
        },
        highlight = {
          "RainbowDelimiterAeris1",
          "RainbowDelimiterAeris2",
        },
      }
    end,
  },
  {
    "nvim-treesitter/nvim-treesitter",
    lazy = false,
    build = function()
      if vim.fn.executable("tree-sitter") == 1 then
        vim.cmd("TSUpdate")
      end
    end,
    opts = {
      ensure_installed = {
        "bash",
        "css",
        "dockerfile",
        "go",
        "gomod",
        "gosum",
        "gotmpl",
        "html",
        "javascript",
        "json",
        "lua",
        "markdown",
        "markdown_inline",
        "proto",
        "python",
        "query",
        "regex",
        "sql",
        "swift",
        "toml",
        "tsx",
        "typescript",
        "vim",
        "vimdoc",
        "vue",
        "yaml",
      },
    },
    config = function(_, opts)
      local treesitter = require("nvim-treesitter")
      local can_install_parsers = vim.fn.executable("tree-sitter") == 1

      treesitter.setup({
        install_dir = vim.fn.stdpath("data") .. "/site",
      })

      local installed = {}
      for _, lang in ipairs(treesitter.get_installed("parsers")) do
        installed[lang] = true
      end

      local missing = {}
      for _, lang in ipairs(opts.ensure_installed) do
        if not installed[lang] then
          table.insert(missing, lang)
        end
      end

      if #missing > 0 then
        if can_install_parsers then
          vim.schedule(function()
            pcall(treesitter.install, missing, { summary = true })
          end)
        else
          vim.schedule(function()
            vim.notify_once(
              "tree-sitter CLI not found; skipping parser installation. Install `tree-sitter` to enable automatic Treesitter parser setup.",
              vim.log.levels.WARN
            )
          end)
        end
      end
    end,
  },
  {
    "hrsh7th/nvim-cmp",
    event = "InsertEnter",
    dependencies = {
      "L3MON4D3/LuaSnip",
      "saadparwaiz1/cmp_luasnip",
      "rafamadriz/friendly-snippets",
      "hrsh7th/cmp-nvim-lsp",
      "hrsh7th/cmp-buffer",
      "hrsh7th/cmp-path",
    },
    config = function()
      local cmp = require("cmp")
      local luasnip = require("luasnip")

      require("luasnip.loaders.from_vscode").lazy_load()

      cmp.setup({
        snippet = {
          expand = function(args)
            luasnip.lsp_expand(args.body)
          end,
        },
        completion = {
          completeopt = "menu,menuone,noinsert",
        },
        window = {
          completion = cmp.config.window.bordered(),
          documentation = cmp.config.window.bordered(),
        },
        mapping = cmp.mapping.preset.insert({
          ["<C-Space>"] = cmp.mapping.complete(),
          ["<CR>"] = cmp.mapping.confirm({ select = true }),
          ["<Tab>"] = cmp.mapping(function(fallback)
            if cmp.visible() then
              cmp.select_next_item()
              return
            end

            if luasnip.expand_or_locally_jumpable() then
              luasnip.expand_or_jump()
              return
            end

            fallback()
          end, { "i", "s" }),
          ["<S-Tab>"] = cmp.mapping(function(fallback)
            if cmp.visible() then
              cmp.select_prev_item()
              return
            end

            if luasnip.locally_jumpable(-1) then
              luasnip.jump(-1)
              return
            end

            fallback()
          end, { "i", "s" }),
        }),
        sources = cmp.config.sources({
          { name = "nvim_lsp" },
          { name = "luasnip" },
          { name = "path" },
        }, {
          { name = "buffer" },
        }),
      })
    end,
  },
  {
    "folke/lazydev.nvim",
    ft = "lua",
    opts = {
      library = {
        { path = "${3rd}/luv/library", words = { "vim%.uv" } },
      },
    },
  },
  {
    "mason-org/mason.nvim",
    cmd = "Mason",
    opts = {
      ui = {
        border = "rounded",
      },
    },
  },
  {
    "mason-org/mason-lspconfig.nvim",
    dependencies = { "mason-org/mason.nvim" },
    opts = {
      automatic_enable = false,
      ensure_installed = {
        "bashls",
        "gopls",
        "jsonls",
        "lua_ls",
        "marksman",
        "pyright",
        "sqls",
        "vtsls",
        "vue_ls",
        "yamlls",
      },
    },
  },
  {
    "WhoIsSethDaniel/mason-tool-installer.nvim",
    cmd = {
      "MasonToolsInstall",
      "MasonToolsInstallSync",
      "MasonToolsUpdate",
      "MasonToolsUpdateSync",
      "MasonToolsClean",
    },
    dependencies = {
      "mason-org/mason.nvim",
      "mason-org/mason-lspconfig.nvim",
    },
    opts = {
      ensure_installed = {
        "bash-language-server",
        "gofumpt",
        "goimports",
        "gopls",
        "json-lsp",
        "lua-language-server",
        "markdownlint-cli2",
        "marksman",
        "prettierd",
        "pyright",
        "ruff",
        "shellcheck",
        "shfmt",
        "sql-formatter",
        "sqls",
        "stylua",
        "vtsls",
        "vue-language-server",
        "yaml-language-server",
      },
      auto_update = false,
      run_on_start = true,
      start_delay = 2500,
      debounce_hours = 12,
      integrations = {
        ["mason-lspconfig"] = true,
      },
    },
  },
  {
    "neovim/nvim-lspconfig",
    lazy = false,
    dependencies = {
      "folke/lazydev.nvim",
      "hrsh7th/cmp-nvim-lsp",
      "mason-org/mason.nvim",
      "mason-org/mason-lspconfig.nvim",
    },
    config = function()
      local capabilities = require("cmp_nvim_lsp").default_capabilities(
        vim.lsp.protocol.make_client_capabilities()
      )

      vim.diagnostic.config({
        severity_sort = true,
        float = {
          border = "rounded",
          source = "if_many",
        },
      })

      local function on_attach(client, bufnr)
        local disable_formatting = {
          jsonls = true,
          vtsls = true,
          vue_ls = true,
          yamlls = true,
        }

        if disable_formatting[client.name] then
          client.server_capabilities.documentFormattingProvider = false
          client.server_capabilities.documentRangeFormattingProvider = false
        end

        if client:supports_method("textDocument/inlayHint", bufnr) then
          pcall(vim.lsp.inlay_hint.enable, false, { bufnr = bufnr })
        end
      end

      local vue_plugin_path = vim.fn.stdpath("data")
        .. "/mason/packages/vue-language-server/node_modules/@vue/language-server"
      local vue_plugin = nil
      if vim.uv.fs_stat(vue_plugin_path) then
        vue_plugin = {
          configNamespace = "typescript",
          languages = { "vue" },
          location = vue_plugin_path,
          name = "@vue/typescript-plugin",
        }
      end

      local servers = {
        bashls = {},
        gopls = {
          settings = {
            gopls = {
              directoryFilters = {
                "-.git",
                "-.cache",
                "-**/.cache",
                "-**/node_modules",
                "-**/dist",
                "-**/build",
                "-**/tmp",
              },
              analyses = {
                shadow = true,
                unusedparams = true,
                unusedwrite = true,
              },
              gofumpt = true,
              hints = {
                assignVariableTypes = true,
                compositeLiteralFields = true,
                compositeLiteralTypes = true,
                constantValues = true,
                functionTypeParameters = true,
                parameterNames = true,
                rangeVariableTypes = true,
              },
              staticcheck = true,
              usePlaceholders = true,
            },
          },
        },
        jsonls = {},
        lua_ls = {
          settings = {
            Lua = {
              completion = {
                callSnippet = "Replace",
              },
              diagnostics = {
                globals = { "vim" },
              },
              telemetry = {
                enable = false,
              },
              workspace = {
                checkThirdParty = false,
              },
            },
          },
        },
        marksman = {},
        pyright = {},
        sqls = {},
        vtsls = {
          filetypes = {
            "javascript",
            "javascriptreact",
            "typescript",
            "typescriptreact",
            "vue",
          },
          settings = {
            vtsls = {
              tsserver = {
                globalPlugins = vue_plugin and { vue_plugin } or {},
              },
            },
          },
        },
        vue_ls = {},
        yamlls = {
          settings = {
            yaml = {
              keyOrdering = false,
            },
          },
        },
      }

      for name, config in pairs(servers) do
        config.capabilities = vim.tbl_deep_extend("force", {}, capabilities, config.capabilities or {})
        config.on_attach = on_attach
        vim.lsp.config(name, config)
        vim.lsp.enable(name)
      end

      if vim.fn.executable("sourcekit-lsp") == 1 then
        vim.lsp.config("sourcekit", {
          capabilities = capabilities,
          on_attach = on_attach,
        })
        vim.lsp.enable("sourcekit")
      end
    end,
  },
  {
    "stevearc/conform.nvim",
    event = { "BufWritePre" },
    cmd = { "ConformInfo" },
    opts = {
      notify_on_error = true,
      format_on_save = function(bufnr)
        local enabled = {
          bash = true,
          go = true,
          javascript = true,
          javascriptreact = true,
          json = true,
          jsonc = true,
          lua = true,
          markdown = true,
          python = true,
          sh = true,
          sql = true,
          typescript = true,
          typescriptreact = true,
          vue = true,
          yaml = true,
          zsh = true,
        }

        if not enabled[vim.bo[bufnr].filetype] then
          return nil
        end

        return {
          timeout_ms = 2000,
          lsp_fallback = true,
        }
      end,
      formatters_by_ft = {
        go = { "goimports", "gofumpt" },
        javascript = { "prettierd", "prettier" },
        javascriptreact = { "prettierd", "prettier" },
        json = { "prettierd", "prettier" },
        jsonc = { "prettierd", "prettier" },
        lua = { "stylua" },
        markdown = { "prettierd", "prettier" },
        python = { "ruff_format", "black" },
        sh = { "shfmt" },
        sql = { "sql_formatter" },
        typescript = { "prettierd", "prettier" },
        typescriptreact = { "prettierd", "prettier" },
        vue = { "prettierd", "prettier" },
        yaml = { "prettierd", "prettier" },
        zsh = { "shfmt" },
      },
    },
  },
}
