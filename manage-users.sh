#!/bin/bash
# =============================================================================
# mita — управление пользователями
# Использование:
#   ./manage-users.sh add <имя>          — добавить (пароль генерируется автоматически)
#   ./manage-users.sh remove <имя>
#   ./manage-users.sh list
#   ./manage-users.sh quota <имя> <дней> <GB>
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

CONFIG_FILE="/etc/mita/server_config.json"

[[ $EUID -ne 0 ]] && { echo -e "${RED}Запустите от root${NC}"; exit 1; }
[[ ! -f "$CONFIG_FILE" ]] && { echo -e "${RED}Конфиг не найден: $CONFIG_FILE${NC}"; exit 1; }

# ---------- Генерация пароля ----------
# 48 случайных байт → base64 → убираем +/= → берём 64 символа
gen_password() {
  # Расширенный набор без символов ломающих protobuf (&<>|()[]{}\")
  openssl rand -base64 48 | tr -d '/+=' | head -c 48
}

# ---------- Получить параметры сервера из конфига ----------
get_server_info() {
  SERVER_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null \
    || hostname -I | awk '{print $1}')

  # Читаем первый portBinding из конфига
  FIRST_BINDING=$(jq -r '.portBindings[0]' "$CONFIG_FILE")
  PORT_PROTOCOL=$(echo "$FIRST_BINDING" | jq -r '.protocol // "TCP"')

  # Может быть portRange или port
  if echo "$FIRST_BINDING" | jq -e '.portRange' &>/dev/null; then
    PORT_VALUE=$(echo "$FIRST_BINDING" | jq -r '.portRange')
    PORT_JSON_KEY="portRange"
  else
    PORT_VALUE=$(echo "$FIRST_BINDING" | jq -r '.port | tostring')
    PORT_JSON_KEY="port"
  fi
}

# ---------- Вывод клиентского конфига ----------
print_client_config() {
  local name="$1" pass="$2"

  # Строим portBindings для клиентского конфига
  if [[ "$PORT_JSON_KEY" == "portRange" ]]; then
    PORT_BINDING_JSON=$(jq -n \
      --arg r "$PORT_VALUE" --arg p "$PORT_PROTOCOL" \
      '[{portRange: $r, protocol: $p}]')
  else
    PORT_BINDING_JSON=$(jq -n \
      --argjson port "$PORT_VALUE" --arg p "$PORT_PROTOCOL" \
      '[{port: $port, protocol: $p}]')
  fi

  CLIENT_JSON=$(jq -n \
    --arg name    "$name" \
    --arg pass    "$pass" \
    --arg ip      "$SERVER_IP" \
    --argjson pb  "$PORT_BINDING_JSON" \
    '{
      profiles: [{
        profileName: "default",
        user: {name: $name, password: $pass},
        servers: [{
          ipAddress: $ip,
          portBindings: $pb
        }]
      }],
      activeProfile: "default",
      rpcPort: 8964,
      socks5Port: 1080
    }')

  echo ""
  echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║           КОНФИГ КЛИЕНТА — скопируйте целиком               ║${NC}"
  echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "${BOLD}Файл:${NC} mieru_client_config.json"
  echo ""
  echo "$CLIENT_JSON" | jq .
  echo ""
  echo -e "${CYAN}┌──────────────────────────────────────────────────────────────┐${NC}"
  echo -e "${CYAN}│ Команды на устройстве клиента:                               │${NC}"
  echo -e "${CYAN}│${NC}  mieru apply config mieru_client_config.json               ${CYAN}│${NC}"
  echo -e "${CYAN}│${NC}  mieru start                                               ${CYAN}│${NC}"
  echo -e "${CYAN}└──────────────────────────────────────────────────────────────┘${NC}"
  echo ""
  echo -e "${YELLOW}⚠  Сохраните пароль — он нигде не хранится в открытом виде:${NC}"
  echo -e "   Пользователь: ${BOLD}$name${NC}"
  echo -e "   Пароль:       ${BOLD}$pass${NC}"
  echo ""
}

cmd="${1:-list}"

case "$cmd" in

  # ------------------------------------------------------------------
  add)
    [[ $# -lt 2 ]] && { echo "Использование: $0 add <имя>"; exit 1; }
    NAME="$2"

    # Проверить не существует ли уже
    EXISTS=$(jq --arg n "$NAME" '.users[] | select(.name == $n)' "$CONFIG_FILE")
    [[ -n "$EXISTS" ]] && { echo -e "${YELLOW}Пользователь '$NAME' уже существует${NC}"; exit 1; }

    # Сгенерировать пароль
    PASS=$(gen_password)

    # Добавить пользователя в конфиг
    jq --arg n "$NAME" --arg p "$PASS" \
      '.users += [{name: $n, password: $p}]' \
      "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"

    # Применить конфиг
    mita apply config "$CONFIG_FILE"
    echo -e "${GREEN}✓ Пользователь '${NAME}' добавлен${NC}"

    # Показать клиентский конфиг
    get_server_info
    print_client_config "$NAME" "$PASS"
    ;;

  # ------------------------------------------------------------------
  remove)
    [[ $# -lt 2 ]] && { echo "Использование: $0 remove <имя>"; exit 1; }
    NAME="$2"

    jq --arg n "$NAME" 'del(.users[] | select(.name == $n))' \
      "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"

    mita apply config "$CONFIG_FILE"
    echo -e "${GREEN}✓ Пользователь '$NAME' удалён${NC}"
    ;;

  # ------------------------------------------------------------------
  list)
    echo -e "${CYAN}Пользователи в конфиге:${NC}"
    jq -r '.users[] | "  \(.name)"' "$CONFIG_FILE"
    echo ""
    echo -e "${CYAN}Статистика (из mita):${NC}"
    mita get users 2>/dev/null || echo "  (mita не запущен)"
    ;;

  # ------------------------------------------------------------------
  quota)
    [[ $# -lt 4 ]] && { echo "Использование: $0 quota <имя> <дней> <GB>"; exit 1; }
    NAME="$2"; DAYS="$3"; GB="$4"
    MB=$(echo "$GB * 1024" | bc | cut -d. -f1)

    jq --arg n "$NAME" --argjson d "$DAYS" --argjson m "$MB" \
      '(.users[] | select(.name == $n)).quotas = [{days: $d, megabytes: $m}]' \
      "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"

    mita apply config "$CONFIG_FILE"
    echo -e "${GREEN}✓ Квота для '$NAME': ${GB}GB / ${DAYS} дней${NC}"
    ;;

  *)
    echo "Команды: add | remove | list | quota"
    exit 1
    ;;
esac
