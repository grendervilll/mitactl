#!/bin/bash
# =============================================================================
# mita + WARP Setup Script
# Ubuntu / Debian VPS
# =============================================================================
set -euo pipefail

# Директория, из которой запущен скрипт (нужна для поиска install-panel.sh рядом)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ========================= ЦВЕТА ДЛЯ ВЫВОДА =========================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()      { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
section() { echo -e "\n${CYAN}══════ $* ══════${NC}"; }

# =============================================================================
# ██████████████████████████████████████████████████████████████████████████
#                        !! НАСТРОЙКИ — РЕДАКТИРОВАТЬ ЗДЕСЬ !!
# ██████████████████████████████████████████████████████████████████████████
# =============================================================================

# ---- Порты mita (можно указать диапазон или одиночные порты) ----
MITA_PORT_RANGE="2100-2110"       # диапазон портов mita
MITA_PROTOCOL="TCP"               # TCP или UDP

# ---- Пользователи mita ----
# Формат: "имя:пароль"
# Добавляйте сколько угодно строк
# ВНИМАНИЕ: перед использованием ОБЯЗАТЕЛЬНО замените пароли ниже на свои (минимум 8 символов)!
MITA_USERS=(
  "alice:qwerty1234"
  "bob:qwerty1234"
)

# ---- WARP ----
WARP_ENABLED=true                 # true — включить WARP; false — только mita без WARP
WARP_PORT=40000                   # локальный порт SOCKS5 от WARP (не менять без причины)

# ---- Логирование mita ----
MITA_LOG_LEVEL="INFO"             # INFO или DEBUG

# =============================================================================
#                    !! КОНЕЦ НАСТРОЕК !!
# =============================================================================

MITA_CONFIG_DIR="/etc/mita"
MITA_CONFIG_FILE="$MITA_CONFIG_DIR/server_config.json"
LISTS_DIR="/etc/mita/lists"
CUSTOM_DOMAINS_FILE="$LISTS_DIR/custom_domains.txt"
CUSTOM_IPS_FILE="$LISTS_DIR/custom_ips.txt"
AUTO_DOMAINS_FILE="$LISTS_DIR/auto_domains.txt"
AUTO_IPS_FILE="$LISTS_DIR/auto_ips.txt"
UPDATE_SCRIPT="/usr/local/bin/mita-update-lists"
CRON_FILE="/etc/cron.d/mita-update"

# =============================================================================
# ПРОВЕРКИ
# =============================================================================
section "Проверка окружения"

[[ $EUID -ne 0 ]] && error "Запустите скрипт от root: sudo bash install.sh"

OS=$(. /etc/os-release && echo "$ID")
[[ "$OS" != "ubuntu" && "$OS" != "debian" ]] && error "Поддерживается только Ubuntu/Debian"
ok "ОС: $OS"

# Проверка пользователей
for entry in "${MITA_USERS[@]}"; do
  name="${entry%%:*}"; pass="${entry##*:}"
  [[ "$pass" == *"ЗАМЕНИТЕ"* ]] && error "Замените пароль для пользователя '$name' в начале скрипта!"
  [[ ${#pass} -lt 8 ]] && error "Пароль пользователя '$name' слишком короткий (минимум 8 символов)"
done
ok "Пользователи настроены корректно (${#MITA_USERS[@]} шт.)"

# =============================================================================
# ВЫБОР ПОРТОВ MITA
# =============================================================================
section "Порты mita"

echo -e "  Текущее значение: ${YELLOW}${MITA_PORT_RANGE}${NC} (${MITA_PROTOCOL})"
echo -e "  Допустимые форматы:"
echo -e "    диапазон:  ${CYAN}2100-2110${NC}   — mita случайно выбирает порт из диапазона при каждом соединении"
echo -e "    одиночный: ${CYAN}2100${NC}        — фиксированный порт"
echo -e "  Рекомендуется диапазон из 5-20 портов."
echo ""
read -r -p "  Введите порт или диапазон [${MITA_PORT_RANGE}]: " _PORT_INPUT

if [[ -n "$_PORT_INPUT" ]]; then
  if [[ "$_PORT_INPUT" =~ ^([0-9]+)-([0-9]+)$ ]]; then
    _P_START="${BASH_REMATCH[1]}"
    _P_END="${BASH_REMATCH[2]}"
    if [[ $_P_START -lt 1024 || $_P_END -gt 65535 ]]; then
      error "Порты должны быть в диапазоне 1024–65535. Получено: $_P_START-$_P_END"
    fi
    if [[ $_P_START -ge $_P_END ]]; then
      error "Начало диапазона ($_P_START) должно быть меньше конца ($_P_END)"
    fi
    MITA_PORT_RANGE="$_PORT_INPUT"
    ok "Диапазон портов: $MITA_PORT_RANGE"
  elif [[ "$_PORT_INPUT" =~ ^[0-9]+$ ]]; then
    if [[ $_PORT_INPUT -lt 1024 || $_PORT_INPUT -gt 65535 ]]; then
      error "Порт $_PORT_INPUT вне допустимого диапазона (1024–65535)"
    fi
    MITA_PORT_RANGE="$_PORT_INPUT"
    ok "Порт: $MITA_PORT_RANGE"
  else
    error "Неверный формат: '$_PORT_INPUT'. Ожидается число (2100) или диапазон (2100-2110)"
  fi
else
  ok "Оставлен по умолчанию: $MITA_PORT_RANGE"
fi

# =============================================================================
# ЗАВИСИМОСТИ
# =============================================================================
section "Установка зависимостей"

apt-get update -qq || { warn "apt-get update завершился с ошибкой, продолжаем..."; true; }
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  curl wget jq cron \
  ca-certificates gnupg lsb-release \
  iptables ufw \
  fail2ban openssl \
  net-tools \
  python3 python3-yaml \
  || error "Ошибка установки зависимостей. Запустите вручную: apt-get install -y curl wget jq cron iptables ufw fail2ban python3 python3-yaml"
# ipset и iptables-persistent — опциональные, не прерываем при ошибке
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ipset iptables-persistent 2>/dev/null || true
ok "Базовые пакеты установлены (включая fail2ban, ufw, ipset, iptables-persistent, python3-yaml)"

# =============================================================================
# УСТАНОВКА MITA
# =============================================================================
section "Установка mita"

MITA_VERSION=$(curl -s https://api.github.com/repos/enfein/mieru/releases/latest \
  | jq -r '.tag_name' | tr -d 'v')
[[ -z "$MITA_VERSION" ]] && error "Не удалось получить версию mita с GitHub"
info "Последняя версия mita: $MITA_VERSION"

ARCH=$(uname -m)
case "$ARCH" in
  x86_64)  DEB_ARCH="amd64" ;;
  aarch64) DEB_ARCH="arm64" ;;
  armv7l)  DEB_ARCH="armhf" ;;
  *)       error "Неподдерживаемая архитектура: $ARCH" ;;
esac

DEB_FILE="mita_${MITA_VERSION}_${DEB_ARCH}.deb"
DL_URL="https://github.com/enfein/mieru/releases/download/v${MITA_VERSION}/${DEB_FILE}"

info "Загрузка: $DL_URL"
wget -q --show-progress "$DL_URL" -O /tmp/"$DEB_FILE" || error "Ошибка загрузки mita"
dpkg -i /tmp/"$DEB_FILE" || apt-get install -f -y -qq
rm -f /tmp/"$DEB_FILE"
ok "mita $MITA_VERSION установлен"

# =============================================================================
# УСТАНОВКА DOCKER + WARP
# =============================================================================
if $WARP_ENABLED; then
  section "Установка Docker и Cloudflare WARP"

  if ! command -v docker &>/dev/null; then
    info "Установка Docker..."
    curl -fsSL https://get.docker.com | sh -s -- -q
    systemctl enable docker --now
    ok "Docker установлен"
  else
    ok "Docker уже установлен"
  fi

  info "Запуск Cloudflare WARP в Docker..."
  docker rm -f cloudflare-warp 2>/dev/null || true
  docker run -d \
    --name cloudflare-warp \
    --restart unless-stopped \
    -p 127.0.0.1:${WARP_PORT}:40000 \
    seiry/cloudflare-warp-proxy

  # Подождать пока WARP поднимется
  info "Ожидание запуска WARP (до 30 сек)..."
  for i in $(seq 1 30); do
    if curl -s --max-time 3 --proxy "socks5h://127.0.0.1:${WARP_PORT}" \
        "https://www.cloudflare.com/cdn-cgi/trace" 2>/dev/null | grep -q "warp=on"; then
      ok "WARP активен и работает"
      break
    fi
    sleep 1
    [[ $i -eq 30 ]] && warn "WARP не ответил за 30 сек — продолжаем, проверьте позже: docker logs cloudflare-warp"
  done
fi

# =============================================================================
# СОЗДАНИЕ ДИРЕКТОРИЙ И ФАЙЛОВ СПИСКОВ
# =============================================================================
section "Создание файлов конфигурации"

mkdir -p "$MITA_CONFIG_DIR" "$LISTS_DIR"

# ---- custom_domains.txt ----
cat > "$CUSTOM_DOMAINS_FILE" << 'EOF'
# ================================================================
# ПОЛЬЗОВАТЕЛЬСКИЙ СПИСОК ДОМЕНОВ → трафик пойдёт через WARP
# ================================================================
# Добавляйте домены по одному на строку.
# Строки начинающиеся с # — комментарии, игнорируются.
# Субдомены включаются автоматически (openai.com → *.openai.com).
#
# Примеры:
# openai.com
# chatgpt.com
# anthropic.com
# claude.ai
# ================================================================

EOF
ok "Создан: $CUSTOM_DOMAINS_FILE"

# ---- custom_ips.txt ----
cat > "$CUSTOM_IPS_FILE" << 'EOF'
# ================================================================
# ПОЛЬЗОВАТЕЛЬСКИЙ СПИСОК IP/CIDR → трафик пойдёт через WARP
# ================================================================
# Формат: одна подсеть CIDR или IP на строку.
# Примеры:
# 104.16.0.0/12
# 172.64.0.0/13
# ================================================================

EOF
ok "Создан: $CUSTOM_IPS_FILE"

# ---- auto_domains.txt (источники для автообновления) ----
cat > "$AUTO_DOMAINS_FILE" << 'EOF'
# ================================================================
# ИСТОЧНИКИ АВТООБНОВЛЯЕМЫХ ДОМЕНОВ (ссылки или geosite-категории)
# ================================================================
# Поддерживаемые форматы строк:
#
# 1) URL на текстовый файл (один домен на строку):
#    https://raw.githubusercontent.com/v2fly/domain-list-community/release/openai.txt
#
# 2) geosite-категория из репозитория v2fly:
#    geosite:openai
#    geosite:google
#    geosite:netflix
#    geosite:category-ru    ← российские сайты
#    (полный список: github.com/v2fly/domain-list-community/tree/master/data)
#
# Строки с # — комментарии.
# ================================================================

# --- OpenAI / AI сервисы ---
geosite:openai

# --- Примеры (раскомментируйте нужное) ---
# geosite:google
# geosite:netflix
# https://raw.githubusercontent.com/nicholaswilde/blocklists/main/domain-lists/streaming.txt
EOF
ok "Создан: $AUTO_DOMAINS_FILE"

# ---- auto_ips.txt ----
cat > "$AUTO_IPS_FILE" << 'EOF'
# ================================================================
# ИСТОЧНИКИ АВТООБНОВЛЯЕМЫХ IP-ДИАПАЗОНОВ
# ================================================================
# Формат строк:
#
# 1) URL на файл с CIDR:
#    https://raw.githubusercontent.com/herrbischoff/country-ip-blocks/master/ipv4/us.cidr
#
# 2) geoip-страна (ISO-код):
#    geoip:us
#    geoip:gb
#    geoip:de
#
# ================================================================

# Пример: американские IP через WARP
# geoip:us
EOF
ok "Создан: $AUTO_IPS_FILE"

# =============================================================================
# СКРИПТ ОБНОВЛЕНИЯ СПИСКОВ
# =============================================================================
section "Создание скрипта обновления списков"

cat > "$UPDATE_SCRIPT" << UPDATEEOF
#!/bin/bash
# Автообновление списков доменов/IP и перегенерация конфига mita
# Запускается cron ежедневно

set -euo pipefail
LISTS_DIR="$LISTS_DIR"
MITA_CONFIG_FILE="$MITA_CONFIG_FILE"
WARP_ENABLED=$WARP_ENABLED
WARP_PORT=$WARP_PORT
MITA_PORT_RANGE="$MITA_PORT_RANGE"
MITA_PROTOCOL="$MITA_PROTOCOL"
MITA_LOG_LEVEL="$MITA_LOG_LEVEL"
GEOSITE_YML_URL="https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat_plain.yml"
GEOSITE_CACHE="/var/cache/mita-geosite.yml"
GEOIP_BASE="https://raw.githubusercontent.com/herrbischoff/country-ip-blocks/master/ipv4"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] \$*" | tee -a /var/log/mita-update.log; }

# ---------- Сбор доменов ----------
log "Сбор доменов..."
TMP_DOMAINS=\$(mktemp)

# Пользовательские домены
grep -v '^\s*#' "\$LISTS_DIR/custom_domains.txt" | grep -v '^\s*$' >> "\$TMP_DOMAINS" || true

# Проверяем, нужен ли geosite YAML (есть хотя бы одна строка geosite: в auto_domains.txt)
NEED_GEOSITE=false
grep -q '^geosite:' "\$LISTS_DIR/auto_domains.txt" 2>/dev/null && NEED_GEOSITE=true

if \$NEED_GEOSITE; then
  mkdir -p "\$(dirname "\$GEOSITE_CACHE")"
  CACHE_AGE_DAYS=999
  if [[ -f "\$GEOSITE_CACHE" ]]; then
    CACHE_AGE_SEC=\$(( \$(date +%s) - \$(stat -c %Y "\$GEOSITE_CACHE" 2>/dev/null || echo 0) ))
    CACHE_AGE_DAYS=\$(( CACHE_AGE_SEC / 86400 ))
  fi
  if [[ \$CACHE_AGE_DAYS -ge 7 ]]; then
    log "Загрузка базы geosite (dlc.dat_plain.yml, ~10-15 МБ, кэш обновляется раз в 7 дней)..."
    if curl -sfL --max-time 60 "\$GEOSITE_YML_URL" -o "\$GEOSITE_CACHE.tmp" 2>/dev/null; then
      mv "\$GEOSITE_CACHE.tmp" "\$GEOSITE_CACHE"
      log "База geosite обновлена"
    else
      log "WARN: не удалось загрузить базу geosite — используется старый кэш (если есть)"
      rm -f "\$GEOSITE_CACHE.tmp"
    fi
  else
    log "База geosite в кэше актуальна (обновлена \$CACHE_AGE_DAYS дн. назад)"
  fi
fi

# Автоматические источники
while IFS= read -r line; do
  line="\$(echo "\$line" | xargs)"
  [[ -z "\$line" || "\$line" == \#* ]] && continue

  if [[ "\$line" == geosite:* ]]; then
    category="\${line#geosite:}"
    log "  geosite:\$category"
    if [[ -f "\$GEOSITE_CACHE" ]]; then
      python3 -c "
import yaml, sys
try:
    with open('\$GEOSITE_CACHE') as f:
        data = yaml.safe_load(f)
    found = False
    for entry in data.get('lists', []):
        if entry.get('name','').lower() == '\$category'.lower():
            found = True
            for rule in entry.get('rules', []):
                d = rule
                for prefix in ('domain:', 'full:'):
                    if d.startswith(prefix):
                        d = d[len(prefix):]
                        print(d)
                        break
                else:
                    # regexp: и include: пропускаем — не доменные правила
                    pass
    if not found:
        sys.stderr.write('NOTFOUND\\n')
except Exception as e:
    sys.stderr.write(f'ERROR:{e}\\n')
" >> "\$TMP_DOMAINS" 2>/tmp/geosite_err.log
      if grep -q "NOTFOUND" /tmp/geosite_err.log 2>/dev/null; then
        log "  WARN: категория geosite:\$category не найдена в базе"
      elif grep -q "ERROR" /tmp/geosite_err.log 2>/dev/null; then
        log "  WARN: ошибка парсинга geosite:\$category — $(cat /tmp/geosite_err.log)"
      fi
      rm -f /tmp/geosite_err.log
    else
      log "  WARN: база geosite недоступна, пропускаю geosite:\$category"
    fi

  elif [[ "\$line" == http* ]]; then
    log "  URL: \$line"
    curl -sf "\$line" 2>/dev/null \
      | grep -v '^\s*#' | grep -v '^\s*$' \
      >> "\$TMP_DOMAINS" || log "  WARN: не удалось загрузить \$line"
  fi
done < "\$LISTS_DIR/auto_domains.txt"

# Дедупликация доменов
FINAL_DOMAINS=\$(sort -u "\$TMP_DOMAINS" | grep -v '^\s*$')
rm -f "\$TMP_DOMAINS"
DOMAIN_COUNT=\$(echo "\$FINAL_DOMAINS" | grep -c . || echo 0)
log "Доменов собрано: \$DOMAIN_COUNT"

# ---------- Сбор IP-диапазонов ----------
log "Сбор IP-диапазонов..."
TMP_IPS=\$(mktemp)

grep -v '^\s*#' "\$LISTS_DIR/custom_ips.txt" | grep -v '^\s*$' >> "\$TMP_IPS" || true

while IFS= read -r line; do
  line="\$(echo "\$line" | xargs)"
  [[ -z "\$line" || "\$line" == \#* ]] && continue

  if [[ "\$line" == geoip:* ]]; then
    country="\${line#geoip:}"
    log "  geoip:\$country"
    curl -sf "\$GEOIP_BASE/\${country}.cidr" 2>/dev/null \
      >> "\$TMP_IPS" || log "  WARN: не удалось загрузить geoip:\$country"

  elif [[ "\$line" == http* ]]; then
    log "  URL: \$line"
    curl -sf "\$line" 2>/dev/null | grep -v '^\s*#' | grep -v '^\s*$' \
      >> "\$TMP_IPS" || log "  WARN: не удалось загрузить \$line"
  fi
done < "\$LISTS_DIR/auto_ips.txt"

FINAL_IPS=\$(sort -u "\$TMP_IPS" | grep -v '^\s*$')
rm -f "\$TMP_IPS"
IP_COUNT=\$(echo "\$FINAL_IPS" | grep -c . || echo 0)
log "IP-диапазонов собрано: \$IP_COUNT"

# ---------- Сборка JSON egress-правил ----------
build_egress() {
  local domains="\$1"
  local ips="\$2"

  if ! \$WARP_ENABLED; then
    echo '{"rules": [{"ipRanges": ["*"], "domainNames": ["*"], "action": "DIRECT"}]}'
    return
  fi

  local domain_arr="[]"
  local ip_arr="[]"

  [[ -n "\$domains" ]] && domain_arr=\$(echo "\$domains" | jq -R . | jq -s .)
  [[ -n "\$ips" ]]     && ip_arr=\$(echo "\$ips" | jq -R . | jq -s .)

  # Строим правила: сначала WARP-правило (если есть домены/IP), потом DIRECT для всего остального
  local rules="[]"

  if [[ \$DOMAIN_COUNT -gt 0 || \$IP_COUNT -gt 0 ]]; then
    warp_rule=\$(jq -n \
      --argjson d "\$domain_arr" \
      --argjson i "\$ip_arr" \
      '{action: "PROXY", proxyNames: ["warp"], domainNames: \$d, ipRanges: \$i}')
    rules=\$(echo "[\$warp_rule]")
  fi

  # Финальное правило — всё остальное напрямую
  direct_rule='{"ipRanges": ["*"], "domainNames": ["*"], "action": "DIRECT"}'
  rules=\$(echo "\$rules" | jq ". + [\$direct_rule]" --argjson direct "\$direct_rule")

  jq -n \
    --argjson rules "\$rules" \
    '{
      proxies: [{
        name: "warp",
        protocol: "SOCKS5_PROXY_PROTOCOL",
        host: "127.0.0.1",
        port: \$ENV.WARP_PORT|tonumber
      }],
      rules: \$rules
    }' <<< "" 2>/dev/null || jq -n \
    --argjson rules "\$rules" \
    --argjson port "\$WARP_PORT" \
    '{
      proxies: [{name: "warp", protocol: "SOCKS5_PROXY_PROTOCOL", host: "127.0.0.1", port: \$port}],
      rules: \$rules
    }'
}

EGRESS_JSON=\$(build_egress "\$FINAL_DOMAINS" "\$FINAL_IPS")

# ---------- Чтение текущих пользователей ----------
CURRENT_USERS=\$(jq '.users' "\$MITA_CONFIG_FILE" 2>/dev/null || echo '[]')

# ---------- Генерация итогового конфига ----------
log "Генерация конфига mita..."

# Разбор диапазона портов
if [[ "\$MITA_PORT_RANGE" == *"-"* ]]; then
  PORT_BINDING=\$(jq -n --arg r "\$MITA_PORT_RANGE" --arg p "\$MITA_PROTOCOL" \
    '[{portRange: \$r, protocol: \$p}]')
else
  PORT_BINDING=\$(jq -n --arg port "\$MITA_PORT_RANGE" --arg p "\$MITA_PROTOCOL" \
    '[{port: (\$port|tonumber), protocol: \$p}]')
fi

jq -n \
  --argjson portBindings "\$PORT_BINDING" \
  --argjson users "\$CURRENT_USERS" \
  --arg logLevel "\$MITA_LOG_LEVEL" \
  --argjson egress "\$EGRESS_JSON" \
  '{
    portBindings: \$portBindings,
    users: \$users,
    loggingLevel: \$logLevel,
    egress: \$egress
  }' > "\${MITA_CONFIG_FILE}.tmp"

mv "\${MITA_CONFIG_FILE}.tmp" "\$MITA_CONFIG_FILE"
log "Конфиг сохранён: \$MITA_CONFIG_FILE"

# ---------- Применение конфига ----------
log "Применение конфига mita..."
# Запустить mita если не запущен (нужен для apply config)
MITA_WAS_STOPPED=false
if ! systemctl is-active --quiet mita 2>/dev/null; then
  log "mita не запущен — запускаем для применения конфига..."
  systemctl reset-failed mita 2>/dev/null || true
  /usr/bin/mita run &
  MITA_BG_PID=\$!
  sleep 3
  MITA_WAS_STOPPED=true
fi

mita apply config "\$MITA_CONFIG_FILE" && log "Конфиг применён успешно" \
  || { log "ОШИБКА применения конфига"; exit 1; }

if \$MITA_WAS_STOPPED; then
  kill \$MITA_BG_PID 2>/dev/null || true
  sleep 1
  systemctl reset-failed mita 2>/dev/null || true
  systemctl start mita && log "mita запущен" || log "WARN: не удалось запустить mita"
else
  systemctl restart mita
  log "mita перезапущен"
fi

log "Обновление завершено. Доменов: \$DOMAIN_COUNT, IP: \$IP_COUNT"
UPDATEEOF

chmod +x "$UPDATE_SCRIPT"
ok "Скрипт обновления создан: $UPDATE_SCRIPT"

# =============================================================================
# ПЕРВОНАЧАЛЬНАЯ ГЕНЕРАЦИЯ КОНФИГА С ПОЛЬЗОВАТЕЛЯМИ
# =============================================================================
section "Генерация начального конфига mita"

# Собрать JSON пользователей
USERS_JSON="["
for i in "${!MITA_USERS[@]}"; do
  entry="${MITA_USERS[$i]}"
  name="${entry%%:*}"
  pass="${entry##*:}"
  sep=$([[ $i -lt $((${#MITA_USERS[@]}-1)) ]] && echo "," || echo "")
  USERS_JSON+=$(jq -n --arg n "$name" --arg p "$pass" \
    '{name: $n, password: $p}')
  USERS_JSON+="$sep"
done
USERS_JSON+="]"

# Разбор диапазона портов для начального конфига
if [[ "$MITA_PORT_RANGE" == *"-"* ]]; then
  PORT_BINDING=$(jq -n --arg r "$MITA_PORT_RANGE" --arg p "$MITA_PROTOCOL" \
    '[{portRange: $r, protocol: $p}]')
else
  PORT_BINDING=$(jq -n --arg port "$MITA_PORT_RANGE" --arg p "$MITA_PROTOCOL" \
    '[{port: ($port|tonumber), protocol: $p}]')
fi

# Базовый конфиг без egress (применим после первого запуска update-lists)
jq -n \
  --argjson portBindings "$PORT_BINDING" \
  --argjson users "$USERS_JSON" \
  --arg logLevel "$MITA_LOG_LEVEL" \
  '{
    portBindings: $portBindings,
    users: $users,
    loggingLevel: $logLevel,
    egress: {}
  }' > "$MITA_CONFIG_FILE"

ok "Начальный конфиг записан: $MITA_CONFIG_FILE"

# Применить конфиг
mita apply config "$MITA_CONFIG_FILE"
ok "Конфиг mita применён"

# =============================================================================
# ЗАПУСК MITA
# =============================================================================
section "Запуск mita"

systemctl enable mita 2>/dev/null || true
systemctl restart mita
sleep 2
if systemctl is-active --quiet mita; then
  ok "mita запущен и работает"
else
  warn "mita не запустился — проверьте: journalctl -u mita -n 50"
fi

# =============================================================================
# НАСТРОЙКА CRON
# =============================================================================
section "Настройка автообновления (cron)"

cat > "$CRON_FILE" << EOF
# Обновление списков доменов/IP для mita — каждый день в 04:00
0 4 * * * root $UPDATE_SCRIPT >> /var/log/mita-update.log 2>&1
EOF

ok "Cron задача создана: $CRON_FILE"

# =============================================================================
# ПЕРВЫЙ ЗАПУСК ОБНОВЛЕНИЯ СПИСКОВ
# =============================================================================
section "Первое обновление списков"

info "Запуск $UPDATE_SCRIPT..."
bash "$UPDATE_SCRIPT" && ok "Списки обновлены, конфиг применён" \
  || warn "Ошибка при обновлении списков, проверьте /var/log/mita-update.log"

# =============================================================================
# ОТКРЫТИЕ ПОРТОВ В FIREWALL
# =============================================================================
section "Настройка firewall"

if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
  # UFW требует двоеточие для диапазонов: 3000:3010/tcp, а не 3000-3010/tcp
  if [[ "$MITA_PORT_RANGE" == *"-"* ]]; then
    _UFW_START="${MITA_PORT_RANGE%-*}"; _UFW_END="${MITA_PORT_RANGE#*-}"
    ufw allow "${_UFW_START}:${_UFW_END}/${MITA_PROTOCOL,,}" comment "mita proxy" 2>/dev/null || true
  else
    ufw allow "${MITA_PORT_RANGE}/${MITA_PROTOCOL,,}" comment "mita proxy" 2>/dev/null || true
  fi
  ok "UFW: порты $MITA_PORT_RANGE/$MITA_PROTOCOL открыты"
  echo ""
  warn "ВАЖНО: UFW управляет только локальным фаерволом ОС."
  warn "Если ваш VPS у облачного провайдера (Hetzner, AWS, GCP, DigitalOcean, Vultr и др.),"
  warn "откройте порты ${MITA_PORT_RANGE} (${MITA_PROTOCOL}) ТАКЖЕ в консоли провайдера"
  warn "(Security Groups / Firewall / Network Rules) — иначе подключения не будет."
  echo ""
elif command -v iptables &>/dev/null; then
  if [[ "$MITA_PORT_RANGE" == *"-"* ]]; then
    START_PORT="${MITA_PORT_RANGE%-*}"; END_PORT="${MITA_PORT_RANGE#*-}"
    iptables -I INPUT -p "${MITA_PROTOCOL,,}" --dport "$START_PORT:$END_PORT" -j ACCEPT 2>/dev/null || true
  else
    iptables -I INPUT -p "${MITA_PROTOCOL,,}" --dport "$MITA_PORT_RANGE" -j ACCEPT 2>/dev/null || true
  fi
  ok "iptables: порты открыты"
fi

# =============================================================================
# ИТОГОВЫЙ ОТЧЁТ
# =============================================================================
section "Установка завершена!"

SERVER_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════╗"
echo -e "║              УСТАНОВКА ЗАВЕРШЕНА УСПЕШНО             ║"
echo -e "╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${CYAN}Параметры сервера для клиентов:${NC}"
echo -e "  IP сервера:  ${YELLOW}$SERVER_IP${NC}"
echo -e "  Порты mita:  ${YELLOW}$MITA_PORT_RANGE ($MITA_PROTOCOL)${NC}"
echo ""
echo -e "${CYAN}Пользователи:${NC}"
for entry in "${MITA_USERS[@]}"; do
  name="${entry%%:*}"; pass="${entry##*:}"
  echo -e "  ${YELLOW}$name${NC} / $pass"
done
echo ""
echo -e "${CYAN}Файлы конфигурации:${NC}"
echo -e "  Конфиг mita:          ${YELLOW}$MITA_CONFIG_FILE${NC}"
echo -e "  Свои домены → WARP:   ${YELLOW}$CUSTOM_DOMAINS_FILE${NC}"
echo -e "  Свои IP → WARP:       ${YELLOW}$CUSTOM_IPS_FILE${NC}"
echo -e "  Авто-источники (dom): ${YELLOW}$AUTO_DOMAINS_FILE${NC}"
echo -e "  Авто-источники (IP):  ${YELLOW}$AUTO_IPS_FILE${NC}"
echo -e "  Лог обновлений:       ${YELLOW}/var/log/mita-update.log${NC}"
echo ""
echo -e "${CYAN}Полезные команды:${NC}"
echo -e "  ${YELLOW}mita status${NC}                        — статус сервера"
echo -e "  ${YELLOW}mita get users${NC}                     — список пользователей и их трафик"
echo -e "  ${YELLOW}mita describe config${NC}               — текущий конфиг"
echo -e "  ${YELLOW}$UPDATE_SCRIPT${NC}   — обновить списки вручную"
echo -e "  ${YELLOW}journalctl -u mita -f${NC}              — логи mita в реальном времени"
if $WARP_ENABLED; then
  echo -e "  ${YELLOW}docker logs cloudflare-warp${NC}        — логи WARP"
fi
echo ""
echo -e "${CYAN}Следующий шаг — добавьте нужные домены в:${NC}"
echo -e "  ${YELLOW}$CUSTOM_DOMAINS_FILE${NC}  — ваши домены"
echo -e "  ${YELLOW}$AUTO_DOMAINS_FILE${NC}       — geosite/URL источники"
echo -e "Затем запустите: ${YELLOW}$UPDATE_SCRIPT${NC}"
echo ""

# =============================================================================
# УСТАНОВКА ВЕБ-ПАНЕЛИ (опционально)
# =============================================================================
section "Веб-панель управления"

# Ищем install-panel.sh в нескольких возможных местах:
# 1) Прямо рядом с install.sh (актуальная структура архива)
# 2) В подпапке mita-panel-pkg/ (старая структура архива)
PANEL_INSTALLER=""
for candidate in \
  "$SCRIPT_DIR/install-panel.sh" \
  "$SCRIPT_DIR/mita-panel-pkg/install-panel.sh"
do
  if [[ -f "$candidate" ]]; then
    PANEL_INSTALLER="$candidate"
    break
  fi
done

if [[ -z "$PANEL_INSTALLER" ]]; then
  warn "Файл install-panel.sh не найден рядом со скриптом."
  warn "Искал в: $SCRIPT_DIR/ и $SCRIPT_DIR/mita-panel-pkg/"
  warn "Убедитесь что install-panel.sh, app.py и templates/ распакованы рядом с install.sh."
else
  echo -e "Установить веб-панель управления mita? (логин/пароль и секретный путь генерируются автоматически)"
  echo -e "  ${GREEN}y${NC} — да, установить сейчас"
  echo -e "  ${YELLOW}n${NC} — пропустить (можно установить позже: bash $PANEL_INSTALLER)"
  echo ""
  read -r -p "Установить панель? [y/N]: " INSTALL_PANEL
  echo ""

  if [[ "${INSTALL_PANEL,,}" == "y" || "${INSTALL_PANEL,,}" == "yes" ]]; then
    info "Запуск установки веб-панели..."
    echo ""
    bash "$PANEL_INSTALLER"
  else
    info "Пропускаем установку панели."
    echo -e "  Запустить позже: ${YELLOW}bash $PANEL_INSTALLER${NC}"
  fi
fi

# ── Установка mita-ctl как системной команды ──────────────────────
section "Установка утилиты управления mita-ctl"
CTL_SRC="$SCRIPT_DIR/mita-ctl.sh"
if [[ -f "$CTL_SRC" ]]; then
  cp "$CTL_SRC" /usr/local/bin/mita-ctl
  chmod +x /usr/local/bin/mita-ctl
  ok "mita-ctl установлен!"
  echo -e "  Управление сервером: ${YELLOW}sudo mita-ctl${NC}"
else
  warn "mita-ctl.sh не найден рядом с install.sh"
  warn "Установите вручную: cp mita-ctl.sh /usr/local/bin/mita-ctl && chmod +x /usr/local/bin/mita-ctl"
fi
