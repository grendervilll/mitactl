#!/bin/bash
# =============================================================================
# mita-ctl — утилита управления mita сервером
# Запуск: sudo bash mita-ctl.sh
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()      { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERR]${NC}  $*"; }
section() { echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo -e "${CYAN}  $*${NC}"; echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }
hr()      { echo -e "${BLUE}─────────────────────────────────────────────────${NC}"; }
pause()   { echo ""; read -r -p "Нажмите Enter для продолжения..." _; }

[[ $EUID -ne 0 ]] && { echo -e "${RED}Запустите от root: sudo bash mita-ctl.sh${NC}"; exit 1; }

PANEL_CONFIG="/etc/mita/panel.json"
PANEL_ENV="/etc/mita/panel.env"
MITA_CONFIG="/etc/mita/server_config.json"

load_panel() {
  [[ -f "$PANEL_CONFIG" ]] && cat "$PANEL_CONFIG" || echo "{}"
}
panel_value() { load_panel | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('$1',''))" 2>/dev/null || echo ""; }
env_value()   { [[ -f "$PANEL_ENV" ]] && grep "^$1=" "$PANEL_ENV" | cut -d= -f2- || echo ""; }

_panel_proto() {
  local ssl_cert
  ssl_cert=$(env_value "SSL_CERT")
  if [[ -n "$ssl_cert" && -f "$ssl_cert" ]]; then
    echo "https"
  else
    echo "http"
  fi
}

gen_pass() { openssl rand -base64 48 | tr -d '/+=' | head -c 32; }

# ── SSH tunnel helper ──────────────────────────────────────────────────────
print_ssh_instruction() {
  local port="$1"
  local secret="$2"
  local ssh_port="${3:-22}"
  local server_ip
  server_ip=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
  echo ""
  echo -e "${CYAN}┌─────────────────────────────────────────────────────────┐${NC}"
  echo -e "${CYAN}│  Подключение к панели через SSH-туннель                 │${NC}"
  echo -e "${CYAN}└─────────────────────────────────────────────────────────┘${NC}"
  echo ""
  echo -e "  Выполните на ${BOLD}вашем компьютере${NC}:"
  echo ""
  echo -e "  ${YELLOW}ssh -L ${port}:127.0.0.1:${port} -p ${ssh_port} root@${server_ip} -N${NC}"
  echo ""
  echo -e "  Затем откройте в браузере:"
  echo -e "  ${BOLD}${GREEN}$(_panel_proto)://127.0.0.1:${port}/${secret}/${NC}"
  echo ""
  echo -e "  ${BLUE}Флаг -N означает что SSH не выполняет команды, только туннель.${NC}"
  echo -e "  ${BLUE}Для фонового режима добавьте -f:${NC}"
  echo -e "  ${YELLOW}ssh -fN -L ${port}:127.0.0.1:${port} -p ${ssh_port} root@${server_ip}${NC}"
  echo ""
}

# ════════════════════════════════════════════════════════════════════════════
# ГЛАВНОЕ МЕНЮ
# ════════════════════════════════════════════════════════════════════════════
main_menu() {
  while true; do
    clear
    echo -e "${CYAN}"
    echo "  ╔══════════════════════════════════════════════════════╗"
    echo "  ║              mita-ctl  —  Управление сервером        ║"
    echo "  ╚══════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo -e "  ${BOLD}1.${NC}  Сменить способ подключения к панели"
    echo -e "  ${BOLD}2.${NC}  Управление портами (firewall)"
    echo -e "  ${BOLD}3.${NC}  Сменить порт веб-панели"
    echo -e "  ${BOLD}4.${NC}  Перевыпустить SSL-сертификат панели"
    echo -e "  ${BOLD}5.${NC}  Управление пользователями mita"
    echo -e "  ${BOLD}6.${NC}  Показать логин и пароль админа панели"
    echo -e "  ${BOLD}7.${NC}  Изменить данные администратора панели"
    echo -e "  ${BOLD}8.${NC}  Настройка fail2ban"
    echo -e "  ${BOLD}9.${NC}  Рекомендации по безопасности VPS"
    echo -e "  ${RED}${BOLD}10.${NC} ${RED}Полное удаление mita, панели и WARP${NC}"
    echo -e "  ${BOLD}11.${NC} Показать текущую конфигурацию"
    echo -e "  ${BOLD}12.${NC} Управление Telegram-ботом"
    echo -e "  ${BOLD}13.${NC} ${CYAN}Обновить панель и утилиты из GitHub${NC}"
    echo -e "  ${BOLD}0.${NC}  Выход"
    echo ""
    read -r -p "  Выберите пункт: " choice
    case "$choice" in
      1) menu_panel_access ;;
      2) menu_firewall ;;
      3) menu_change_panel_port ;;
      4) menu_ssl ;;
      5) menu_users ;;
      6) menu_show_admin ;;
      7) menu_change_admin ;;
      8) menu_fail2ban ;;
      9) menu_security ;;
      10) menu_uninstall ;;
      11) menu_show_config ;;
      12) menu_bot ;;
      13) menu_update ;;
      0) exit 0 ;;
      *) warn "Неверный выбор" ;;
    esac
  done
}

# ════════════════════════════════════════════════════════════════════════════
# 1. СПОСОБ ПОДКЛЮЧЕНИЯ К ПАНЕЛИ
# ════════════════════════════════════════════════════════════════════════════
menu_panel_access() {
  section "Способ подключения к панели"
  local panel_port secret ssh_port
  panel_port=$(env_value "PANEL_PORT"); panel_port=${panel_port:-8080}
  secret=$(panel_value "secret_path")

  echo -e "  Текущий порт панели: ${YELLOW}${panel_port}${NC}"
  echo -e "  Текущий секретный путь: ${YELLOW}/${secret}/${NC}"
  echo ""
  echo -e "  ${BOLD}1.${NC}  SSH-туннель (панель недоступна снаружи)"
  echo -e "  ${BOLD}2.${NC}  По IP-адресу (текущий способ)"
  echo -e "  ${BOLD}3.${NC}  По доменному имени с Let's Encrypt"
  echo -e "  ${BOLD}0.${NC}  Назад"
  echo ""
  read -r -p "  Выбор: " choice

  case "$choice" in
    1)
      section "SSH-туннель"
      echo "Панель будет слушать только на 127.0.0.1 (недоступна снаружи)."
      echo ""
      read -r -p "SSH-порт вашего VPS [22]: " ssh_port
      ssh_port=${ssh_port:-22}

      # Привязать gunicorn к 127.0.0.1
      _update_panel_bind "127.0.0.1" "$panel_port"

      # Закрыть порт панели в firewall
      _fw_close "$panel_port" "tcp"

      # Обновить panel.json
      python3 -c "
import json
with open('$PANEL_CONFIG') as f: d=json.load(f)
d['access_mode']='ssh'
d['ssh_port']=$ssh_port
with open('$PANEL_CONFIG','w') as f: json.dump(d,f,indent=2)
"
      systemctl restart mita-panel 2>/dev/null || true
      ok "Панель переключена на SSH-туннель"
      print_ssh_instruction "$panel_port" "$secret" "$ssh_port"
      pause
      ;;

    2)
      section "Доступ по IP"
      local server_ip
      server_ip=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')

      _update_panel_bind "0.0.0.0" "$panel_port"
      _fw_open "$panel_port" "tcp"

      python3 -c "
import json
with open('$PANEL_CONFIG') as f: d=json.load(f)
d['access_mode']='ip'
with open('$PANEL_CONFIG','w') as f: json.dump(d,f,indent=2)
"
      systemctl restart mita-panel 2>/dev/null || true
      ok "Панель доступна по IP"
      echo ""
      echo -e "  Адрес: ${BOLD}${GREEN}$(_panel_proto)://${server_ip}:${panel_port}/${secret}/${NC}"
      pause
      ;;

    3)
      section "Let's Encrypt"
      read -r -p "Домен (например panel.example.com): " domain
      read -r -p "Email для Let's Encrypt (Enter = пропустить): " email
      [[ -z "$domain" ]] && { warn "Домен не указан"; pause; return; }

      # Установить certbot
      command -v certbot &>/dev/null || apt-get install -y -qq certbot

      local le_args=("certbot" "certonly" "--standalone" "--non-interactive" "--agree-tos" "-d" "$domain")
      [[ -n "$email" ]] && le_args+=("--email" "$email") || le_args+=("--register-unsafely-without-email")

      info "Получение сертификата Let's Encrypt..."
      if "${le_args[@]}"; then
        local cert="/etc/letsencrypt/live/${domain}/fullchain.pem"
        local key="/etc/letsencrypt/live/${domain}/privkey.pem"
        _update_env_val "SSL_CERT" "$cert"
        _update_env_val "SSL_KEY"  "$key"
        _update_panel_bind "0.0.0.0" "$panel_port"
        _fw_open "$panel_port" "tcp"
        python3 -c "
import json
with open('$PANEL_CONFIG') as f: d=json.load(f)
d.update({'access_mode':'domain','ssl_type':'letsencrypt','ssl_domain':'$domain','ssl_cert':'$cert','ssl_key':'$key'})
with open('$PANEL_CONFIG','w') as f: json.dump(d,f,indent=2)
"
        # Настроить автопродление
        (crontab -l 2>/dev/null; echo "0 3 * * * certbot renew --quiet && systemctl restart mita-panel") | sort -u | crontab -
        systemctl restart mita-panel 2>/dev/null || true
        ok "Сертификат получен"
        echo -e "  Адрес: ${BOLD}${GREEN}https://${domain}:${panel_port}/${secret}/${NC}"
      else
        error "Не удалось получить сертификат. Убедитесь что домен указывает на этот сервер и порт 80 открыт."
      fi
      pause
      ;;
    0) return ;;
  esac
}

_update_panel_bind() {
  local host="$1" port="$2"
  # Обновить ExecStart в systemd unit через враппер start.sh
  sed -i "s/--bind [0-9.:]*:[0-9]*/--bind ${host}:${port}/" /opt/mita-panel/start.sh 2>/dev/null || true
  # Обновить PANEL_PORT в env
  _update_env_val "PANEL_BIND_HOST" "$host"
  # Пересоздать start.sh с нужным bind
  cat > /opt/mita-panel/start.sh << STARTEOF
#!/bin/bash
set -a; source /etc/mita/panel.env; set +a
SSL_ARGS=""
if [[ -n "\$SSL_CERT" && -n "\$SSL_KEY" && -f "\$SSL_CERT" && -f "\$SSL_KEY" ]]; then
  SSL_ARGS="--certfile=\$SSL_CERT --keyfile=\$SSL_KEY"
fi
exec /opt/mita-panel/venv/bin/gunicorn \\
    --bind ${host}:\${PANEL_PORT} \\
    --workers 2 --timeout 120 \\
    --access-logfile /var/log/mita-panel-access.log \\
    --error-logfile /var/log/mita-panel.log \\
    \$SSL_ARGS app:app
STARTEOF
  chmod +x /opt/mita-panel/start.sh
}

_update_env_val() {
  local key="$1" val="$2"
  if grep -q "^${key}=" "$PANEL_ENV" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${val}|" "$PANEL_ENV"
  else
    echo "${key}=${val}" >> "$PANEL_ENV"
  fi
}

# ════════════════════════════════════════════════════════════════════════════
# 2. FIREWALL
# ════════════════════════════════════════════════════════════════════════════
menu_firewall() {
  section "Управление портами (Firewall)"

  # Определить активный firewall
  local FW="none"
  command -v ufw &>/dev/null && ufw status | grep -q "Status: active" && FW="ufw"
  [[ "$FW" == "none" ]] && command -v iptables &>/dev/null && FW="iptables"

  info "Активный firewall: $FW"
  echo ""
  echo -e "  ${BOLD}1.${NC}  Открыть порт"
  echo -e "  ${BOLD}2.${NC}  Закрыть порт"
  echo -e "  ${BOLD}3.${NC}  Применить рекомендуемые правила (только нужные порты)"
  echo -e "  ${BOLD}4.${NC}  Показать текущие правила"
  echo -e "  ${BOLD}0.${NC}  Назад"
  echo ""
  read -r -p "  Выбор: " choice

  case "$choice" in
    1)
      read -r -p "Порт: " p; read -r -p "Протокол [tcp]: " proto; proto=${proto:-tcp}
      _fw_open "$p" "$proto" && ok "Порт $p/$proto открыт"
      pause ;;
    2)
      read -r -p "Порт: " p; read -r -p "Протокол [tcp]: " proto; proto=${proto:-tcp}
      _fw_close "$p" "$proto" && ok "Порт $p/$proto закрыт"
      pause ;;
    3)
      section "Рекомендуемые правила"
      local panel_port mita_range
      panel_port=$(env_value "PANEL_PORT"); panel_port=${panel_port:-8080}
      mita_range=$(python3 -c "
import json
with open('$MITA_CONFIG') as f: d=json.load(f)
b=d.get('portBindings',[{}])[0]
print(b.get('portRange',b.get('port','2100-2110')))
" 2>/dev/null || echo "2100-2110")

      read -r -p "SSH-порт вашего VPS [22]: " ssh_port
      ssh_port=${ssh_port:-22}

      local access_mode
      access_mode=$(panel_value "access_mode")

      info "Настраиваю правила:"
      info "  SSH: $ssh_port/tcp"
      info "  mita: $mita_range/tcp"
      [[ "$access_mode" != "ssh" ]] && info "  Панель: $panel_port/tcp" || info "  Панель: закрыта (SSH-туннель)"

      if [[ "$FW" == "ufw" ]]; then
        ufw --force reset 2>/dev/null
        ufw default deny incoming
        ufw default allow outgoing
        ufw allow "$ssh_port/tcp" comment "SSH"
        # mita ports
        local start_p end_p
        if [[ "$mita_range" == *"-"* ]]; then
          start_p="${mita_range%-*}"; end_p="${mita_range#*-}"
          ufw allow "${start_p}:${end_p}/tcp" comment "mita"
        else
          ufw allow "$mita_range/tcp" comment "mita"
        fi
        [[ "$access_mode" != "ssh" ]] && ufw allow "$panel_port/tcp" comment "mita-panel"
        ufw --force enable
      else
        iptables -F INPUT 2>/dev/null
        iptables -P INPUT DROP
        iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
        iptables -A INPUT -i lo -j ACCEPT
        iptables -A INPUT -p tcp --dport "$ssh_port" -j ACCEPT
        if [[ "$mita_range" == *"-"* ]]; then
          start_p="${mita_range%-*}"; end_p="${mita_range#*-}"
          iptables -A INPUT -p tcp --dport "${start_p}:${end_p}" -j ACCEPT
        else
          iptables -A INPUT -p tcp --dport "$mita_range" -j ACCEPT
        fi
        [[ "$access_mode" != "ssh" ]] && iptables -A INPUT -p tcp --dport "$panel_port" -j ACCEPT
        command -v iptables-save &>/dev/null && iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
      fi
      ok "Правила применены"
      pause ;;
    4)
      echo ""
      if [[ "$FW" == "ufw" ]]; then ufw status numbered
      else iptables -L INPUT -n --line-numbers; fi
      pause ;;
    0) return ;;
  esac
}

_fw_open() {
  local port="$1" proto="${2:-tcp}"
  if [[ "$port" == *"-"* ]]; then
    local _s="${port%-*}" _e="${port#*-}"
    command -v ufw &>/dev/null && ufw status | grep -q "Status: active" \
      && ufw allow "${_s}:${_e}/${proto}" 2>/dev/null || true
    iptables -I INPUT -p "$proto" --dport "${_s}:${_e}" -j ACCEPT 2>/dev/null || true
  else
    command -v ufw &>/dev/null && ufw status | grep -q "Status: active" \
      && ufw allow "${port}/${proto}" 2>/dev/null || true
    iptables -I INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null || true
  fi
}

_fw_close() {
  local port="$1" proto="${2:-tcp}"
  if [[ "$port" == *"-"* ]]; then
    local _s="${port%-*}" _e="${port#*-}"
    command -v ufw &>/dev/null && ufw status | grep -q "Status: active" \
      && ufw delete allow "${_s}:${_e}/${proto}" 2>/dev/null || true
    iptables -D INPUT -p "$proto" --dport "${_s}:${_e}" -j ACCEPT 2>/dev/null || true
  else
    command -v ufw &>/dev/null && ufw status | grep -q "Status: active" \
      && ufw delete allow "${port}/${proto}" 2>/dev/null || true
    iptables -D INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null || true
  fi
}

# ════════════════════════════════════════════════════════════════════════════
# 3. СМЕНИТЬ ПОРТ ВЕБ-ПАНЕЛИ
# ════════════════════════════════════════════════════════════════════════════
menu_change_panel_port() {
  section "Смена порта веб-панели"

  local current_port new_port
  current_port=$(env_value "PANEL_PORT"); current_port=${current_port:-8080}
  local access_mode
  access_mode=$(panel_value "access_mode")

  echo -e "  Текущий порт: ${YELLOW}${current_port}${NC}"
  if [[ "$access_mode" == "ssh" ]]; then
    echo -e "  Режим доступа: ${YELLOW}SSH-туннель (панель на 127.0.0.1)${NC}"
  fi
  echo ""

  while true; do
    read -r -p "  Новый порт [${current_port}]: " new_port
    new_port=${new_port:-$current_port}
    if [[ "$new_port" == "$current_port" ]]; then
      info "Порт не изменился"
      pause
      return
    fi
    if [[ ! "$new_port" =~ ^[0-9]+$ ]] || [[ $new_port -lt 1024 || $new_port -gt 65535 ]]; then
      warn "Порт должен быть числом от 1024 до 65535"
      continue
    fi
    if ss -tlnp 2>/dev/null | grep -q ":${new_port}[[:space:]]"; then
      warn "Порт $new_port уже занят. Выберите другой."
      continue
    fi
    break
  done

  echo ""
  info "Смена порта с $current_port на $new_port..."

  # 1. Обновить panel.env
  _update_env_val "PANEL_PORT" "$new_port"

  # 2. Пересоздать start.sh с новым портом (сохраняя bind host)
  local bind_host="0.0.0.0"
  [[ "$access_mode" == "ssh" ]] && bind_host="127.0.0.1"

  cat > /opt/mita-panel/start.sh << STARTEOF
#!/bin/bash
set -a; source /etc/mita/panel.env; set +a
SSL_ARGS=""
if [[ -n "\$SSL_CERT" && -n "\$SSL_KEY" && -f "\$SSL_CERT" && -f "\$SSL_KEY" ]]; then
  SSL_ARGS="--certfile=\$SSL_CERT --keyfile=\$SSL_KEY"
fi
exec /opt/mita-panel/venv/bin/gunicorn \\
    --bind ${bind_host}:${new_port} \\
    --workers 2 --timeout 120 \\
    --access-logfile /var/log/mita-panel-access.log \\
    --error-logfile /var/log/mita-panel.log \\
    \$SSL_ARGS app:app
STARTEOF
  chmod +x /opt/mita-panel/start.sh

  # 3. Обновить firewall
  if [[ "$access_mode" != "ssh" ]]; then
    _fw_close "$current_port" "tcp"
    _fw_open "$new_port" "tcp"
  fi

  # 4. Перезапустить панель
  systemctl restart mita-panel 2>/dev/null || true
  sleep 1

  if systemctl is-active --quiet mita-panel; then
    ok "Панель перезапущена на порту $new_port"
    local proto
    proto=$(_panel_proto)
    local secret server_ip
    secret=$(env_value "SECRET_PATH")
    server_ip=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
    echo ""
    echo -e "  Новый адрес: ${BOLD}${GREEN}${proto}://${server_ip}:${new_port}/${secret}/${NC}"
    if [[ "$access_mode" == "ssh" ]]; then
      local ssh_port
      ssh_port=$(panel_value "ssh_port"); ssh_port=${ssh_port:-22}
      print_ssh_instruction "$new_port" "$secret" "$ssh_port"
    fi
  else
    error "Панель не запустилась. Проверьте: journalctl -u mita-panel -n 20"
    warn "Возвращаю старый порт $current_port..."
    _update_env_val "PANEL_PORT" "$current_port"
    sed -i "s/--bind ${bind_host}:${new_port}/--bind ${bind_host}:${current_port}/" /opt/mita-panel/start.sh 2>/dev/null || true
    systemctl restart mita-panel 2>/dev/null || true
  fi

  pause
}

# ════════════════════════════════════════════════════════════════════════════
# 4. SSL
# ════════════════════════════════════════════════════════════════════════════
menu_ssl() {
  section "Перевыпуск SSL-сертификата"
  echo -e "  ${BOLD}1.${NC}  Самоподписной (10 лет)"
  echo -e "  ${BOLD}2.${NC}  Let's Encrypt"
  echo -e "  ${BOLD}0.${NC}  Назад"
  echo ""
  read -r -p "  Выбор: " choice

  case "$choice" in
    1)
      local cert_dir="/etc/mita/ssl"
      mkdir -p "$cert_dir"
      openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
        -keyout "$cert_dir/selfsigned.key" -out "$cert_dir/selfsigned.crt" \
        -subj "/CN=mita-panel/O=mita/C=XX" 2>/dev/null
      _update_env_val "SSL_CERT" "$cert_dir/selfsigned.crt"
      _update_env_val "SSL_KEY"  "$cert_dir/selfsigned.key"
      python3 -c "
import json
with open('$PANEL_CONFIG') as f: d=json.load(f)
d.update({'ssl_type':'selfsigned','ssl_cert':'$cert_dir/selfsigned.crt','ssl_key':'$cert_dir/selfsigned.key'})
with open('$PANEL_CONFIG','w') as f: json.dump(d,f,indent=2)
"
      _rebuild_start_sh
      systemctl restart mita-panel 2>/dev/null || true
      ok "Самоподписной сертификат создан и применён"
      pause ;;
    2)
      local domain
      read -r -p "Домен: " domain
      [[ -z "$domain" ]] && { warn "Не указан домен"; pause; return; }
      command -v certbot &>/dev/null || apt-get install -y -qq certbot
      if certbot renew --cert-name "$domain" --quiet 2>/dev/null || \
         certbot certonly --standalone --non-interactive --agree-tos \
           --register-unsafely-without-email -d "$domain"; then
        local cert="/etc/letsencrypt/live/${domain}/fullchain.pem"
        local key="/etc/letsencrypt/live/${domain}/privkey.pem"
        _update_env_val "SSL_CERT" "$cert"
        _update_env_val "SSL_KEY"  "$key"
        python3 -c "
import json
with open('$PANEL_CONFIG') as f: d=json.load(f)
d.update({'ssl_type':'letsencrypt','ssl_domain':'$domain','ssl_cert':'$cert','ssl_key':'$key'})
with open('$PANEL_CONFIG','w') as f: json.dump(d,f,indent=2)
"
        _rebuild_start_sh
        systemctl restart mita-panel 2>/dev/null || true
        ok "Сертификат Let's Encrypt выпущен и применён"
      else
        error "Не удалось выпустить сертификат"
      fi
      pause ;;
    0) return ;;
  esac
}

_rebuild_start_sh() {
  local bind_host
  bind_host=$(panel_value "access_mode")
  [[ "$bind_host" == "ssh" ]] && bind_host="127.0.0.1" || bind_host="0.0.0.0"
  _update_panel_bind "$bind_host" "$(env_value PANEL_PORT)"
}

# ════════════════════════════════════════════════════════════════════════════
# 5. ПОЛЬЗОВАТЕЛИ
# ════════════════════════════════════════════════════════════════════════════
# ── Общая функция: безопасное применение конфига mita ───────────────────────
# Запускает mita если он не активен (нужно для apply config),
# применяет конфиг, возвращает демон в исходное состояние.
# Возвращает 0 при успехе, 1 при ошибке. Текст ошибки — в stdout.
_apply_mita_config() {
  local MITA_WAS_STOPPED=false
  local MITA_BG_PID=""

  if ! systemctl is-active --quiet mita 2>/dev/null; then
    systemctl reset-failed mita 2>/dev/null || true
    rm -f /etc/mita/server.conf.pb 2>/dev/null
    /usr/bin/mita run &
    MITA_BG_PID=$!
    sleep 2
    MITA_WAS_STOPPED=true
  fi

  local apply_out apply_rc
  apply_out=$(mita apply config "$MITA_CONFIG" 2>&1)
  apply_rc=$?

  if $MITA_WAS_STOPPED; then
    kill "$MITA_BG_PID" 2>/dev/null || true
    wait "$MITA_BG_PID" 2>/dev/null || true
    sleep 1
  fi

  if [[ $apply_rc -ne 0 ]]; then
    echo "$apply_out"
    return 1
  fi

  [[ -f /etc/mita/server.conf.pb ]] && chown mita:mita /etc/mita/server.conf.pb 2>/dev/null

  systemctl reset-failed mita 2>/dev/null || true
  systemctl restart mita
  sleep 1
  return 0
}

_delete_user() {
  local uname="$1"
  local result
  result=$(python3 << PYEOF
import json
with open('$MITA_CONFIG') as f: d=json.load(f)
before=len(d.get('users',[]))
d['users']=[u for u in d.get('users',[]) if u['name']!='$uname']
after=len(d['users'])
with open('$MITA_CONFIG','w') as f: json.dump(d,f,indent=2)
print("DELETED" if before>after else "NOTFOUND")
PYEOF
)

  if [[ "$result" == "NOTFOUND" ]]; then
    warn "Пользователь '$uname' не найден"
    return 1
  fi

  if _apply_mita_config; then
    if systemctl is-active --quiet mita; then
      ok "Пользователь '$uname' удалён, mita работает"
    else
      warn "Пользователь удалён, но mita не запустился — проверьте: journalctl -u mita -n 20"
    fi
  else
    error "Ошибка применения конфига после удаления пользователя"
  fi
}

menu_users() {
  section "Управление пользователями mita"

  # Показать текущих пользователей
  echo -e "${CYAN}Текущие пользователи:${NC}"
  python3 -c "
import json
with open('$MITA_CONFIG') as f: d=json.load(f)
users=d.get('users',[])
if not users: print('  (нет пользователей)')
for u in users: print(f'  - {u[\"name\"]}')
"
  echo ""
  echo -e "  ${BOLD}1.${NC}  Создать одного пользователя (своё имя)"
  echo -e "  ${BOLD}2.${NC}  Создать несколько с рандомными именами"
  echo -e "  ${BOLD}3.${NC}  Удалить пользователя"
  echo -e "  ${BOLD}4.${NC}  Показать конфиг существующего пользователя"
  echo -e "  ${BOLD}0.${NC}  Назад"
  echo ""
  read -r -p "  Выбор: " choice

  # Запрашиваем сложность пароля один раз перед созданием
  local pwd_mode="hard"
  if [[ "$choice" == "1" || "$choice" == "2" ]]; then
    echo ""
    echo -e "  ${BOLD}Сложность пароля:${NC}"
    echo -e "  ${BOLD}1.${NC}  Лёгкий — A-Z, a-z, 0-9, -._~*+ (без спецсимволов)"
    echo -e "  ${BOLD}2.${NC}  Сложный — со спецсимволами (по умолчанию)"
    echo ""
    read -r -p "  Выбор [2]: " pwd_choice
    [[ "$pwd_choice" == "1" ]] && pwd_mode="easy"
  fi

  case "$choice" in
    1)
      read -r -p "Имя пользователя: " uname
      [[ -z "$uname" ]] && { warn "Имя не указано"; pause; return; }
      _create_user "$uname" "$pwd_mode"
      pause ;;
    2)
      read -r -p "Количество пользователей: " cnt
      [[ ! "$cnt" =~ ^[0-9]+$ ]] && { warn "Неверное число"; pause; return; }
      for i in $(seq 1 "$cnt"); do
        local adj noun rnd uname
        adj=$(shuf -n1 -e swift brave quiet cool sharp calm bright dark wild free 2>/dev/null || echo "user")
        noun=$(shuf -n1 -e fox hawk river storm ember peak orbit tide frost spark 2>/dev/null || echo "node")
        rnd=$((RANDOM % 9000 + 1000))
        uname="${adj}_${noun}_${rnd}"
        _create_user "$uname" "$pwd_mode"
      done
      pause ;;
    3)
      read -r -p "Имя пользователя для удаления: " uname
      _delete_user "$uname"
      pause ;;
    4)
      read -r -p "Имя пользователя: " uname
      _show_user_config "$uname"
      pause ;;
    0) return ;;
  esac
}

_show_user_config() {
  local uname="$1"
  python3 << PYEOF
import json
with open('$MITA_CONFIG') as f: d=json.load(f)
user = next((u for u in d.get('users',[]) if u['name']=='$uname'), None)
if not user:
    print("Пользователь '$uname' не найден")
else:
    import subprocess
    server_ip=subprocess.run(['curl','-s','--max-time','5','ifconfig.me'],capture_output=True,text=True).stdout.strip()
    cfg=d.get('portBindings',[{}])[0]
    port=cfg.get('portRange',str(cfg.get('port','2100-2110')))
    first_port = port.split('-')[0] if '-' in port else port
    print(f"\n  Параметры для ручного ввода в Karing/sing-box клиентах:")
    print(f"    server:       {server_ip}")
    print(f"    server port:  {first_port}")
    print(f"    username:     {user['name']}")
    print(f"    password:     {user['password']}")
    print(f"    transport:    TCP")
    print(f"    multiplexing: multiplexing_low")
PYEOF
  echo ""
  read -r -p "Показать подробную инструкцию по добавлению в Karing? [y/N]: " show_karing
  [[ "${show_karing,,}" == "y" ]] && print_karing_instructions
}

_create_user() {
  local uname="$1"
  local pwd_mode="$2"
  local pass
  if [[ "$pwd_mode" == "easy" ]]; then
    pass=$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9-._~*+' | head -c 32)
  else
    pass=$(openssl rand -base64 48 | tr -d '/+=' | head -c 48)
  fi

  # Записываем пользователя в JSON и проверяем результат явно
  local py_result
  py_result=$(python3 << PYEOF
import json, sys
try:
    with open('$MITA_CONFIG') as f: d=json.load(f)
except Exception as e:
    print(f"ERROR_READ:{e}")
    sys.exit(1)

if any(u['name']=='$uname' for u in d.get('users',[])):
    print("EXISTS")
    sys.exit(0)

d.setdefault('users',[]).append({'name':'$uname','password':'$pass'})
try:
    with open('$MITA_CONFIG','w') as f: json.dump(d,f,indent=2)
except Exception as e:
    print(f"ERROR_WRITE:{e}")
    sys.exit(1)

print("WRITTEN")
PYEOF
)

  if [[ "$py_result" == "EXISTS" ]]; then
    warn "Пользователь '$uname' уже существует"
    return 1
  fi
  if [[ "$py_result" != "WRITTEN" ]]; then
    error "Не удалось записать конфиг: $py_result"
    return 1
  fi

  local apply_err
  apply_err=$(_apply_mita_config)
  if [[ $? -ne 0 ]]; then
    error "mita apply config завершился с ошибкой:"
    echo "$apply_err"
    return 1
  fi

  if systemctl is-active --quiet mita; then
    ok "Создан: $uname"
  else
    warn "Пользователь создан, но mita не запустился — проверьте: journalctl -u mita -n 20"
  fi

  echo "  Пароль: $pass"

  # Показать клиентский конфиг
  python3 << PYEOF
import json, subprocess
with open('$MITA_CONFIG') as f: d=json.load(f)
server_ip=subprocess.run(['curl','-s','--max-time','5','ifconfig.me'],capture_output=True,text=True).stdout.strip()
cfg=d.get('portBindings',[{}])[0]
port=cfg.get('portRange',str(cfg.get('port','2100-2110')))
proto=cfg.get('protocol','TCP')
client={
    'profiles':[{'profileName':'default','user':{'name':'$uname','password':'$pass'},
        'servers':[{'ipAddress':server_ip,'portBindings':[{'portRange':port,'protocol':proto}]}]}],
    'activeProfile':'default','rpcPort':8964,'socks5Port':1080
}
print(f"\n  Клиентский конфиг (mieru CLI):")
print(json.dumps(client,indent=2,ensure_ascii=False))

first_port = port.split('-')[0] if '-' in port else port
print(f"\n  Параметры для ручного ввода в Karing/sing-box клиентах:")
print(f"    server:       {server_ip}")
print(f"    server port:  {first_port}")
print(f"    username:     $uname")
print(f"    password:     $pass")
print(f"    transport:    TCP")
print(f"    multiplexing: multiplexing_low")
PYEOF

  echo ""
  read -r -p "Показать подробную инструкцию по добавлению в Karing? [y/N]: " show_karing
  [[ "${show_karing,,}" == "y" ]] && print_karing_instructions
}

print_karing_instructions() {
  echo ""
  echo -e "${CYAN}┌─────────────────────────────────────────────────────────────────┐${NC}"
  echo -e "${CYAN}│  Ручное добавление сервера в Karing                              │${NC}"
  echo -e "${CYAN}└─────────────────────────────────────────────────────────────────┘${NC}"
  cat << 'KARINGEOF'

   1.  Откройте Karing → добавить профиль
   2.  Выберите тип "Custom" и впишите любое имя
   3.  Перейдите в раздел "My profiles"
   4.  Нажмите "+" в поле только что созданного профиля
   5.  В выпадающем списке протоколов выберите "Mieru"
   6.  В поле "tag" впишите любое название (например: proxy)
   7.  Заполните "server" и "server port" — значения выше (IP и порт)
   8.  Заполните "username" и "password" — значения выше
   9.  В поле "multiplexing" выберите "multiplexing_low"
  10.  В поле "transport" впишите ЗАГЛАВНЫМИ БУКВАМИ: TCP
       Затем нажмите ✓ в правом верхнем углу.
       Убедитесь что тумблер профиля в "My profiles" зелёный,
       затем нажмите кнопку подключения в главном меню Karing.
  11.  Diversion Rules (разделение трафика) — направить конкретные
       сайты/приложения мимо VPN или через него:
         a) Нажмите карандаш (✏) в правом верхнем углу "Diversion Rules"
         b) Нажмите "⋮" там же → "+ Add"
         c) Введите название правила, прокрутите список вниз,
            выберите созданное правило
         d) Добавьте нужные адреса/приложения, нажмите ✓ вверху справа
         e) Вернитесь в "Diversion Rules", найдите правило внизу списка
         f) Нажмите на него → "Direct" (мимо VPN)
            или раскройте имя профиля → выберите его (через VPN)

KARINGEOF
  pause
}

# ════════════════════════════════════════════════════════════════════════════
# 6. ПОКАЗАТЬ ДАННЫЕ АДМИНА
# ════════════════════════════════════════════════════════════════════════════
# ── Общая функция: вывод логина/пароля/URL панели с учётом access_mode ──────
_print_panel_access_info() {
  local user pass secret panel_port access_mode
  user=$(panel_value "admin_user")
  pass=$(panel_value "admin_pass")
  secret=$(panel_value "secret_path")
  panel_port=$(env_value "PANEL_PORT"); panel_port=${panel_port:-8080}
  access_mode=$(panel_value "access_mode")
  local server_ip
  server_ip=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')

  echo ""
  echo -e "  Логин:          ${BOLD}${YELLOW}${user}${NC}"
  echo -e "  Пароль:         ${BOLD}${YELLOW}${pass}${NC}"
  echo -e "  Секретный путь: ${BOLD}/${secret}/${NC}"
  echo ""

  case "$access_mode" in
    ssh)
      local ssh_port
      ssh_port=$(panel_value "ssh_port"); ssh_port=${ssh_port:-22}
      echo -e "  Способ доступа: ${YELLOW}SSH-туннель${NC} (панель не торчит наружу)"
      print_ssh_instruction "$panel_port" "$secret" "$ssh_port"
      ;;
    domain)
      local proto="http" domain
      [[ -n "$(panel_value ssl_cert)" ]] && proto="https"
      domain=$(panel_value "ssl_domain")
      echo -e "  Способ доступа: ${YELLOW}Доменное имя${NC}"
      if [[ -n "$domain" ]]; then
        echo -e "  Адрес: ${BOLD}${GREEN}${proto}://${domain}:${panel_port}/${secret}/${NC}"
      else
        warn "Домен не настроен в panel.json, показываю по IP"
        echo -e "  Адрес: ${BOLD}${GREEN}${proto}://${server_ip}:${panel_port}/${secret}/${NC}"
      fi
      ;;
    *)
      local proto="http"
      [[ -n "$(panel_value ssl_cert)" ]] && proto="https"
      echo -e "  Способ доступа: ${YELLOW}По IP-адресу${NC}"
      echo -e "  Адрес: ${BOLD}${GREEN}${proto}://${server_ip}:${panel_port}/${secret}/${NC}"
      ;;
  esac
}

menu_show_admin() {
  section "Данные администратора панели"
  _print_panel_access_info
  pause
}

# ════════════════════════════════════════════════════════════════════════════
# 11. КОНФИГУРАЦИЯ СЕРВЕРА
# ════════════════════════════════════════════════════════════════════════════
menu_show_config() {
  section "Текущая конфигурация сервера"

  # ── Доступ к панели ───────────────────────────────────────────
  echo -e "${CYAN}── Веб-панель ──────────────────────────────────────────${NC}"
  if [[ -f "$PANEL_CONFIG" ]]; then
    _print_panel_access_info
  else
    warn "Панель не установлена (panel.json не найден)"
  fi

  echo ""
  echo -e "${CYAN}── Статус сервисов ─────────────────────────────────────${NC}"

  local mita_active panel_active warp_active f2b_active ufw_active
  systemctl is-active --quiet mita        2>/dev/null && mita_active=true  || mita_active=false
  systemctl is-active --quiet mita-panel  2>/dev/null && panel_active=true || panel_active=false
  systemctl is-active --quiet fail2ban    2>/dev/null && f2b_active=true   || f2b_active=false
  command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active" && ufw_active=true || ufw_active=false

  warp_active=false
  if command -v docker &>/dev/null && docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^cloudflare-warp$"; then
    warp_active=true
  fi

  _status_line() {
    local label="$1" active="$2"
    if [[ "$active" == "true" ]]; then
      echo -e "  ${label}: ${GREEN}● работает${NC}"
    else
      echo -e "  ${label}: ${RED}● остановлен/не установлен${NC}"
    fi
  }

  _status_line "mita сервер     " "$mita_active"
  _status_line "Веб-панель      " "$panel_active"
  _status_line "Cloudflare WARP " "$warp_active"
  _status_line "fail2ban        " "$f2b_active"
  _status_line "UFW             " "$ufw_active"

  # ── mita: пользователи и порты ─────────────────────────────────
  echo ""
  echo -e "${CYAN}── mita сервер ─────────────────────────────────────────${NC}"
  if [[ -f "$MITA_CONFIG" ]]; then
    python3 -c "
import json
with open('$MITA_CONFIG') as f: d=json.load(f)
bindings = d.get('portBindings', [{}])
b = bindings[0] if bindings else {}
port = b.get('portRange', str(b.get('port','?')))
proto = b.get('protocol','?')
users = d.get('users', [])
print(f'  Порты:          {port} ({proto})')
print(f'  Пользователей:  {len(users)}')
for u in users:
    print(f'    - {u[\"name\"]}')
egress = d.get('egress', {})
if egress.get('rules'):
    print(f'  WARP egress:    настроен ({len(egress[\"rules\"])} правил)')
else:
    print(f'  WARP egress:    не настроен')
"
  else
    warn "Конфиг mita не найден ($MITA_CONFIG)"
  fi

  # ── fail2ban лимиты ───────────────────────────────────────────
  echo ""
  echo -e "${CYAN}── fail2ban (лимит входа в панель) ─────────────────────${NC}"
  local max_retry ban_time
  max_retry=$(panel_value "login_max_attempts"); max_retry=${max_retry:-"не настроено"}
  ban_time=$(panel_value  "login_ban_seconds");  ban_time=${ban_time:-"не настроено"}
  echo -e "  Попыток до блокировки: ${YELLOW}${max_retry}${NC}"
  echo -e "  Время блокировки:      ${YELLOW}${ban_time}${NC} сек"

  # ── SSL ───────────────────────────────────────────────────────
  echo ""
  echo -e "${CYAN}── SSL-сертификат панели ────────────────────────────────${NC}"
  local ssl_type
  ssl_type=$(panel_value "ssl_type")
  if [[ -z "$ssl_type" || "$ssl_type" == "none" ]]; then
    echo -e "  Тип: ${RED}не настроен${NC} (панель работает по HTTP)"
  else
    echo -e "  Тип:     ${YELLOW}${ssl_type}${NC}"
    [[ -n "$(panel_value ssl_domain)" ]] && echo -e "  Домен:   ${YELLOW}$(panel_value ssl_domain)${NC}"
    echo -e "  Файл:    $(panel_value ssl_cert)"
  fi

  # ── Версии ────────────────────────────────────────────────────
  echo ""
  echo -e "${CYAN}── Версии ──────────────────────────────────────────────${NC}"
  command -v mita &>/dev/null && echo -e "  mita:   $(mita version 2>/dev/null || echo '?')"
  command -v docker &>/dev/null && echo -e "  docker: $(docker --version 2>/dev/null | cut -d, -f1)"

  # ── Расположение файлов ───────────────────────────────────
  echo ""
  echo -e "${CYAN}── Расположение файлов ─────────────────────────────────${NC}"
  echo -e "  Конфиг mita:        ${YELLOW}${MITA_CONFIG}${NC}"
  echo -e "  Конфиг панели:      ${YELLOW}${PANEL_CONFIG}${NC}"
  echo -e "  Переменные панели:  ${YELLOW}${PANEL_ENV}${NC}"
  echo -e "  Директория панели:  ${YELLOW}/opt/mita-panel${NC}"
  echo -e "  Утилита mita-ctl:   ${YELLOW}/usr/local/bin/mita-ctl${NC}"

  pause
}

# ════════════════════════════════════════════════════════════════════════════
# 7. ИЗМЕНИТЬ ДАННЫЕ АДМИНА
# ════════════════════════════════════════════════════════════════════════════
menu_change_admin() {
  section "Изменение данных администратора"
  echo -e "  ${BOLD}1.${NC}  Сгенерировать новый пароль автоматически"
  echo -e "  ${BOLD}2.${NC}  Задать свой пароль"
  echo -e "  ${BOLD}0.${NC}  Назад"
  echo ""
  read -r -p "  Выбор: " choice

  local new_pass
  case "$choice" in
    1) new_pass=$(gen_pass) ;;
    2)
      read -r -s -p "Новый пароль (мин. 12 символов): " new_pass; echo ""
      [[ ${#new_pass} -lt 12 ]] && { warn "Пароль слишком короткий"; pause; return; }
      ;;
    0) return ;;
    *) warn "Неверный выбор"; pause; return ;;
  esac

  python3 -c "
import json
with open('$PANEL_CONFIG') as f: d=json.load(f)
d['admin_pass']='$new_pass'
with open('$PANEL_CONFIG','w') as f: json.dump(d,f,indent=2)
"
  systemctl restart mita-panel 2>/dev/null || true
  ok "Пароль изменён"
  echo ""
  echo -e "  Новый пароль: ${BOLD}${YELLOW}${new_pass}${NC}"
  echo -e "  Логин:        ${BOLD}$(panel_value admin_user)${NC}"
  pause
}

# ════════════════════════════════════════════════════════════════════════════
# 8. БЕЗОПАСНОСТЬ VPS
# ════════════════════════════════════════════════════════════════════════════
menu_security() {
  section "Рекомендации по безопасности VPS"
  echo ""
  cat << 'SECEOF'
  ┌─────────────────────────────────────────────────────────────────┐
  │  КРИТИЧЕСКИ ВАЖНО                                               │
  └─────────────────────────────────────────────────────────────────┘

  1. ВХОД ПО SSH-КЛЮЧУ (отключить пароли)
     # Сгенерируйте ключ на своём компьютере:
     ssh-keygen -t ed25519 -C "vps-key"
     # Скопируйте на сервер:
     ssh-copy-id -p 22 root@YOUR_IP
     # Отключите вход по паролю (/etc/ssh/sshd_config):
     PasswordAuthentication no
     PubkeyAuthentication yes
     systemctl restart sshd

  2. СМЕНИТЕ ПОРТ SSH (заменить 22 на нестандартный)
     # В /etc/ssh/sshd_config:
     Port 2222   # любой свободный порт
     systemctl restart sshd
     # Не забудьте открыть новый порт в firewall!

  3. FAIL2BAN (блокировка перебора паролей)
     apt-get install -y fail2ban
     systemctl enable fail2ban --now

  ┌─────────────────────────────────────────────────────────────────┐
  │  ВАЖНО                                                          │
  └─────────────────────────────────────────────────────────────────┘

  4. АВТООБНОВЛЕНИЕ БЕЗОПАСНОСТИ
     apt-get install -y unattended-upgrades
     dpkg-reconfigure -plow unattended-upgrades

  5. МИНИМУМ ОТКРЫТЫХ ПОРТОВ
     Используйте пункт 2 этого меню → "Рекомендуемые правила".
     Открытыми должны быть только: SSH, порты mita, порт панели (если не SSH-туннель).

  6. ПАНЕЛЬ ЧЕРЕЗ SSH-ТУННЕЛЬ
     Самый безопасный вариант — панель вообще не торчит наружу.
     Используйте пункт 1 главного меню для переключения.

  7. СЕКРЕТНЫЙ ПУТЬ ПАНЕЛИ
     Никогда не делитесь ссылкой на панель. Без секретного пути
     сервер возвращает 404 на все запросы.

  ┌─────────────────────────────────────────────────────────────────┐
  │  ДОПОЛНИТЕЛЬНО                                                  │
  └─────────────────────────────────────────────────────────────────┘

  8. МОНИТОРИНГ ВХОДОВ
     last             # последние входы
     journalctl -u ssh --since "1 hour ago"
     grep "Failed" /var/log/auth.log | tail -20

  9. ПРОВЕРКА ОТКРЫТЫХ ПОРТОВ
     ss -tlnp         # что слушает на сервере
     nmap -p- YOUR_IP # что видно снаружи (запускать со своего ПК)

  10. РЕГУЛЯРНЫЕ ОБНОВЛЕНИЯ
      apt-get update && apt-get upgrade -y

SECEOF
  pause
}

# ════════════════════════════════════════════════════════════════════════════
# 9. FAIL2BAN
# ════════════════════════════════════════════════════════════════════════════
menu_fail2ban() {
  section "Настройка fail2ban для панели"

  local installed=false active=false
  command -v fail2ban-client &>/dev/null && installed=true
  $installed && systemctl is-active --quiet fail2ban && active=true

  echo -e "  fail2ban установлен: $($installed && echo "${GREEN}да${NC}" || echo "${RED}нет${NC}")"
  $installed && echo -e "  fail2ban активен:    $($active && echo "${GREEN}да${NC}" || echo "${RED}нет${NC}")"
  echo ""

  local pc_maxretry pc_bantime
  pc_maxretry=$(python3 -c "import json; d=json.load(open('$PANEL_CONFIG')); print(d.get('login_max_attempts',5))" 2>/dev/null || echo 5)
  pc_bantime=$(python3 -c  "import json; d=json.load(open('$PANEL_CONFIG')); print(d.get('login_ban_seconds',3600))" 2>/dev/null || echo 3600)
  echo -e "  Текущие лимиты: ${YELLOW}${pc_maxretry} попыток${NC} / ${YELLOW}${pc_bantime} сек${NC}"
  echo ""
  echo -e "  ${BOLD}1.${NC}  Строгий    — 3 попытки / 30 минут"
  echo -e "  ${BOLD}2.${NC}  Стандарт   — 5 попыток / 1 час"
  echo -e "  ${BOLD}3.${NC}  Мягкий     — 10 попыток / 15 минут"
  echo -e "  ${BOLD}4.${NC}  Жёсткий    — 3 попытки / 24 часа"
  echo -e "  ${BOLD}5.${NC}  Ручная настройка"
  echo -e "  ${BOLD}6.${NC}  Установить/переустановить fail2ban"
  echo -e "  ${BOLD}0.${NC}  Назад"
  echo ""
  read -r -p "  Выбор: " choice

  local max_retry ban_time
  case "$choice" in
    1) max_retry=3;  ban_time=1800  ;;
    2) max_retry=5;  ban_time=3600  ;;
    3) max_retry=10; ban_time=900   ;;
    4) max_retry=3;  ban_time=86400 ;;
    5)
      read -r -p "  Попыток до блокировки [5]: " max_retry
      max_retry=${max_retry:-5}
      echo "  Время блокировки:"
      echo "    1) 5 минут  2) 15 минут  3) 30 минут"
      echo "    4) 1 час    5) 24 часа   6) 7 дней   7) Своё (сек)"
      read -r -p "  Выбор [4]: " bt_choice
      case "${bt_choice:-4}" in
        1) ban_time=300   ;; 2) ban_time=900   ;; 3) ban_time=1800  ;;
        4) ban_time=3600  ;; 5) ban_time=86400 ;; 6) ban_time=604800;;
        7) read -r -p "  Секунды: " ban_time ;;
        *) ban_time=3600  ;;
      esac
      ;;
    6)
      info "Установка fail2ban..."
      apt-get install -y -qq fail2ban
      systemctl enable fail2ban --now
      ok "fail2ban установлен и запущен"
      pause; return ;;
    0) return ;;
    *) warn "Неверный выбор"; pause; return ;;
  esac

  # Применить
  _apply_fail2ban "$max_retry" "$ban_time"
  pause
}

_apply_fail2ban() {
  local max_retry="$1" ban_time="$2"

  # Обновить panel.json
  python3 -c "
import json
with open('$PANEL_CONFIG') as f: d=json.load(f)
d['login_max_attempts']=$max_retry
d['login_ban_seconds']=$ban_time
with open('$PANEL_CONFIG','w') as f: json.dump(d,f,indent=2)
"

  # Записать fail2ban конфиг
  if command -v fail2ban-client &>/dev/null; then
    mkdir -p /etc/fail2ban/filter.d /etc/fail2ban/jail.d
    cat > /etc/fail2ban/filter.d/mita-panel.conf << EOF
[Definition]
failregex = ^<HOST> .+ "POST /[^"]+/login[^"]*" 4(?:01|29).*$
ignoreregex =
EOF
    cat > /etc/fail2ban/jail.d/mita-panel.conf << EOF
[mita-panel]
enabled  = true
filter   = mita-panel
backend  = auto
logpath  = /var/log/mita-panel-access.log
maxretry = $max_retry
bantime  = $ban_time
findtime = $ban_time
EOF
    if systemctl restart fail2ban 2>/dev/null && systemctl is-active --quiet fail2ban; then
      ok "fail2ban настроен и запущен: $max_retry попыток / ${ban_time}с"
    else
      warn "fail2ban настроен, но не запустился. Проверьте: journalctl -u fail2ban -n 20"
    fi
  else
    warn "fail2ban не установлен — лимиты сохранены только в panel.json"
  fi

  # Перезапустить панель чтобы подхватила новые лимиты
  systemctl restart mita-panel 2>/dev/null || true
  ok "Настройки применены. Попыток: $max_retry, бан: ${ban_time}с"
}

# ════════════════════════════════════════════════════════════════════════════
# 12. TELEGRAM БОТ
# ════════════════════════════════════════════════════════════════════════════
menu_bot() {
  section "Управление Telegram-ботом"

  BOT_SERVICE="mita-bot"
  BOT_DIR="/opt/mita-bot"
  BOT_CONFIG="/etc/mita/bot.json"

  local installed=false running=false
  if [[ -f "/etc/systemd/system/${BOT_SERVICE}.service" ]]; then
    installed=true
    systemctl is-active --quiet "$BOT_SERVICE" && running=true
  fi

  echo ""
  if $installed; then
    echo -e "  Статус:    ${GREEN}● Установлен${NC}"
    if $running; then
      echo -e "  Состояние: ${GREEN}● Активен${NC}"
    else
      echo -e "  Состояние: ${RED}● Остановлен${NC}"
    fi
    if [[ -f "$BOT_CONFIG" ]]; then
      local token
      token=$(python3 -c "import json; d=json.load(open('$BOT_CONFIG')); print(d.get('token','')[:8]+'…')" 2>/dev/null || echo "—")
      echo -e "  Токен:     ${YELLOW}${token}${NC}"
      local admins
      admins=$(python3 -c "import json; d=json.load(open('$BOT_CONFIG')); print(', '.join(d.get('admin_ids',[])))" 2>/dev/null || echo "—")
      echo -e "  Админы ID: ${YELLOW}${admins}${NC}"
    fi
  else
    echo -e "  Статус:    ${YELLOW}● Не установлен${NC}"
  fi

  echo ""
  echo -e "  ${BOLD}1.${NC}  Установить / обновить бота"
  echo -e "  ${BOLD}2.${NC}  Перезапустить бота"
  echo -e "  ${BOLD}3.${NC}  Добавить админа (Telegram ID)"
  echo -e "  ${BOLD}4.${NC}  Логи бота (journalctl)"
  if $installed; then
    echo -e "  ${RED}${BOLD}5.${NC}  ${RED}Удалить бота${NC}"
  fi
  echo -e "  ${BOLD}0.${NC}  Назад"
  echo ""
  read -r -p "  Выбор: " choice

  case "$choice" in
    1) _bot_install ;;
    2) _bot_restart ;;
    3) _bot_add_admin ;;
    4) journalctl -u "$BOT_SERVICE" -f --no-pager -n 50 ;;
    5)
      if $installed; then
        read -r -p "  Точно удалить бота? [y/N]: " del
        if [[ "${del,,}" == "y" ]]; then
          _bot_uninstall
        fi
      fi
      ;;
  esac
}

_bot_install() {
  section "Установка Telegram-бота"

  local installer=""
  for candidate in /opt/mita-panel/install-bot.sh; do
    [[ -f "$candidate" ]] && { installer="$candidate"; break; }
  done

  if [[ -z "$installer" ]]; then
    error "install-bot.sh не найден. Поместите его в /opt/mita-panel/"
    pause
    return
  fi

  read -r -p "Токен бота (от @BotFather): " token
  [[ -z "$token" ]] && { error "Токен обязателен"; return; }

  echo ""
  info "Определение вашего Telegram ID..."
  echo -e "  Отправьте ${YELLOW}любое сообщение${NC} своему боту в Telegram прямо сейчас."
  echo -e "  Ожидание сообщения (макс. 60 сек)..."

  admin_id=""
  for i in $(seq 1 30); do
    admin_id=$(curl -s --max-time 5 "https://api.telegram.org/bot${token}/getUpdates" 2>/dev/null | \
      python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    ids=[r['message']['from']['id'] for r in d.get('result',[]) if 'message' in r and 'from' in r['message']]
    print(ids[-1] if ids else '')
except: pass
" 2>/dev/null)
    [[ -n "$admin_id" ]] && break
    sleep 2
  done

  if [[ -z "$admin_id" || ! "$admin_id" =~ ^[0-9]+$ ]]; then
    warn "Не удалось определить ID автоматически."
    read -r -p "Впишите ваш Telegram ID вручную (число): " admin_id
  else
    ok "Telegram ID определён: ${GREEN}${admin_id}${NC}"
  fi
  [[ -z "$admin_id" || ! "$admin_id" =~ ^[0-9]+$ ]] && { error "ID должен быть числом"; return; }

  BOT_TOKEN_NONINTERACTIVE="$token" BOT_ADMIN_NONINTERACTIVE="$admin_id" bash "$installer"
  pause
}

_bot_restart() {
  section "Перезапуск бота"
  BOT_SERVICE="mita-bot"
  systemctl restart "$BOT_SERVICE" 2>/dev/null || true
  sleep 1
  if systemctl is-active --quiet "$BOT_SERVICE"; then
    ok "Бот перезапущен"
  else
    warn "Бот не запустился. Проверьте: journalctl -u $BOT_SERVICE -f"
  fi
  pause
}

_bot_add_admin() {
  section "Добавление админа"
  BOT_CONFIG="/etc/mita/bot.json"
  [[ ! -f "$BOT_CONFIG" ]] && { error "Бот не установлен"; return; }

  read -r -p "Telegram ID нового админа (число): " new_id
  [[ -z "$new_id" || ! "$new_id" =~ ^[0-9]+$ ]] && { error "ID должен быть числом"; return; }

  python3 -c "
import json
with open('$BOT_CONFIG') as f: d=json.load(f)
ids=d.get('admin_ids',[])
if '$new_id' not in ids: ids.append('$new_id')
d['admin_ids']=ids
with open('$BOT_CONFIG','w') as f: json.dump(d,f,indent=2)
"
  systemctl restart mita-bot 2>/dev/null || true
  ok "Админ $new_id добавлен"
  pause
}

_bot_uninstall() {
  section "Удаление Telegram-бота"
  BOT_SERVICE="mita-bot"
  systemctl stop "$BOT_SERVICE" 2>/dev/null || true
  systemctl disable "$BOT_SERVICE" 2>/dev/null || true
  rm -f "/etc/systemd/system/${BOT_SERVICE}.service"
  systemctl daemon-reload 2>/dev/null || true
  rm -rf /opt/mita-bot
  rm -f /etc/mita/bot.json
  ok "Бот удалён"
  pause
}

# ════════════════════════════════════════════════════════════════════════════
# 13. ОБНОВЛЕНИЕ ПАНЕЛИ И УТИЛИТ ИЗ GITHUB
# ════════════════════════════════════════════════════════════════════════════
menu_update() {
  section "Обновление панели и утилит из GitHub"

  REPO_URL="https://github.com/grendervilll/mitactl.git"
  TMP_DIR="/tmp/mita-update-$$"
  PANEL_DIR="/opt/mita-panel"
  BOT_DIR="/opt/mita-bot"

  echo ""
  echo -e "  ${GREEN}Будут обновлены только файлы кода:${NC}"
  echo -e "    • веб-панель: app.py, templates/, static/"
  echo -e "    • Telegram-бот: bot.py"
  echo -e "    • CLI-утилита: mita-ctl.sh"
  echo ""
  echo -e "  ${GREEN}НЕ затрагиваются:${NC}"
  echo -e "    • пользователи и пароли (/etc/mita/server_config.json)"
  echo -e "    • данные админа, SSL, fail2ban, WARP (/etc/mita/panel.json)"
  echo -e "    • сертификаты (/etc/mita/ssl/)"
  echo -e "    • токен бота и ID админов (/etc/mita/bot.json)"
  echo -e "    • все конфиги и настройки остаются нетронутыми"
  echo ""

  read -r -p "  Продолжить обновление? [y/N]: " confirm
  [[ "${confirm,,}" != "y" && "${confirm,,}" != "yes" ]] && { warn "Отменено"; pause; return; }

  echo ""
  info "Репозиторий: $REPO_URL"

  if ! command -v git &>/dev/null; then
    info "Установка git..."
    apt-get install -y -qq git 2>/dev/null || { error "Не удалось установить git"; return; }
  fi

  info "Клонирование репозитория..."
  rm -rf "$TMP_DIR"
  if ! git clone --depth 1 "$REPO_URL" "$TMP_DIR" 2>/dev/null; then
    error "Не удалось клонировать репозиторий. Проверьте URL и доступ в интернет."
    rm -rf "$TMP_DIR"
    pause
    return
  fi
  ok "Клонировано в $TMP_DIR"

  local updated=()

  # ── веб-панель ─────────────────────────────────────────────────
  if [[ -d "$PANEL_DIR" && -d "$PANEL_DIR/templates" ]]; then
    info "Обновление веб-панели..."
    [[ -f "$TMP_DIR/app.py" ]] && cp "$TMP_DIR/app.py" "$PANEL_DIR/" && updated+=("веб-панель (app.py)")
    if [[ -d "$TMP_DIR/templates" ]]; then
      rsync -a --delete "$TMP_DIR/templates/" "$PANEL_DIR/templates/" 2>/dev/null || \
        cp -r "$TMP_DIR/templates/"* "$PANEL_DIR/templates/"
      updated+=("веб-панель (templates)")
    fi
    [[ -d "$TMP_DIR/static" ]] && mkdir -p "$PANEL_DIR/static" && cp -r "$TMP_DIR/static/"* "$PANEL_DIR/static/" 2>/dev/null && updated+=("веб-панель (static)")
    systemctl restart mita-panel 2>/dev/null || true
    ok "Веб-панель обновлена"
  else
    info "Веб-панель не установлена — пропускаем"
  fi

  # ── Telegram-бот ────────────────────────────────────────────────
  if [[ -d "$BOT_DIR" && -f "$TMP_DIR/bot.py" ]]; then
    info "Обновление Telegram-бота..."
    cp "$TMP_DIR/bot.py" "$BOT_DIR/"
    systemctl restart mita-bot 2>/dev/null || true
    ok "Бот обновлён"
    updated+=("Telegram-бот")
  else
    info "Бот не установлен — пропускаем"
  fi

  # ── mita-ctl ────────────────────────────────────────────────────
  if [[ -f "$TMP_DIR/mita-ctl.sh" ]]; then
    info "Обновление mita-ctl..."
    cp "$TMP_DIR/mita-ctl.sh" /usr/local/bin/mita-ctl
    chmod +x /usr/local/bin/mita-ctl
    ok "mita-ctl обновлён"
    updated+=("mita-ctl")
  fi

  # ── install-bot.sh ──────────────────────────────────────────────
  [[ -f "$TMP_DIR/install-bot.sh" ]] && cp "$TMP_DIR/install-bot.sh" "$PANEL_DIR/" 2>/dev/null && updated+=("install-bot.sh")

  rm -rf "$TMP_DIR"

  echo ""
  if [[ ${#updated[@]} -gt 0 ]]; then
    ok "Обновлено: ${updated[*]}"
  else
    warn "Ничего не обновлено — установите компоненты перед обновлением"
  fi

  echo -e "  ${YELLOW}Рекомендуется перезапустить сессию mita-ctl для применения обновления самой утилиты.${NC}"
  pause
}

# ════════════════════════════════════════════════════════════════════════════
# 10. ПОЛНОЕ УДАЛЕНИЕ
# ════════════════════════════════════════════════════════════════════════════
menu_uninstall() {
  clear
  echo -e "${RED}"
  echo "  ╔══════════════════════════════════════════════════════════════╗"
  echo "  ║                  ⚠  ПОЛНОЕ УДАЛЕНИЕ  ⚠                       ║"
  echo "  ╚══════════════════════════════════════════════════════════════╝"
  echo -e "${NC}"
  echo "  Эта операция безвозвратно удалит:"
  echo ""
  echo -e "    ${YELLOW}•${NC} mita сервер (бинарник, systemd unit, конфиги)"
  echo -e "    ${YELLOW}•${NC} Веб-панель (/opt/mita-panel, systemd unit)"
  echo -e "    ${YELLOW}•${NC} Cloudflare WARP (Docker-контейнер)"
  echo -e "    ${YELLOW}•${NC} Telegram-бот (/opt/mita-bot, systemd unit)"
  echo -e "    ${YELLOW}•${NC} Все пользователи и пароли (/etc/mita/)"
  echo -e "    ${YELLOW}•${NC} SSL-сертификаты, выпущенные для панели"
  echo -e "    ${YELLOW}•${NC} Правила fail2ban для панели"
  echo -e "    ${YELLOW}•${NC} Cron-задачи обновления списков доменов"
  echo -e "    ${YELLOW}•${NC} Сама утилита mita-ctl (/usr/local/bin/mita-ctl)"
  echo ""
  echo -e "  ${RED}${BOLD}Это действие необратимо. Все данные будут потеряны.${NC}"
  echo ""

  read -r -p "  Введите слово УДАЛИТЬ для подтверждения: " confirm1
  if [[ "$confirm1" != "УДАЛИТЬ" ]]; then
    warn "Отменено — слово не совпадает"
    pause
    return
  fi

  echo ""
  read -r -p "  Вы точно уверены? Введите 'да' ещё раз: " confirm2
  if [[ "${confirm2,,}" != "да" ]]; then
    warn "Отменено"
    pause
    return
  fi

  echo ""
  section "Удаление в процессе..."

  # ── 0. Сохраняем порты до удаления файлов ──────────────────────
  # Читаем параметры заранее — файлы конфигурации удалим позже
  _MITA_RANGE="2100-2110"
  if [[ -f "$MITA_CONFIG" ]]; then
    _MITA_RANGE=$(python3 -c "
import json
try:
    with open('$MITA_CONFIG') as f: d=json.load(f)
    b=d.get('portBindings',[{}])[0]
    print(b.get('portRange',str(b.get('port','2100-2110'))))
except: print('2100-2110')
" 2>/dev/null || echo "2100-2110")
  fi

  _PANEL_PORT="8080"
  if [[ -f "$PANEL_ENV" ]]; then
    _PANEL_PORT=$(grep "^PANEL_PORT=" "$PANEL_ENV" 2>/dev/null | cut -d= -f2 || true)
  fi
  _PANEL_PORT=${_PANEL_PORT:-8080}

  # Определяем SSH порт — пользователь вводит сам, автоопределение как подсказка
  _SSH_DETECTED=$(grep -E "^[[:space:]]*Port[[:space:]]+" /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -1 || true)
  _SSH_DETECTED=${_SSH_DETECTED:-22}
  echo ""
  read -r -p "  SSH порт, который НЕ нужно закрывать [${_SSH_DETECTED}]: " _SSH_INPUT
  _SSH_PORT="${_SSH_INPUT:-$_SSH_DETECTED}"
  info "SSH порт $_SSH_PORT будет сохранён"
  info "Порты mita для закрытия: $_MITA_RANGE"
  info "Порт панели для закрытия: $_PANEL_PORT"

  # ── 1. Остановить и удалить веб-панель ─────────────────────────
  info "Остановка mita-panel..."
  systemctl stop mita-panel 2>/dev/null || true
  systemctl disable mita-panel 2>/dev/null || true
  rm -f /etc/systemd/system/mita-panel.service
  rm -rf /opt/mita-panel
  ok "Веб-панель удалена"

  # ── 2. Остановить и удалить mita сервер ────────────────────────
  info "Остановка mita..."
  systemctl stop mita 2>/dev/null || true
  systemctl disable mita 2>/dev/null || true

  # Сначала пробуем штатное удаление через dpkg/apt — пока unit-файл
  # ещё на месте, иначе pre/post-removal скрипты пакета падают
  DEB_PKG=$(dpkg -l 2>/dev/null | grep -i "^ii.*mita" | awk '{print $2}' | head -1 || true)
  if [[ -n "$DEB_PKG" ]]; then
    apt-get remove -y -qq "$DEB_PKG" 2>/dev/null \
      || dpkg --remove --force-remove-reinstreq "$DEB_PKG" 2>/dev/null \
      || true
  fi

  # Затем подчищаем то, что могло остаться вручную
  rm -f /usr/lib/systemd/system/mita.service
  rm -f /etc/systemd/system/mita.service
  rm -f /usr/bin/mita
  dpkg --configure -a 2>/dev/null || true
  ok "mita сервер удалён"

  # ── 3. Удалить WARP (Docker) ───────────────────────────────────
  if command -v docker &>/dev/null; then
    info "Удаление WARP контейнера..."
    docker rm -f cloudflare-warp 2>/dev/null || true
    docker rmi seiry/cloudflare-warp-proxy 2>/dev/null || true
    ok "WARP контейнер удалён"
  fi

  # ── 4. Удалить конфиги и данные ────────────────────────────────
  info "Удаление конфигов и пользователей..."
  rm -rf /etc/mita
  rm -rf /var/lib/mita
  rm -rf /var/run/mita
  rm -f /var/log/mita-panel*.log
  rm -f /var/log/mita-update.log
  ok "Конфиги и данные удалены"

  # ── 5. Удалить SSL-сертификаты Let's Encrypt (если выпускались) ─
  if command -v certbot &>/dev/null; then
    local domains
    domains=$(certbot certificates 2>/dev/null | grep "Domains:" | awk '{print $2}' || true)
    if [[ -n "$domains" ]]; then
      info "Найдены сертификаты Let's Encrypt: $domains"
      read -r -p "  Удалить их тоже? [y/N]: " del_certs
      if [[ "${del_certs,,}" == "y" ]]; then
        for d in $domains; do
          certbot delete --cert-name "$d" --non-interactive 2>/dev/null || true
        done
        ok "Сертификаты удалены"
      fi
    fi
  fi

  # ── 6. Удалить правила fail2ban ────────────────────────────────
  info "Удаление правил fail2ban для панели..."
  rm -f /etc/fail2ban/filter.d/mita-panel.conf
  rm -f /etc/fail2ban/jail.d/mita-panel.conf
  systemctl restart fail2ban 2>/dev/null || true
  ok "Правила fail2ban удалены (сам fail2ban не тронут — может использоваться для SSH)"

  # ── 7. Удалить cron-задачи ──────────────────────────────────────
  info "Удаление cron-задач..."
  crontab -l 2>/dev/null | grep -v "mita-update-lists" | grep -v "certbot renew --quiet && systemctl restart mita-panel" | crontab - 2>/dev/null || true
  rm -f /etc/cron.d/mita-update
  rm -f /usr/local/bin/mita-update-lists
  ok "Cron-задачи удалены"

  # ── 7a. Удалить Telegram-бота ────────────────────────────────────
  if [[ -f "/etc/systemd/system/mita-bot.service" ]]; then
    info "Удаление Telegram-бота..."
    systemctl stop mita-bot 2>/dev/null || true
    systemctl disable mita-bot 2>/dev/null || true
    rm -f /etc/systemd/system/mita-bot.service
    systemctl daemon-reload 2>/dev/null || true
    rm -rf /opt/mita-bot
    rm -f /etc/mita/bot.json
    ok "Telegram-бот удалён"
  fi

  # ── 8. Закрыть порты в firewall ────────────────────────────────
  info "Закрытие портов mita ($_MITA_RANGE) и панели ($_PANEL_PORT) в firewall..."
  info "SSH порт $_SSH_PORT будет явно сохранён открытым."

  _UFW_ACTIVE=false
  command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active" && _UFW_ACTIVE=true

  # ---- UFW ----
  if $_UFW_ACTIVE; then
    # Сначала явно гарантируем SSH, ПОТОМ удаляем остальные правила
    ufw allow "$_SSH_PORT/tcp" comment "SSH" 2>/dev/null || true

    # Удаляем правило mita (диапазон или одиночный порт)
    if [[ "$_MITA_RANGE" == *"-"* ]]; then
      _SP="${_MITA_RANGE%-*}"; _EP="${_MITA_RANGE#*-}"
      ufw delete allow "${_SP}:${_EP}/tcp" 2>/dev/null || true
      ufw delete allow "${_SP}:${_EP}/udp" 2>/dev/null || true
    else
      ufw delete allow "$_MITA_RANGE/tcp" 2>/dev/null || true
      ufw delete allow "$_MITA_RANGE/udp" 2>/dev/null || true
    fi
    # Удаляем правило панели
    ufw delete allow "$_PANEL_PORT/tcp" 2>/dev/null || true
    # Дополнительно: чистим правила по комментарию (совместимость с разными версиями)
    ufw status numbered 2>/dev/null | { grep -iE "mita|panel" || true; } | awk -F'[][]' '{gsub(/[[:space:]]/, "", $2); print $2}' | sort -rn | while read -r num; do
      [[ -n "$num" ]] && yes | ufw delete "$num" 2>/dev/null || true
    done
    ok "UFW: правила удалены, SSH ($_SSH_PORT) сохранён"
  fi

  # ---- iptables (только когда UFW не управляет firewall) ----
  if ! $_UFW_ACTIVE && command -v iptables &>/dev/null; then
    if [[ "$_MITA_RANGE" == *"-"* ]]; then
      _SP="${_MITA_RANGE%-*}"; _EP="${_MITA_RANGE#*-}"
      iptables -D INPUT -p tcp --dport "${_SP}:${_EP}" -j ACCEPT 2>/dev/null || true
      iptables -D INPUT -p udp --dport "${_SP}:${_EP}" -j ACCEPT 2>/dev/null || true
    else
      iptables -D INPUT -p tcp --dport "$_MITA_RANGE" -j ACCEPT 2>/dev/null || true
      iptables -D INPUT -p udp --dport "$_MITA_RANGE" -j ACCEPT 2>/dev/null || true
    fi
    iptables -D INPUT -p tcp --dport "$_PANEL_PORT" -j ACCEPT 2>/dev/null || true
    # Явно обеспечиваем SSH-правило первым в цепочке
    iptables -D INPUT -p tcp --dport "$_SSH_PORT" -j ACCEPT 2>/dev/null || true
    iptables -I INPUT 1 -p tcp --dport "$_SSH_PORT" -j ACCEPT 2>/dev/null || true
    # Сохраняем правила
    command -v iptables-save &>/dev/null && iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    ok "iptables: правила удалены, SSH ($_SSH_PORT) сохранён"
  fi

  ok "Firewall: порты mita и панели закрыты. SSH ($_SSH_PORT) открыт."

  systemctl daemon-reload 2>/dev/null || true

  echo ""
  echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}║              УДАЛЕНИЕ ЗАВЕРШЕНО                               ║${NC}"
  echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo "  mita, веб-панель, WARP и связанные данные удалены."
  echo "  fail2ban, certbot, docker и системные пакеты оставлены —"
  echo "  они могут использоваться другими сервисами на этом VPS."
  echo ""
  echo -e "  ${YELLOW}Эта утилита (mita-ctl) удалит себя после выхода.${NC}"
  echo ""
  read -r -p "Нажмите Enter для выхода..." _

  # Удаляем сам себя последним действием
  rm -f /usr/local/bin/mita-ctl
  exit 0
}

# ── Точка входа ───────────────────────────────────────────────────────────
main_menu

