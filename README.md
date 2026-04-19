# Aeris

[中文文档](./README.zh-CN.md)

Aeris is a modern IDE-style Neovim configuration focused on being usable immediately after cloning.

Goals:

- clone and launch with minimal setup
- install plugins automatically on first start
- install common LSP servers and formatters automatically on first start
- provide a ready-to-use layout with a file tree, top tabs, terminal panel, and workspace Git panel

## Features

- file tree
- top buffer tab bar
- bottom multi-terminal workflow
- multi-repo Git workspace panel
- code navigation, hover, references, and rename
- LSP, Treesitter, formatting, and completion
- Git workflow with Codex-generated commit messages
- Markdown rendering support

## Screenshots

Code editing interface:

![Code editing interface](./assets/1.png)

Git workspace interface:

![Git workspace interface](./assets/2.png)

## Requirements

Base requirements:

- Neovim `>= 0.12`
- `git`
- `ripgrep`
- a terminal configured with a Nerd Font

Recommended for language tooling:

- `node`
- `python3`
- `go`

## Installation

### Option 1: clone directly into `~/.config/nvim`

```bash
git clone https://github.com/Tony7817/aeris.git ~/.config/nvim
nvim
```

### Option 2: clone elsewhere and symlink to `~/.config/nvim`

```bash
git clone https://github.com/Tony7817/aeris.git ~/Code/Aeris
cd ~/Code/Aeris
./bin/install.sh
nvim
```

`bin/install.sh` will:

- back up an existing `~/.config/nvim`
- symlink the current repo to `~/.config/nvim`

## First Launch

The first time you open `nvim`, Aeris will automatically:

1. bootstrap `lazy.nvim`
2. install plugins
3. install Mason-managed LSP servers, formatters, and CLI tools

To install or reinstall Mason tools manually:

```vim
:MasonToolsInstall
```

To inspect plugin and tool status:

```vim
:Lazy
:Mason
:checkhealth
```

## Daily Usage

### Open a project

```bash
cd /path/to/project
nvim .
```

Default layout:

- left: file tree
- right: file contents
- top: recently used file tabs

### Common workflow

Find a file:

```text
Space ff
```

Search text globally:

```text
Space fg
```

Open a terminal:

```text
Space tt
```

Open the Git workspace:

```text
Space gw
```

Go to definition / find references:

```text
gd
gr
```

Jump back after navigation:

```text
Ctrl-o
```

## Leader Key

The `leader` key is set to `Space`.

That means:

- `Space ff` means press `Space`, then `f`, then `f`
- `Space gw` means press `Space`, then `g`, then `w`

## Keymap Reference

### General

| Key | Action |
| --- | --- |
| `Esc` | Clear search highlight |
| `Space w` | Save current file |
| `Space q` | Close current window |
| `Space Q` | Force quit Neovim |

### Files and Search

| Key | Action |
| --- | --- |
| `Space e` | Show / hide file tree |
| `Space E` | Focus file tree |
| `Space ff` | Find files |
| `Space fg` | Search text globally |
| `Space fb` | Open buffer list |
| `Space fr` | Open recent files |
| `Space fd` | Open diagnostics list |

### Tabs and Buffers

| Key | Action |
| --- | --- |
| `Tab` | Next file tab |
| `Shift-Tab` | Previous file tab |
| `Space 1` to `Space 9` | Jump to file tab 1 to 9 |
| `Space bd` | Close current buffer |

### Window Navigation

| Key | Action |
| --- | --- |
| `Option-h` | Focus left window |
| `Option-j` | Focus lower window |
| `Option-k` | Focus upper window |
| `Option-l` | Focus right window |
| `Ctrl-h` | Focus left window |
| `Ctrl-j` | Focus lower window |
| `Ctrl-k` | Focus upper window |
| `Ctrl-l` | Focus right window |

### Terminal

| Key | Action |
| --- | --- |
| `Space tt` | Create a new terminal |
| `Space tl` | Focus / toggle terminal list |
| `Esc Esc` | Leave terminal insert mode |

### Git

| Key | Action |
| --- | --- |
| `Space gw` | Open the workspace Git panel |
| `Space gd` | Open `diffview` |
| `Space gh` | View current file history |
| `Space gq` | Close `diffview` |
| `Space gx` | Exit the Git workspace |
| `]h` | Next Git change |
| `[h` | Previous Git change |

### LSP and Code Navigation

These mappings are available after an LSP client attaches to the current file.

| Key | Action |
| --- | --- |
| `<F12>` | Prefer implementation, otherwise definition |
| `gd` | Go to definition |
| `gr` | Find references |
| `gI` | Go to implementation |
| `K` | Hover documentation |
| `Space ds` | Document symbols |
| `Space ca` | Code action |
| `Space rn` | Rename symbol |
| `Space cf` | Format current file |
| `Ctrl-o` | Jump back |
| `Ctrl-i` | Jump forward |

### Diagnostics

| Key | Action |
| --- | --- |
| `[d` | Previous diagnostic |
| `]d` | Next diagnostic |
| `Space cd` | Line diagnostic popup |

## Repository Structure

```text
.
├── AGENTS.md
├── README.md
├── README.zh-CN.md
├── bin
│   └── install.sh
├── init.lua
├── lazy-lock.json
└── lua
    ├── config
    │   ├── autocmds.lua
    │   ├── git_workspace.lua
    │   ├── keymaps.lua
    │   ├── lazy.lua
    │   ├── options.lua
    │   ├── references.lua
    │   └── terminals.lua
    └── plugins
        └── init.lua
```

## Language Support

These language servers are installed and enabled by default:

- Bash
- Go
- JSON
- Lua
- Markdown
- Python
- SQL
- TypeScript / Vue
- YAML

If `sourcekit-lsp` is available on the system, Swift is also enabled automatically.

## Notes

- Plugin versions are locked in `lazy-lock.json`
- This repository has its own `AGENTS.md`
- By repository rule, every change must be committed
