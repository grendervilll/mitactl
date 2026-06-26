#!/bin/bash
# =============================================================================
# Установка mita Web Panel
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()      { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
section() { echo -e "\n${CYAN}══════ $* ══════${NC}"; }

[[ $EUID -ne 0 ]] && error "Запустите от root: sudo bash install-panel.sh"

# ── проверка зависимостей ──────────────────────────────────────────
section "Проверка окружения"
command -v mita &>/dev/null || error "mita не установлен — сначала запустите install.sh"

# ── выбор порта ────────────────────────────────────────────────────
section "Выбор порта панели"

find_free_port() {
  local start=$1
  for port in $(seq $start 65535); do
    if ! ss -tlnp 2>/dev/null | grep -q ":${port} " && \
       ! ss -tlnp 2>/dev/null | grep -q ":${port}$"; then
      echo $port; return
    fi
  done
  echo 8080
}

echo -e "Введите порт для панели (Enter = автовыбор из свободных начиная с 8080):"
read -r -p "Порт: " USER_PORT
if [[ -z "$USER_PORT" ]]; then
  PANEL_PORT=$(find_free_port 8080)
  info "Автовыбран свободный порт: $PANEL_PORT"
elif [[ "$USER_PORT" =~ ^[0-9]+$ ]] && [[ $USER_PORT -ge 1024 && $USER_PORT -le 65535 ]]; then
  if ss -tlnp 2>/dev/null | grep -q ":${USER_PORT}[[:space:]]"; then
    warn "Порт $USER_PORT занят, выбираем следующий свободный..."
    PANEL_PORT=$(find_free_port $((USER_PORT+1)))
    info "Выбран порт: $PANEL_PORT"
  else
    PANEL_PORT=$USER_PORT
    ok "Порт: $PANEL_PORT"
  fi
else
  error "Неверный порт: $USER_PORT"
fi

# ── установка Python, Flask и системных утилит ──────────────────────
section "Установка зависимостей"

apt-get update -qq
apt-get install -y -qq \
  python3 python3-pip python3-venv \
  openssl curl wget jq \
  fail2ban \
  certbot \
  iptables ufw \
  ca-certificates gnupg lsb-release \
  net-tools \
  2>/dev/null
ok "Системные пакеты установлены (Python, fail2ban, certbot, iptables, ufw)"

# fail2ban не запускаем автоматически — пользователь настроит лимиты
# через раздел "Безопасность" в панели или mita-ctl → пункт 7
systemctl enable fail2ban 2>/dev/null || true
ok "fail2ban установлен (настройка — через панель или mita-ctl)"

PANEL_DIR="/opt/mita-panel"
mkdir -p "$PANEL_DIR"

python3 -m venv "$PANEL_DIR/venv"
"$PANEL_DIR/venv/bin/pip" install -q flask gunicorn pyyaml psutil 2>/dev/null
ok "Python venv, Flask и зависимости установлены"

# ── копирование файлов ─────────────────────────────────────────────
section "Копирование файлов панели"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cp "$SCRIPT_DIR/app.py" "$PANEL_DIR/"
cp -r "$SCRIPT_DIR/templates" "$PANEL_DIR/"
[[ -d "$SCRIPT_DIR/static" ]] && cp -r "$SCRIPT_DIR/static" "$PANEL_DIR/"
ok "Файлы скопированы в $PANEL_DIR"

# ── генерация секретов ─────────────────────────────────────────────
section "Генерация учётных данных"

gen_pass() {
  openssl rand -base64 32 | tr -d '/+=' | head -c 24
}
gen_path() {
  openssl rand -hex 10
}

ADMIN_USER="admin"
ADMIN_PASS=$(gen_pass)
SECRET_PATH=$(gen_path)
FLASK_SECRET=$(openssl rand -hex 32)

ok "Логин и секретный путь сгенерированы"

# ── выбор способа подключения ──────────────────────────────────────
section "Способ подключения к панели"
echo -e "  ${BOLD}1.${NC}  По IP-адресу (открытый доступ)"
echo -e "  ${BOLD}2.${NC}  SSH-туннель (панель только на 127.0.0.1, недоступна снаружи)"
echo -e "  ${BOLD}3.${NC}  По доменному имени с Let's Encrypt"
echo ""
read -r -p "Выберите способ [1]: " ACCESS_MODE_CHOICE
ACCESS_MODE_CHOICE=${ACCESS_MODE_CHOICE:-1}

ACCESS_MODE="ip"
PANEL_BIND="0.0.0.0"
SSL_DOMAIN=""
SSH_ACCESS_PORT=22
LE_DOMAIN=""

case "$ACCESS_MODE_CHOICE" in
  2)
    ACCESS_MODE="ssh"
    PANEL_BIND="127.0.0.1"
    read -r -p "SSH-порт вашего VPS [22]: " SSH_ACCESS_PORT
    SSH_ACCESS_PORT=${SSH_ACCESS_PORT:-22}
    info "Панель будет доступна только через SSH-туннель"
    ;;
  3)
    ACCESS_MODE="domain"
    PANEL_BIND="0.0.0.0"
    read -r -p "Домен для панели (например panel.example.com): " LE_DOMAIN
    [[ -z "$LE_DOMAIN" ]] && { warn "Домен не указан, переключаемся на IP"; ACCESS_MODE="ip"; }
    ;;
esac

# ── конфиг панели ─────────────────────────────────────────────────
PANEL_CONFIG="/etc/mita/panel.json"
mkdir -p /etc/mita

# Получить WARP_PORT из существующего env если есть
WARP_PORT=40000
[[ -f /etc/mita/panel.env ]] && WARP_PORT=$(grep '^WARP_PORT=' /etc/mita/panel.env | cut -d= -f2 || echo 40000)

cat > "$PANEL_CONFIG" << EOF
{
  "admin_user": "$ADMIN_USER",
  "admin_pass": "$ADMIN_PASS",
  "secret_path": "$SECRET_PATH",
  "panel_port": $PANEL_PORT,
  "access_mode": "$ACCESS_MODE",
  "ssh_port": $SSH_ACCESS_PORT,
  "ssl_type": "none",
  "warp_users": []
}
EOF
ok "Конфиг панели: $PANEL_CONFIG"

# ── env файл ──────────────────────────────────────────────────────
cat > /etc/mita/panel.env << EOF
PANEL_PORT=$PANEL_PORT
SECRET_PATH=$SECRET_PATH
FLASK_SECRET=$FLASK_SECRET
PANEL_CONFIG=$PANEL_CONFIG
MITA_CONFIG=/etc/mita/server_config.json
WARP_PORT=$WARP_PORT
SSL_CERT=
SSL_KEY=
EOF
ok "Env файл: /etc/mita/panel.env"

# ── враппер запуска (динамически подхватывает SSL из panel.env) ──
section "Создание systemd сервиса"

cat > /opt/mita-panel/start.sh << 'STARTEOF'
#!/bin/bash
# Читаем актуальный panel.env каждый раз при старте
set -a
source /etc/mita/panel.env
set +a

SSL_ARGS=""
if [[ -n "$SSL_CERT" && -n "$SSL_KEY" && -f "$SSL_CERT" && -f "$SSL_KEY" ]]; then
  SSL_ARGS="--certfile=$SSL_CERT --keyfile=$SSL_KEY"
fi

exec /opt/mita-panel/venv/bin/gunicorn \
    --bind 0.0.0.0:${PANEL_PORT} \
    --workers 2 \
    --timeout 120 \
    --access-logfile /var/log/mita-panel-access.log \
    --error-logfile /var/log/mita-panel.log \
    $SSL_ARGS \
    app:app
STARTEOF
chmod +x /opt/mita-panel/start.sh
ok "Враппер запуска создан: /opt/mita-panel/start.sh"

cat > /etc/systemd/system/mita-panel.service << EOF
[Unit]
Description=mita Web Panel
After=network.target mita.service
Wants=mita.service

[Service]
Type=simple
User=root
WorkingDirectory=$PANEL_DIR
ExecStart=/opt/mita-panel/start.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable mita-panel
systemctl restart mita-panel
sleep 2

if systemctl is-active --quiet mita-panel; then
  ok "mita-panel запущен"
else
  warn "Не удалось запустить — проверьте: journalctl -u mita-panel -n 30"
fi

# ── firewall ──────────────────────────────────────────────────────
section "Открытие порта в firewall"

if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
  ufw allow "$PANEL_PORT/tcp" comment "mita-panel" 2>/dev/null || true
  ok "UFW: порт $PANEL_PORT открыт"
elif command -v iptables &>/dev/null; then
  iptables -I INPUT -p tcp --dport "$PANEL_PORT" -j ACCEPT 2>/dev/null || true
  ok "iptables: порт $PANEL_PORT открыт"
fi

# ── авто-генерация самоподписного сертификата ─────────────────────
section "SSL-сертификат"
SSL_DIR="/etc/mita/ssl"
mkdir -p "$SSL_DIR"
SSL_CERT="$SSL_DIR/selfsigned.crt"
SSL_KEY="$SSL_DIR/selfsigned.key"

info "Создание самоподписного сертификата (10 лет)..."
openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
  -keyout "$SSL_KEY" -out "$SSL_CERT" \
  -subj "/CN=mita-panel/O=mita/C=XX" 2>/dev/null

echo "SSL_CERT=$SSL_CERT" >> /etc/mita/panel.env
echo "SSL_KEY=$SSL_KEY"  >> /etc/mita/panel.env

python3 -c "
import json
with open('$PANEL_CONFIG') as f: d=json.load(f)
d.update({'ssl_type':'selfsigned','ssl_cert':'$SSL_CERT','ssl_key':'$SSL_KEY'})
with open('$PANEL_CONFIG','w') as f: json.dump(d,f,indent=2)
"
systemctl restart mita-panel 2>/dev/null || true
ok "Самоподписной сертификат установлен, панель перезапущена с HTTPS"

PROTO="https"

# ── итог ──────────────────────────────────────────────────────────
section "Установка завершена!"

SERVER_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗"
echo -e "║           ПАНЕЛЬ УПРАВЛЕНИЯ УСТАНОВЛЕНА                      ║"
echo -e "╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${CYAN}Адрес панели:${NC}"
echo -e "  ${BOLD}${YELLOW}${PROTO}://${SERVER_IP}:${PANEL_PORT}/${SECRET_PATH}/${NC}"
echo ""
echo -e "${CYAN}Учётные данные:${NC}"
echo -e "  Логин:   ${BOLD}${ADMIN_USER}${NC}"
echo -e "  Пароль:  ${BOLD}${YELLOW}${ADMIN_PASS}${NC}"
echo ""
echo -e "${CYAN}Секретный путь:${NC}"
echo -e "  ${BOLD}/${SECRET_PATH}/${NC}"
echo -e "  ${RED}Без него панель недоступна (возвращает 404)${NC}"
echo ""
echo -e "${CYAN}Полная ссылка для браузера:${NC}"
echo -e "  ${BOLD}${GREEN}${PROTO}://${SERVER_IP}:${PANEL_PORT}/${SECRET_PATH}/${NC}"
echo ""
echo -e "${CYAN}SSL:${NC}"
echo -e "  Сертификат: самоподписной (10 лет), уже установлен"
echo -e "  Браузер покажет предупреждение — примите его"
echo -e "  Заменить на Let's Encrypt: раздел SSL в панели или mita-ctl → пункт 3"
echo ""
echo -e "${CYAN}Полезные команды:${NC}"
echo -e "  ${YELLOW}systemctl status mita-panel${NC}      — статус"
echo -e "  ${YELLOW}journalctl -u mita-panel -f${NC}      — логи"
echo -e "  ${YELLOW}systemctl restart mita-panel${NC}     — перезапуск"
echo ""
echo -e "${RED}⚠  Сохраните ссылку и пароль — они больше не отобразятся!${NC}"
echo ""

# ── SSH туннель: финальные инструкции ─────────────────────────────
if [[ "$ACCESS_MODE" == "ssh" ]]; then
  echo ""
  echo -e "${CYAN}┌──────────────────────────────────────────────────────────────┐${NC}"
  echo -e "${CYAN}│  Подключение к панели через SSH-туннель                      │${NC}"
  echo -e "${CYAN}└──────────────────────────────────────────────────────────────┘${NC}"
  echo ""
  echo -e "  Выполните на ${BOLD}вашем компьютере${NC}:"
  echo ""
  echo -e "  ${YELLOW}ssh -L ${PANEL_PORT}:127.0.0.1:${PANEL_PORT} -p ${SSH_ACCESS_PORT} root@${SERVER_IP} -N${NC}"
  echo ""
  echo -e "  Затем откройте в браузере:"
  echo -e "  ${BOLD}${GREEN}${PROTO}://127.0.0.1:${PANEL_PORT}/${SECRET_PATH}/${NC}"
  echo ""
  echo -e "  Для фонового режима:"
  echo -e "  ${YELLOW}ssh -fN -L ${PANEL_PORT}:127.0.0.1:${PANEL_PORT} -p ${SSH_ACCESS_PORT} root@${SERVER_IP}${NC}"
  echo ""
fi

# ── Let's Encrypt ─────────────────────────────────────────────────
if [[ "$ACCESS_MODE" == "domain" && -n "$LE_DOMAIN" ]]; then
  info "Получение Let's Encrypt сертификата для $LE_DOMAIN..."
  command -v certbot &>/dev/null || apt-get install -y -qq certbot
  if certbot certonly --standalone --non-interactive --agree-tos \
      --register-unsafely-without-email -d "$LE_DOMAIN" 2>/dev/null; then
    LE_CERT="/etc/letsencrypt/live/${LE_DOMAIN}/fullchain.pem"
    LE_KEY="/etc/letsencrypt/live/${LE_DOMAIN}/privkey.pem"
    echo "SSL_CERT=$LE_CERT" >> /etc/mita/panel.env
    echo "SSL_KEY=$LE_KEY"  >> /etc/mita/panel.env
    python3 -c "
import json
with open('$PANEL_CONFIG') as f: d=json.load(f)
d.update({'ssl_type':'letsencrypt','ssl_domain':'$LE_DOMAIN','ssl_cert':'$LE_CERT','ssl_key':'$LE_KEY'})
with open('$PANEL_CONFIG','w') as f: json.dump(d,f,indent=2)
"
    (crontab -l 2>/dev/null; echo "0 3 * * * certbot renew --quiet && systemctl restart mita-panel") | sort -u | crontab -
    systemctl restart mita-panel 2>/dev/null || true
    ok "Сертификат получен"
    PROTO="https"
  else
    warn "Не удалось получить сертификат Let's Encrypt. Убедитесь что $LE_DOMAIN указывает на этот сервер и порт 80 открыт."
    PROTO="http"
  fi
fi

# ── Установка mita-ctl как системной команды ──────────────────────
section "Установка утилиты mita-ctl"

SCRIPT_DIR_CTL="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CTL_SRC="$SCRIPT_DIR_CTL/mita-ctl.sh"

if [[ -f "$CTL_SRC" ]]; then
  cp "$CTL_SRC" /usr/local/bin/mita-ctl
  chmod +x /usr/local/bin/mita-ctl
  ok "mita-ctl установлен. Запуск: sudo mita-ctl"
else
  warn "mita-ctl.sh не найден рядом — пропускаем"
  warn "Чтобы установить вручную: cp mita-ctl.sh /usr/local/bin/mita-ctl && chmod +x /usr/local/bin/mita-ctl"
fi
