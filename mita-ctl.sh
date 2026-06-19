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
  echo -e "  ${BOLD}${GREEN}http://127.0.0.1:${port}/${secret}/${NC}"
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
    echo -e "  ${BOLD}3.${NC}  Перевыпустить SSL-сертификат панели"
    echo -e "  ${BOLD}4.${NC}  Управление пользователями mita"
    echo -e "  ${BOLD}5.${NC}  Показать логин и пароль админа панели"
    echo -e "  ${BOLD}6.${NC}  Изменить данные администратора панели"
    echo -e "  ${BOLD}7.${NC}  Настройка fail2ban"
    echo -e "  ${BOLD}8.${NC}  Рекомендации по безопасности VPS"
    echo -e "  ${RED}${BOLD}9.${NC}  ${RED}Полное удаление mita, панели и WARP${NC}"
    echo -e "  ${BOLD}10.${NC} Показать текущую конфигурацию"
    echo -e "  ${BOLD}0.${NC}  Выход"
    echo ""
    read -r -p "  Выберите пункт: " choice
    case "$choice" in
      1) menu_panel_access ;;
      2) menu_firewall ;;
      3) menu_ssl ;;
      4) menu_users ;;
      5) menu_show_admin ;;
      6) menu_change_admin ;;
      7) menu_fail2ban ;;
      8) menu_security ;;
      9) menu_uninstall ;;
      10) menu_show_config ;;
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
      echo -e "  Адрес: ${BOLD}${GREEN}http://${server_ip}:${panel_port}/${secret}/${NC}"
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
  command -v ufw &>/dev/null && ufw status | grep -q "Status: active" \
    && ufw allow "$port/$proto" 2>/dev/null || true
  iptables -I INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null || true
}

_fw_close() {
  local port="$1" proto="${2:-tcp}"
  command -v ufw &>/dev/null && ufw status | grep -q "Status: active" \
    && ufw delete allow "$port/$proto" 2>/dev/null || true
  iptables -D INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null || true
}

# ════════════════════════════════════════════════════════════════════════════
# 3. SSL
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
# 4. ПОЛЬЗОВАТЕЛИ
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

  case "$choice" in
    1)
      read -r -p "Имя пользователя: " uname
      [[ -z "$uname" ]] && { warn "Имя не указано"; pause; return; }
      _create_user "$uname"
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
        _create_user "$uname"
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
  local pass
  pass=$(openssl rand -base64 48 | tr -d '/+=' | head -c 48)

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
# 5. ПОКАЗАТЬ ДАННЫЕ АДМИНА
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

  pause
}

# ════════════════════════════════════════════════════════════════════════════
# 6. ИЗМЕНИТЬ ДАННЫЕ АДМИНА
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
# 7. БЕЗОПАСНОСТЬ VPS
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
# 8. FAIL2BAN
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
failregex = ^.*"POST /[^"]+/login[^"]*" 4(01|29).*$
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
action   = iptables-multiport[name=mita-panel, port="http,https,8080,8443", protocol=tcp]
EOF
    systemctl restart fail2ban 2>/dev/null || true
    ok "fail2ban настроен: $max_retry попыток / ${ban_time}с"
  else
    warn "fail2ban не установлен — лимиты сохранены только в panel.json"
  fi

  # Перезапустить панель чтобы подхватила новые лимиты
  systemctl restart mita-panel 2>/dev/null || true
  ok "Настройки применены. Попыток: $max_retry, бан: ${ban_time}с"
}

# ════════════════════════════════════════════════════════════════════════════
# 9. ПОЛНОЕ УДАЛЕНИЕ
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
  DEB_PKG=$(dpkg -l 2>/dev/null | grep -i "^ii.*mita" | awk '{print $2}' | head -1)
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
    domains=$(certbot certificates 2>/dev/null | grep "Domains:" | awk '{print $2}')
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

  # ── 8. Закрыть порты в firewall (best-effort) ──────────────────
  info "Откат правил firewall (порты mita/панели)..."
  if command -v ufw &>/dev/null; then
    ufw status numbered 2>/dev/null | grep -iE "mita|panel" | awk -F'[][]' '{print $2}' | sort -rn | while read -r num; do
      [[ -n "$num" ]] && yes | ufw delete "$num" 2>/dev/null || true
    done
  fi
  ok "Правила firewall обработаны (проверьте 'ufw status' вручную при необходимости)"

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

