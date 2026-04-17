#!/usr/bin/env bash

set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET_DIR="${HOME}/.config/nvim"
BACKUP_DIR="${HOME}/.config/nvim.backup.$(date +%Y%m%d_%H%M%S)"

mkdir -p "${HOME}/.config"

if [ -L "${TARGET_DIR}" ]; then
  rm -f "${TARGET_DIR}"
elif [ -e "${TARGET_DIR}" ]; then
  mv "${TARGET_DIR}" "${BACKUP_DIR}"
  echo "Backed up existing config to ${BACKUP_DIR}"
fi

ln -s "${SOURCE_DIR}" "${TARGET_DIR}"

echo "Linked ${SOURCE_DIR} -> ${TARGET_DIR}"
echo "Run 'nvim' to bootstrap plugins and tools."
