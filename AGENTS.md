# Neovim Config AGENTS Guide

本目录是个人 Neovim 配置仓库，目标是维护一套稳定、可迭代、可回滚的编辑器环境。

## 项目说明

- 入口文件：`init.lua`
- 核心配置：`lua/config/*.lua`
- 插件声明与配置：`lua/plugins/init.lua`
- 插件锁文件：`lazy-lock.json`
- 历史备份：`backups/`

这套配置主要覆盖以下能力：

- 编辑器基础选项与键位
- 文件树、buffer tab、terminal、Git 面板
- LSP、Treesitter、格式化与补全
- 主题、高亮与界面布局

## 工作规则

- 在本目录下修改任意 Neovim 配置后，必须提交一个 git commit。
- 默认要求是“一次明确修改，对应一个 commit”，不要把多个不相关修改混在同一个 commit 里。
- 除非用户明确要求，不要 amend 现有 commit。
- 除非用户明确要求，不要回退或覆盖其他人已有改动。
- 使用 Codex CLI 时，必须先 `cd` 到目标代码仓目录，再执行 `codex` 相关命令创建 session。
- 不要在错误的工作目录直接启动 Codex session；session 的创建目录应当与实际要操作的代码仓一致。

## 修改建议

- 改动 `lua/config/*.lua` 或 `lua/plugins/init.lua` 后，优先做最小验证。
- 能用 `nvim --headless '+qa'` 验证启动时，尽量验证一次。
- 涉及键位、窗口、Git、terminal、文件树这类交互功能时，除静态检查外，尽量补一次行为验证。

## 提交规范

- 提交信息应直接描述本次配置改动，例如：
  - `chore: initialize neovim config repo`
  - `feat: add bufferline tabs`
  - `fix: improve git workspace diff navigation`

## 适用范围

- 本文件仅适用于 `~/.config/nvim` 这个 Neovim 配置目录。
- 若未来在该目录下新增子模块或外部脚本，也默认遵循本文件规则，除非该子目录另有自己的 `AGENTS.md`。
