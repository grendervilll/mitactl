#!/bin/bash
# =============================================================================
# Установка Telegram-бота для управления mita
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()      { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
section() { echo -e "\n${CYAN}══════ $* ══════${NC}"; }

[[ $EUID -ne 0 ]] && error "Запустите от root: sudo bash install-bot.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOT_DIR="/opt/mita-bot"
BOT_CONFIG="/etc/mita/bot.json"

# ── поиск bot.py ────────────────────────────────────────────────────
BOT_SRC=""
for candidate in "$SCRIPT_DIR/bot.py" "$SCRIPT_DIR/mita-bot-pkg/bot.py"; do
    if [[ -f "$candidate" ]]; then
        BOT_SRC="$candidate"
        break
    fi
done

if [[ -z "$BOT_SRC" ]]; then
    error "bot.py не найден рядом со скриптом. Убедитесь что bot.py лежит в одной папке с install-bot.sh"
fi

# ═══════════════════════════════════════════════════════════════════════
section "Установка Telegram-бота mita"

# ── неинтерактивный режим (вызов из веб-панели или API) ────────────
if [[ -n "${BOT_TOKEN_NONINTERACTIVE:-}" && -n "${BOT_ADMIN_NONINTERACTIVE:-}" ]]; then
    BOT_TOKEN="$BOT_TOKEN_NONINTERACTIVE"
    ADMIN_ID="$BOT_ADMIN_NONINTERACTIVE"
    info "Неинтерактивный режим"
else
    echo ""
    echo -e "  ${BOLD}Для работы бота нужны:${NC}"
    echo -e "    ${YELLOW}1.${NC} Токен бота от @BotFather"
    echo -e "    ${YELLOW}2.${NC} Ваш Telegram ID (узнать: @userinfobot)"
    echo ""

    # ── токен ───────────────────────────────────────────────────────────
    read -r -p "Введите токен бота (от @BotFather): " BOT_TOKEN
    if [[ -z "$BOT_TOKEN" ]]; then
        error "Токен не может быть пустым"
    fi

    # ── admin ID ─────────────────────────────────────────────────────────
    read -r -p "Введите ваш Telegram ID (число, узнать через @userinfobot): " ADMIN_ID
    if [[ -z "$ADMIN_ID" || ! "$ADMIN_ID" =~ ^[0-9]+$ ]]; then
        error "Telegram ID должен быть числом"
    fi
fi

echo ""
info "Токен: ${BOT_TOKEN:0:8}..."
info "Admin ID: $ADMIN_ID"

# ── зависимости ─────────────────────────────────────────────────────
section "Установка зависимостей"
apt-get update -qq
apt-get install -y -qq python3 python3-pip python3-venv

BOT_VENV="$BOT_DIR/venv"
if [[ ! -d "$BOT_VENV" ]]; then
    python3 -m venv "$BOT_VENV"
fi

"$BOT_VENV/bin/pip" install -q python-telegram-bot psutil 2>/dev/null
ok "Python-зависимости установлены в виртуальное окружение"

# ── копирование файлов ──────────────────────────────────────────────
section "Установка бота"
mkdir -p "$BOT_DIR"
cp "$BOT_SRC" "$BOT_DIR/bot.py"
chmod +x "$BOT_DIR/bot.py"
ok "bot.py скопирован в $BOT_DIR/"

# ── конфиг ──────────────────────────────────────────────────────────
mkdir -p /etc/mita
if [[ -f "$BOT_CONFIG" ]]; then
    python3 -c "
import json
with open('$BOT_CONFIG') as f: d=json.load(f)
d['token']='$BOT_TOKEN'
admin_ids=d.get('admin_ids',[])
if '$ADMIN_ID' not in admin_ids: admin_ids.append('$ADMIN_ID')
d['admin_ids']=admin_ids
with open('$BOT_CONFIG','w') as f: json.dump(d,f,indent=2)
"
    ok "Конфиг обновлён"
else
    cat > "$BOT_CONFIG" <<JSON
{
  "token": "$BOT_TOKEN",
  "admin_ids": ["$ADMIN_ID"]
}
JSON
    ok "Конфиг создан: $BOT_CONFIG"
fi

# ── env файл ────────────────────────────────────────────────────────
cat > "$BOT_DIR/env" <<EOF
BOT_CONFIG=$BOT_CONFIG
BOT_TOKEN=$BOT_TOKEN
EOF

# ── systemd unit ────────────────────────────────────────────────────
cat > /etc/systemd/system/mita-bot.service <<UNIT
[Unit]
Description=mita Telegram Bot
After=network.target

[Service]
Type=simple
WorkingDirectory=$BOT_DIR
EnvironmentFile=$BOT_DIR/env
ExecStart=$BOT_VENV/bin/python3 $BOT_DIR/bot.py
Restart=always
RestartSec=10
User=root

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable mita-bot
systemctl restart mita-bot

sleep 2
if systemctl is-active --quiet mita-bot; then
    ok "Бот запущен и добавлен в автозагрузку"
else
    warn "Бот не запустился. Проверьте: journalctl -u mita-bot -f"
fi

# ═══════════════════════════════════════════════════════════════════════
section "Установка завершена"

echo ""
echo -e "  ${GREEN}Бот установлен!${NC}"
echo ""
echo -e "  ${BOLD}Команды управления:${NC}"
echo -e "    ${YELLOW}systemctl status mita-bot${NC}  — статус бота"
echo -e "    ${YELLOW}systemctl restart mita-bot${NC} — перезапустить"
echo -e "    ${YELLOW}journalctl -u mita-bot -f${NC} — логи"
echo ""
echo -e "  ${BOLD}Файлы:${NC}"
echo -e "    Бот:       ${YELLOW}$BOT_DIR/bot.py${NC}"
echo -e "    Конфиг:    ${YELLOW}$BOT_CONFIG${NC}"
echo -e "    Unit:      ${YELLOW}/etc/systemd/system/mita-bot.service${NC}"
echo ""
echo -e "  ${BOLD}Для добавления других админов:${NC}"
echo -e "    Отредактируйте ${YELLOW}$BOT_CONFIG${NC} и добавьте ID в массив admin_ids,"
echo -e "    затем: ${YELLOW}systemctl restart mita-bot${NC}"
echo ""
