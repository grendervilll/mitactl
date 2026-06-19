#!/bin/bash
set -euo pipefail

REPO="grendervilll/mitactl"
BRANCH="main"
ARCHIVE_URL="https://github.com/${REPO}/archive/refs/heads/${BRANCH}.tar.gz"
INSTALL_DIR="/opt/mitactl-install"

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()   { echo -e "${GREEN}[OK]${NC}   $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

[[ $EUID -ne 0 ]] && err "Запустите от root: sudo bash <(curl -Ls ...)"

command -v curl &>/dev/null || apt-get install -y -qq curl
command -v tar  &>/dev/null || apt-get install -y -qq tar

info "Загрузка репозитория ${REPO}..."
rm -rf "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR"

curl -Ls "$ARCHIVE_URL" | tar -xz -C "$INSTALL_DIR" --strip-components=1 \
  || err "Не удалось скачать или распаковать архив с GitHub"

ok "Файлы загружены в $INSTALL_DIR"

chmod +x "$INSTALL_DIR/install.sh"
cd "$INSTALL_DIR"
exec bash install.sh
