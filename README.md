# Tony's Neovim Config

一套偏现代 IDE 工作流的 Neovim 配置。

目标很直接：

- clone 下来就能启动
- 首次启动自动安装插件
- 首次启动自动安装常用 LSP / formatter
- 左侧文件树、顶部文件 tab、底部 terminal、工作区 Git 面板开箱即用

## 效果概览

这套配置默认提供：

- `catppuccin` 主题
- 左侧固定窄文件树
- 顶部 buffer tab 栏
- 底部 terminal + terminal 列表
- 多仓库 Git workspace
- `gr` 引用面板，左侧列表 + 右侧代码片段预览
- 右侧细滚动条，包含当前光标位置和 Git 变更标记
- LSP / Treesitter / 格式化 / 补全

## 系统要求

建议至少满足这些基础条件：

- Neovim `>= 0.12`
- `git`
- `ripgrep`
- Nerd Font 终端字体

为了让语言工具真正开箱即用，建议同时装这些运行时：

- `node`，给 `vtsls`、`vue-language-server`、`prettierd` 这类 JS 工具用
- `python3`，给部分 Python 工具链用
- `go`，给 Go 生态工具链用

## 安装

### 方式一：直接把仓库 clone 到 Neovim 目录

```bash
git clone <your-repo-url> ~/.config/nvim
nvim
```

### 方式二：仓库放别处，再一键链接到 `~/.config/nvim`

```bash
git clone <your-repo-url> ~/Code/nvim-config
cd ~/Code/nvim-config
./bin/install.sh
nvim
```

`bin/install.sh` 会做两件事：

- 如果 `~/.config/nvim` 已存在，会先备份
- 把当前仓库软链接到 `~/.config/nvim`

## 首次启动会发生什么

首次打开 `nvim` 时，会自动：

1. bootstrap `lazy.nvim`
2. 安装插件
3. 安装 Mason 管理的 LSP / formatter / CLI 工具

如果你想手动触发工具安装，可以执行：

```vim
:MasonToolsInstall
```

## 常用快捷键

### 文件与搜索

- `Space ff`：找文件
- `Space fg`：全文搜索
- `Space fr`：最近文件
- `Space fb`：打开 buffer 列表
- `Space e`：显示/隐藏文件树
- `Space E`：聚焦文件树

### 文件 tab

- `Tab`：下一个文件 tab
- `Shift-Tab`：上一个文件 tab
- `Space 1` 到 `Space 9`：跳到对应文件 tab
- `Space bd`：关闭当前 buffer

### 跳转与引用

- `gd`：跳到定义
- `gr`：查看引用
- `gI`：跳到实现
- `Ctrl-o`：返回上一个跳转点
- `Ctrl-i`：前进到下一个跳转点

### Git

- `Space gw`：打开工作区 Git 面板
- `Space gd`：打开 diffview
- `Space gh`：当前文件历史
- `Space gx`：退出 Git 工作区
- `]h` / `[h`：下一处 / 上一处 Git 修改

### Terminal

- `Space tt`：新建 terminal
- `Space tl`：聚焦或切换 terminal 列表
- `Esc Esc`：terminal 回到 Normal 模式

## 目录结构

```text
.
├── init.lua
├── lazy-lock.json
├── lua
│   ├── config
│   │   ├── autocmds.lua
│   │   ├── git_workspace.lua
│   │   ├── keymaps.lua
│   │   ├── lazy.lua
│   │   ├── options.lua
│   │   ├── references.lua
│   │   └── terminals.lua
│   └── plugins
│       └── init.lua
└── bin
    └── install.sh
```

## 健康检查

装好后建议至少跑一次：

```vim
:checkhealth
```

如果插件或工具没装齐，可以看：

```vim
:Lazy
:Mason
:MasonToolsInstall
```

## 说明

- `lazy-lock.json` 已提交，插件版本是锁定的。
- `AGENTS.md` 里规定了：修改这个配置仓库后，必须提交一个 git commit。
