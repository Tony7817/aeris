#!/usr/bin/env bash

set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TARGET_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/nvim"

if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew is required (macOS / Linux). Install it from https://brew.sh, then rerun this script." >&2
  exit 1
fi

# Install only missing system dependencies; leave existing versions alone.
PACKAGES=()
for dependency in 'nvim:neovim' 'git:git' 'rg:ripgrep' 'node:node' 'npm:node' 'python3:python' 'go:go' 'tree-sitter:tree-sitter-cli' 'curl:curl' 'unzip:unzip'; do
  if ! command -v "${dependency%%:*}" >/dev/null 2>&1; then
    PACKAGES+=("${dependency#*:}")
  fi
done
if [ "${#PACKAGES[@]}" -gt 0 ]; then
  brew install "${PACKAGES[@]}"
fi

if ! nvim --clean --headless '+lua if vim.fn.has("nvim-0.12") == 0 then vim.cmd("cquit 1") end' '+qa'; then
  brew upgrade neovim
fi
nvim --clean --headless '+lua if vim.fn.has("nvim-0.12") == 0 then vim.cmd("cquit 1") end' '+qa'

for dependency in git rg node npm python3 go tree-sitter curl unzip tar cc make; do
  if ! command -v "${dependency}" >/dev/null 2>&1; then
    echo "Missing ${dependency}. Install your system build tools (macOS: xcode-select --install; Linux: a C compiler and make), then rerun." >&2
    exit 1
  fi
done

mkdir -p "$(dirname "${TARGET_DIR}")"

# A clone at the target path, or an existing link to it, is already installed.
if [ ! "${SOURCE_DIR}" -ef "${TARGET_DIR}" ]; then
  if [ -e "${TARGET_DIR}" ] || [ -L "${TARGET_DIR}" ]; then
    BACKUP_DIR="${TARGET_DIR}.backup.$(date +%Y%m%d_%H%M%S).$$"
    mv "${TARGET_DIR}" "${BACKUP_DIR}"
    echo "Backed up existing config to ${BACKUP_DIR}"
  fi
  ln -s "${SOURCE_DIR}" "${TARGET_DIR}"
  echo "Linked ${SOURCE_DIR} -> ${TARGET_DIR}"
fi

# Always use this config, even if the caller has another NVIM_APPNAME set.
unset NVIM_APPNAME
cd "${SOURCE_DIR}"
nvim --headless -u "${TARGET_DIR}/init.lua" -l "${SOURCE_DIR}/bin/bootstrap.lua"

echo "Installation complete. Run 'nvim' to start Aeris."
echo "For icons, install a Nerd Font and select it in your terminal settings (see README)."
