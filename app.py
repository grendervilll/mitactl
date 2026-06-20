#!/usr/bin/env python3
"""
mita Web Panel — Flask backend
"""
import os, json, re, subprocess, secrets, string, random, ipaddress, socket, time, logging
from datetime import datetime, timedelta
from functools import wraps
from pathlib import Path

logging.basicConfig(level=logging.INFO,
                    format="%(asctime)s %(levelname)s [%(name)s] %(message)s")

from flask import (Flask, render_template, request, jsonify,
                   session, redirect, url_for, abort)
from collections import defaultdict
from threading import Lock

# ── конфиг ──────────────────────────────────────────────────────────────────
MITA_CONFIG   = os.environ.get("MITA_CONFIG",  "/etc/mita/server_config.json")
PANEL_CONFIG  = os.environ.get("PANEL_CONFIG", "/etc/mita/panel.json")
SECRET_PATH   = os.environ.get("SECRET_PATH",  "")   # задаётся при установке
WARP_PORT     = int(os.environ.get("WARP_PORT", "40000"))
SSL_CERT      = os.environ.get("SSL_CERT", "")
SSL_KEY       = os.environ.get("SSL_KEY",  "")

app = Flask(__name__)
app.secret_key = os.environ.get("FLASK_SECRET", secrets.token_hex(32))
app.config["SESSION_COOKIE_SAMESITE"] = "Lax"
# SESSION_COOKIE_SECURE не задаём статически — это ломает логин, если
# SSL_CERT прописан в env, но gunicorn по факту поднялся на HTTP
# (например, сертификат ещё не физически на диске, или используется
# SSH-туннель без TLS). Вместо этого выставляем Secure динамически
# по факту запроса — см. _set_cookie_secure_dynamically ниже.
app.config["PERMANENT_SESSION_LIFETIME"] = timedelta(hours=8)

# ── Rate limiter ─────────────────────────────────────────────────────────────
class RateLimiter:
    def __init__(self, max_attempts=5, window_seconds=3600):
        self.max_attempts  = max_attempts
        self.window        = window_seconds
        self._attempts     = defaultdict(list)  # ip → [timestamps]
        self._lock         = Lock()

    def _cleanup(self, ip):
        now = datetime.now().timestamp()
        self._attempts[ip] = [t for t in self._attempts[ip] if now - t < self.window]

    def check(self, ip):
        """Returns (allowed: bool, remaining: int, reset_in: int)."""
        with self._lock:
            self._cleanup(ip)
            attempts = len(self._attempts[ip])
            remaining = max(0, self.max_attempts - attempts)
            return remaining > 0, remaining, self.window

    def record_failure(self, ip):
        with self._lock:
            self._attempts[ip].append(datetime.now().timestamp())
            self._cleanup(ip)

    def reset(self, ip):
        with self._lock:
            self._attempts.pop(ip, None)

    def update_limits(self, max_attempts, window_seconds):
        with self._lock:
            self.max_attempts = max_attempts
            self.window       = window_seconds

_login_limiter = RateLimiter(max_attempts=5, window_seconds=3600)

# ── helpers ──────────────────────────────────────────────────────────────────
def load_panel_config():
    try:
        return json.loads(Path(PANEL_CONFIG).read_text())
    except Exception:
        return {}

def load_mita_config():
    try:
        return json.loads(Path(MITA_CONFIG).read_text())
    except Exception:
        return {}

def save_mita_config(cfg):
    Path(MITA_CONFIG).write_text(json.dumps(cfg, indent=2, ensure_ascii=False))
    _apply_mita_config_safe()

_log = logging.getLogger("mita_panel")

def _apply_mita_config_safe():
    """Apply mita config and restart the service.
    Mirrors the shell _apply_mita_config logic: starts mita temporarily if stopped,
    so mita apply config (which requires a running daemon) always succeeds."""

    bg_proc = None
    mita_was_stopped = False

    if not _mita_running():
        pb = Path("/etc/mita/server.conf.pb")
        try:
            pb.unlink(missing_ok=True)
        except Exception:
            pass
        subprocess.run(["systemctl", "reset-failed", "mita"], capture_output=True)
        bg_proc = subprocess.Popen(
            ["/usr/bin/mita", "run"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
        )
        # Installer uses sleep 3 — give mita enough time to open its RPC socket
        time.sleep(3)
        mita_was_stopped = True

    r = subprocess.run(["mita", "apply", "config", MITA_CONFIG],
                       capture_output=True, text=True)
    if r.returncode != 0:
        _log.error("mita apply config failed (rc=%d): %s %s",
                  r.returncode, r.stdout.strip(), r.stderr.strip())

    if mita_was_stopped and bg_proc is not None:
        bg_proc.terminate()
        try:
            bg_proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            bg_proc.kill()
        time.sleep(1)

    # Fix ownership so the mita systemd service (runs as mita user) can read the .pb
    pb = Path("/etc/mita/server.conf.pb")
    if pb.exists():
        subprocess.run(["chown", "mita:mita", str(pb)], capture_output=True)

    subprocess.run(["systemctl", "reset-failed", "mita"], capture_output=True)
    rs = subprocess.run(["systemctl", "restart", "mita"], capture_output=True, text=True)
    if rs.returncode != 0:
        _log.error("systemctl restart mita failed (rc=%d): %s %s",
                  rs.returncode, rs.stdout.strip(), rs.stderr.strip())

def mita_cmd(*args):
    r = subprocess.run(["mita", *args], capture_output=True, text=True)
    return r.stdout.strip()

def gen_password(length=64):
    # Буквы и цифры только — спецсимволы могут ломать mita protobuf парсинг
    # Используем расширенный безопасный набор без проблемных символов
    chars = string.ascii_letters + string.digits + "!@#%^*_-=+?."
    return "".join(secrets.choice(chars) for _ in range(length))

def gen_username():
    adjectives = ["swift","brave","quiet","cool","sharp","calm","bright","dark","wild","free"]
    nouns      = ["fox","hawk","river","storm","ember","peak","orbit","tide","frost","spark"]
    return f"{secrets.choice(adjectives)}_{secrets.choice(nouns)}_{secrets.randbelow(9000)+1000}"

def get_server_ip():
    try:
        return subprocess.run(
            ["curl","-s","--max-time","5","ifconfig.me"],
            capture_output=True, text=True).stdout.strip() or "?"
    except Exception:
        return "?"

def get_warp_ip():
    try:
        r = subprocess.run(
            ["curl","-s","--max-time","8","--proxy",
             f"socks5h://127.0.0.1:{WARP_PORT}",
             "https://ifconfig.me"],
            capture_output=True, text=True)
        ip = r.stdout.strip()
        # базовая валидация
        ipaddress.ip_address(ip)
        return ip
    except Exception:
        return "недоступен"

def get_traffic_stats():
    """Возвращает трафик и статус активности по всем пользователям."""
    raw = mita_cmd("get", "users")
    week_total = month_total = 0.0
    users_stats = []
    today = datetime.now().date()

    # mita get users output format (v3.x):
    # USER           LAST ACTIVE  1 DAY DOWN  1 DAY UP  30 DAYS DOWN  30 DAYS UP
    # username       2024-01-01   1.2MiB      0.5MiB    12.3GiB       4.5GiB
    lines = raw.splitlines()
    data_lines = []
    for line in lines:
        line = line.strip()
        if not line or line.upper().startswith("USER"):
            continue
        data_lines.append(line)

    for line in data_lines:
        parts = re.split(r"\s{2,}", line.strip())
        if len(parts) < 3:
            parts = line.split()
        if len(parts) < 3:
            continue
        try:
            name = parts[0]

            # Parse LAST ACTIVE field (parts[1])
            last_active_raw = parts[1].strip() if len(parts) > 1 else ""
            online = False
            last_active_display = "никогда"
            if last_active_raw and last_active_raw.lower() not in ("never", "-", "n/a", "никогда"):
                try:
                    la_date = datetime.strptime(last_active_raw[:10], "%Y-%m-%d").date()
                    delta = (today - la_date).days
                    if delta == 0:
                        online = True
                        last_active_display = "сегодня"
                    elif delta == 1:
                        last_active_display = "вчера"
                    elif delta < 7:
                        last_active_display = f"{delta} дн. назад"
                    elif delta < 30:
                        last_active_display = f"{delta // 7} нед. назад"
                    else:
                        last_active_display = f"{delta} дн. назад"
                except Exception:
                    last_active_display = last_active_raw

            # Find traffic columns — contain units like MiB, GiB, KiB, B
            traffic_parts = [p for p in parts[1:] if any(u in p for u in ["TiB","GiB","MiB","KiB","iB","B"])]
            d1_down = d1_up = d30_down = d30_up = 0.0
            if len(traffic_parts) >= 4:
                d1_down  = _parse_traffic(traffic_parts[0])
                d1_up    = _parse_traffic(traffic_parts[1])
                d30_down = _parse_traffic(traffic_parts[2])
                d30_up   = _parse_traffic(traffic_parts[3])
            elif len(traffic_parts) >= 2:
                d30_down = _parse_traffic(traffic_parts[0])
                d30_up   = _parse_traffic(traffic_parts[1])
            else:
                continue

            d7_bytes = (d30_down + d30_up) / 30 * 7
            month_total += d30_down + d30_up
            week_total  += d7_bytes
            users_stats.append({
                "name":         name,
                "online":       online,
                "last_active":  last_active_display,
                "day_mb":       round((d1_down + d1_up) / 1024 / 1024, 2),
                "week_mb":      round(d7_bytes / 1024 / 1024, 2),
                "month_mb":     round((d30_down + d30_up) / 1024 / 1024, 2),
            })
        except Exception:
            continue

    return {
        "week_gb":  round(week_total  / 1024**3, 2),
        "month_gb": round(month_total / 1024**3, 2),
        "users":    users_stats,
    }

def _parse_traffic(s: str) -> float:
    """Parse traffic string like '12.5GiB' or '1.2MiB' → bytes (float)."""
    s = s.strip()
    mul = {"TiB":1024**4,"GiB":1024**3,"MiB":1024**2,"KiB":1024,"B":1}
    for suffix, factor in mul.items():
        if s.endswith(suffix):
            try:
                return float(s[:-len(suffix)]) * factor
            except ValueError:
                return 0.0
    try:
        return float(s)
    except ValueError:
        return 0.0

def get_port_info():
    cfg = load_mita_config()
    bindings = cfg.get("portBindings", [])
    if not bindings:
        return "?"
    b = bindings[0]
    return b.get("portRange", str(b.get("port", "?")))

def build_client_config(name, password):
    cfg   = load_mita_config()
    bindings = cfg.get("portBindings", [])
    proto = bindings[0].get("protocol","TCP") if bindings else "TCP"
    port_range = bindings[0].get("portRange", str(bindings[0].get("port","?"))) if bindings else "?"
    server_ip = get_server_ip()
    return {
        "profiles": [{
            "profileName": "default",
            "user": {"name": name, "password": password},
            "servers": [{
                "ipAddress": server_ip,
                "portBindings": [{"portRange": port_range, "protocol": proto}]
            }]
        }],
        "activeProfile": "default",
        "rpcPort": 8964,
        "socks5Port": 1080,
    }

def build_singbox_config(name, password):
    """Генерирует sing-box совместимый конфиг для Karing, Hiddify, NekoBox и др."""
    cfg      = load_mita_config()
    bindings = cfg.get("portBindings", [])
    proto    = bindings[0].get("protocol", "TCP").upper() if bindings else "TCP"
    port_range = bindings[0].get("portRange",
                 str(bindings[0].get("port", "2100"))) if bindings else "2100"
    # Берём первый порт из диапазона для sing-box (он не поддерживает диапазоны)
    first_port = int(port_range.split("-")[0]) if "-" in port_range else int(port_range)
    server_ip  = get_server_ip()

    return {
        "log": {"level": "info", "timestamp": True},
        "dns": {
            "servers": [
                {"tag": "remote", "address": "tls://8.8.8.8", "detour": "proxy"},
                {"tag": "local",  "address": "223.5.5.5",     "detour": "direct"}
            ],
            "rules": [{"outbound": "any", "server": "local"}],
            "final": "remote"
        },
        "inbounds": [
            {
                "type": "tun",
                "tag":  "tun-in",
                "inet4_address": "172.19.0.1/30",
                "auto_route": True,
                "strict_route": True,
                "sniff": True
            },
            {
                "type": "socks",
                "tag":  "socks-in",
                "listen": "127.0.0.1",
                "listen_port": 2080
            },
            {
                "type": "http",
                "tag":  "http-in",
                "listen": "127.0.0.1",
                "listen_port": 2081
            }
        ],
        "outbounds": [
            {
                "type":        "mieru",
                "tag":         "proxy",
                "server":      server_ip,
                "server_port": first_port,
                "transport":   proto,
                "username":    name,
                "password":    password
            },
            {"type": "direct", "tag": "direct"},
            {"type": "block",  "tag": "block"},
            {"type": "dns",    "tag": "dns-out"}
        ],
        "route": {
            "rules": [
                {"protocol": "dns", "outbound": "dns-out"},
                {"ip_is_private": True, "outbound": "direct"},
                {
                    "rule_set": ["geosite-cn", "geoip-cn"],
                    "outbound": "direct"
                }
            ],
            "rule_set": [
                {
                    "tag":    "geosite-cn",
                    "type":   "remote",
                    "format": "binary",
                    "url":    "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs",
                    "download_detour": "proxy"
                },
                {
                    "tag":    "geoip-cn",
                    "type":   "remote",
                    "format": "binary",
                    "url":    "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs",
                    "download_detour": "proxy"
                }
            ],
            "final": "proxy",
            "auto_detect_interface": True
        }
    }

# ── auth ─────────────────────────────────────────────────────────────────────
def login_required(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        if not session.get("logged_in"):
            return redirect(url_for("login_page"))
        return f(*args, **kwargs)
    return decorated

def secret_required(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        if SECRET_PATH and request.path.rstrip("/") not in (
            f"/{SECRET_PATH}", f"/{SECRET_PATH}/login"
        ) and not request.path.startswith(f"/{SECRET_PATH}/"):
            abort(404)
        return f(*args, **kwargs)
    return decorated

# ── routes ────────────────────────────────────────────────────────────────────
BASE = f"/{SECRET_PATH}" if SECRET_PATH else ""

@app.route(f"{BASE}/")
@app.route(f"{BASE}")
@login_required
def index():
    return render_template("index.html", base=BASE)

@app.route(f"{BASE}/login", methods=["GET","POST"])
def login_page():
    if request.method == "POST":
        ip = request.remote_addr or "unknown"
        allowed, remaining, _ = _login_limiter.check(ip)
        if not allowed:
            return jsonify({
                "ok": False,
                "error": "Слишком много попыток. Попробуйте позже.",
                "remaining": 0,
                "rate_limited": True,
            }), 429

        data = request.get_json(silent=True) or {}
        pc   = load_panel_config()
        if (data.get("username") == pc.get("admin_user") and
                data.get("password") == pc.get("admin_pass")):
            _login_limiter.reset(ip)
            session.permanent = True
            session["logged_in"] = True
            return jsonify({"ok": True, "remaining": _login_limiter.max_attempts})

        _login_limiter.record_failure(ip)
        _, remaining, _ = _login_limiter.check(ip)
        return jsonify({
            "ok": False,
            "error": "Неверный логин или пароль",
            "remaining": remaining,
        }), 401
    return render_template("login.html", base=BASE)

@app.route(f"{BASE}/logout")
def logout():
    session.clear()
    return redirect(url_for("login_page"))

# ── API: dashboard ────────────────────────────────────────────────────────────
@app.route(f"{BASE}/api/dashboard")
@login_required
def api_dashboard():
    try:
        stats = get_traffic_stats()
    except Exception:
        stats = {"week_gb": 0, "month_gb": 0, "users": []}
    try:
        warp_ip = get_warp_ip()
    except Exception:
        warp_ip = "недоступен"
    return jsonify({
        "server_ip":   get_server_ip(),
        "warp_ip":     warp_ip,
        "week_gb":     stats["week_gb"],
        "month_gb":    stats["month_gb"],
        "mita_port":   get_port_info(),
        "users_count": len(load_mita_config().get("users", [])),
        "mita_running": _mita_running(),
    })

def _mita_running():
    try:
        r = subprocess.run(["systemctl","is-active","mita"],
                           capture_output=True, text=True, timeout=3)
        return r.stdout.strip() == "active"
    except Exception:
        return False

# ── API: users stats (traffic + online status) ────────────────────────────────
@app.route(f"{BASE}/api/users/stats")
@login_required
def api_users_stats():
    try:
        stats = get_traffic_stats()
        return jsonify({"users": stats["users"]})
    except Exception as e:
        return jsonify({"users": [], "error": str(e)})

# ── API: users ────────────────────────────────────────────────────────────────
@app.route(f"{BASE}/api/users", methods=["GET"])
@login_required
def api_users_get():
    cfg = load_mita_config()
    users = cfg.get("users", [])
    # egress rules для определения warp-пользователей
    egress = cfg.get("egress", {})
    return jsonify({"users": [{"name": u["name"]} for u in users], "egress": egress})

@app.route(f"{BASE}/api/users/create", methods=["POST"])
@login_required
def api_users_create():
    data  = request.get_json(silent=True) or {}
    count = int(data.get("count", 1))
    mode  = data.get("mode", "manual")   # manual | auto
    names = data.get("names", [])        # для manual

    cfg   = load_mita_config()
    existing = {u["name"] for u in cfg.get("users", [])}
    created  = []

    for i in range(count):
        if mode == "manual" and i < len(names):
            name = names[i].strip()
            if not name:
                continue
        else:
            name = gen_username()
            while name in existing:
                name = gen_username()

        if name in existing:
            continue

        password = gen_password()
        cfg.setdefault("users", []).append({"name": name, "password": password})
        existing.add(name)
        created.append({
            "name": name,
            "password": password,
            "client_config": build_client_config(name, password),
        })

    save_mita_config(cfg)
    return jsonify({"created": created})

@app.route(f"{BASE}/api/users/delete", methods=["POST"])
@login_required
def api_users_delete():
    data = request.get_json(silent=True) or {}
    name = data.get("name", "")
    cfg  = load_mita_config()
    cfg["users"] = [u for u in cfg.get("users", []) if u["name"] != name]
    save_mita_config(cfg)
    return jsonify({"ok": True})

@app.route(f"{BASE}/api/users/warp", methods=["POST"])
@login_required
def api_users_warp():
    """Включить/выключить WARP для конкретного пользователя через egress.users."""
    data    = request.get_json(silent=True) or {}
    name    = data.get("name", "")
    enabled = bool(data.get("enabled", False))
    cfg     = load_mita_config()

    # egress.userGroups не поддерживается в mita — используем workaround:
    # храним список warp-пользователей в panel.json,
    # добавляем их домены в egress (все остальные — DIRECT).
    pc = load_panel_config()
    warp_users = set(pc.get("warp_users", []))
    if enabled:
        warp_users.add(name)
    else:
        warp_users.discard(name)
    pc["warp_users"] = list(warp_users)
    Path(PANEL_CONFIG).write_text(json.dumps(pc, indent=2))

    # Примечание: mita не поддерживает per-user egress нативно.
    # Флаг хранится в panel.json и отображается в UI как справочная информация.
    # Реальное разделение — через отдельные порты (см. README).
    return jsonify({"ok": True, "note": "stored_in_panel_config"})

@app.route(f"{BASE}/api/users/warp_status")
@login_required
def api_users_warp_status():
    pc = load_panel_config()
    return jsonify({"warp_users": pc.get("warp_users", [])})

# ── API: SSL ──────────────────────────────────────────────────────────────────
@app.route(f"{BASE}/api/ssl/status")
@login_required
def api_ssl_status():
    pc = load_panel_config()
    return jsonify({
        "type":    pc.get("ssl_type", "none"),
        "domain":  pc.get("ssl_domain", ""),
        "cert":    pc.get("ssl_cert", ""),
        "expires": pc.get("ssl_expires", ""),
    })

@app.route(f"{BASE}/api/ssl/selfsigned", methods=["POST"])
@login_required
def api_ssl_selfsigned():
    cert_dir = "/etc/mita/ssl"
    os.makedirs(cert_dir, exist_ok=True)
    cert = f"{cert_dir}/selfsigned.crt"
    key  = f"{cert_dir}/selfsigned.key"
    r = subprocess.run([
        "openssl","req","-x509","-newkey","rsa:4096","-sha256",
        "-days","3650","-nodes",
        "-keyout", key, "-out", cert,
        "-subj", "/CN=mita-panel/O=mita/C=XX"
    ], capture_output=True, text=True)
    if r.returncode != 0:
        return jsonify({"ok": False, "error": r.stderr}), 500

    # Прописать в env-файл панели
    _update_env("SSL_CERT", cert)
    _update_env("SSL_KEY",  key)

    # Получить дату истечения
    exp = subprocess.run(
        ["openssl","x509","-noout","-enddate","-in",cert],
        capture_output=True, text=True).stdout.strip()

    pc = load_panel_config()
    pc.update({"ssl_type":"selfsigned","ssl_cert":cert,"ssl_key":key,"ssl_expires":exp})
    Path(PANEL_CONFIG).write_text(json.dumps(pc,indent=2))

    return jsonify({"ok": True, "expires": exp,
                    "note": "Перезапустите панель: systemctl restart mita-panel"})

@app.route(f"{BASE}/api/ssl/letsencrypt", methods=["POST"])
@login_required
def api_ssl_letsencrypt():
    data   = request.get_json(silent=True) or {}
    domain = data.get("domain","").strip()
    email  = data.get("email","").strip()
    if not domain:
        return jsonify({"ok": False, "error": "Укажите домен"}), 400

    # Установить certbot если нет
    if subprocess.run(["which","certbot"], capture_output=True).returncode != 0:
        subprocess.run(["apt-get","install","-y","-qq","certbot"], capture_output=True)

    panel_port = int(os.environ.get("PANEL_PORT", "8080"))
    cmd = ["certbot","certonly","--standalone","--non-interactive",
           "--agree-tos","--http-01-port","80",
           "-d", domain]
    if email:
        cmd += ["--email", email]
    else:
        cmd += ["--register-unsafely-without-email"]

    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        return jsonify({"ok": False, "error": r.stdout + r.stderr}), 500

    cert = f"/etc/letsencrypt/live/{domain}/fullchain.pem"
    key  = f"/etc/letsencrypt/live/{domain}/privkey.pem"
    _update_env("SSL_CERT", cert)
    _update_env("SSL_KEY",  key)

    exp = subprocess.run(
        ["openssl","x509","-noout","-enddate","-in",cert],
        capture_output=True, text=True).stdout.strip()

    pc = load_panel_config()
    pc.update({"ssl_type":"letsencrypt","ssl_domain":domain,
               "ssl_cert":cert,"ssl_key":key,"ssl_expires":exp})
    Path(PANEL_CONFIG).write_text(json.dumps(pc,indent=2))

    return jsonify({"ok": True, "expires": exp,
                    "note": "Перезапустите панель: systemctl restart mita-panel"})

def _update_env(key, value):
    env_file = "/etc/mita/panel.env"
    lines = []
    found = False
    if os.path.exists(env_file):
        for line in Path(env_file).read_text().splitlines():
            if line.startswith(f"{key}="):
                lines.append(f"{key}={value}")
                found = True
            else:
                lines.append(line)
    if not found:
        lines.append(f"{key}={value}")
    Path(env_file).write_text("\n".join(lines) + "\n")

# ── 404 для всего вне секретного пути ────────────────────────────────────────
@app.before_request
def check_secret_path():
    if not SECRET_PATH:
        return
    path = request.path.rstrip("/") or "/"
    allowed_prefix = f"/{SECRET_PATH}"
    if not (path == allowed_prefix or path.startswith(allowed_prefix + "/")):
        abort(404)

# ── Динамическая правка Secure-флага на cookie сессии ────────────────────────
# Если выставить Secure статически по наличию SSL_CERT в env, можно словить
# ситуацию когда сертификат прописан, но запрос реально пришёл по HTTP
# (gunicorn не поднял TLS, SSH-туннель без TLS и т.п.) — тогда браузер
# тихо отбросит cookie с флагом Secure, и человек не сможет войти, видя
# при этом "успешный" логин без какой-либо ошибки. Поэтому проверяем
# request.is_secure на каждый ответ и правим флаг по факту.
@app.after_request
def fix_session_cookie_secure(response):
    if not request.is_secure:
        return response
    set_cookie_headers = response.headers.getlist("Set-Cookie")
    if not set_cookie_headers:
        return response
    response.headers.remove("Set-Cookie")
    for header in set_cookie_headers:
        if app.session_cookie_name in header and "Secure" not in header:
            header += "; Secure"
        response.headers.add("Set-Cookie", header)
    return response

if __name__ == "__main__":
    port    = int(os.environ.get("PANEL_PORT", "8080"))
    ssl_ctx = None
    if SSL_CERT and SSL_KEY and os.path.exists(SSL_CERT) and os.path.exists(SSL_KEY):
        import ssl as _ssl
        ssl_ctx = (SSL_CERT, SSL_KEY)
    app.run(host="0.0.0.0", port=port, ssl_context=ssl_ctx)

# ── API: получить конфиг конкретного пользователя (пароль из server_config.json) ──
@app.route(f"{BASE}/api/users/config")
@login_required
def api_user_config():
    name = request.args.get("name", "")
    if not name:
        return jsonify({"ok": False, "error": "Не указано имя"}), 400
    cfg = load_mita_config()
    user = next((u for u in cfg.get("users", []) if u["name"] == name), None)
    if not user:
        return jsonify({"ok": False, "error": "Пользователь не найден"}), 404
    return jsonify({
        "ok":           True,
        "name":         user["name"],
        "password":     user["password"],
        "client_config":  build_client_config(user["name"], user["password"]),
        "singbox_config": build_singbox_config(user["name"], user["password"]),
    })

# ── API: WARP-правила конкретного пользователя ───────────────────────────────
@app.route(f"{BASE}/api/users/warp_rules")
@login_required
def api_warp_rules_get():
    name = request.args.get("name", "")
    if not name:
        return jsonify({"ok": False, "error": "Не указано имя"}), 400
    pc = load_panel_config()
    rules = pc.get("warp_rules", {}).get(name, {
        "domains": [],
        "ips": [],
        "sources": [],   # URL или geosite:/geoip: ссылки
    })
    return jsonify({"ok": True, "name": name, "rules": rules})

@app.route(f"{BASE}/api/users/warp_rules", methods=["POST"])
@login_required
def api_warp_rules_set():
    data = request.get_json(silent=True) or {}
    name    = data.get("name", "")
    domains = data.get("domains", [])   # список строк
    ips     = data.get("ips", [])
    sources = data.get("sources", [])   # geosite:xxx / geoip:xxx / URL

    if not name:
        return jsonify({"ok": False, "error": "Не указано имя"}), 400

    pc = load_panel_config()
    pc.setdefault("warp_rules", {})[name] = {
        "domains": [d.strip() for d in domains if d.strip()],
        "ips":     [i.strip() for i in ips     if i.strip()],
        "sources": [s.strip() for s in sources if s.strip()],
    }
    Path(PANEL_CONFIG).write_text(json.dumps(pc, indent=2))

    # Перегенерировать egress в mita config на основе всех пользователей
    _rebuild_egress(pc)

    return jsonify({"ok": True})

def _get_geosite_data():
    """
    Скачивает (с кэшированием на 7 дней) единый YAML файл со всеми
    geosite-категориями и возвращает распарсенный dict.
    Старый способ (отдельный .txt на каждую категорию на ветке release)
    больше не поддерживается проектом v2fly — теперь только единый
    dlc.dat_plain.yml в latest release.
    """
    import urllib.request, os, time, yaml

    cache_path = "/var/cache/mita-geosite.yml"
    url = "https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat_plain.yml"

    need_download = True
    if os.path.exists(cache_path):
        age_days = (time.time() - os.path.getmtime(cache_path)) / 86400
        if age_days < 7:
            need_download = False

    if need_download:
        try:
            os.makedirs(os.path.dirname(cache_path), exist_ok=True)
            req = urllib.request.Request(url, headers={"User-Agent": "mita-panel"})
            with urllib.request.urlopen(req, timeout=60) as resp:
                data = resp.read()
            with open(cache_path, "wb") as f:
                f.write(data)
        except Exception:
            pass  # используем старый кэш, если есть

    if not os.path.exists(cache_path):
        return None

    try:
        with open(cache_path) as f:
            return yaml.safe_load(f)
    except Exception:
        return None

def _geosite_category_domains(category):
    """Возвращает список доменов для одной geosite-категории."""
    data = _get_geosite_data()
    if not data:
        return []
    domains = []
    cat_lower = category.lower()
    for entry in data.get("lists", []):
        if entry.get("name", "").lower() == cat_lower:
            for rule in entry.get("rules", []):
                for prefix in ("domain:", "full:"):
                    if rule.startswith(prefix):
                        domains.append(rule[len(prefix):])
                        break
                # regexp: и include: пропускаем — не прямые доменные правила
            break
    return domains

def _rebuild_egress(pc):
    """
    Собирает egress.rules из warp_rules всех пользователей и записывает в mita config.
    mita не поддерживает per-user egress — правила глобальные, но мы объединяем
    домены/IP всех пользователей у которых WARP включён.
    Источники (geosite:/geoip:/URL) разворачиваем в реальные списки.
    """
    import urllib.request

    warp_users = set(pc.get("warp_users", []))
    all_domains = set()
    all_ips     = set()

    GEOIP_BASE = "https://raw.githubusercontent.com/herrbischoff/country-ip-blocks/master/ipv4"

    for uname, rules in pc.get("warp_rules", {}).items():
        if uname not in warp_users:
            continue   # пользователь не включён в WARP — пропускаем

        all_domains.update(rules.get("domains", []))
        all_ips.update(rules.get("ips", []))

        for src in rules.get("sources", []):
            src = src.strip()
            try:
                if src.startswith("geosite:"):
                    cat = src[len("geosite:"):]
                    all_domains.update(_geosite_category_domains(cat))
                elif src.startswith("geoip:"):
                    country = src[len("geoip:"):]
                    url = f"{GEOIP_BASE}/{country}.cidr"
                    lines = urllib.request.urlopen(url, timeout=10).read().decode().splitlines()
                    for line in lines:
                        line = line.strip()
                        if line and not line.startswith("#"):
                            all_ips.add(line)
                elif src.startswith("http"):
                    lines = urllib.request.urlopen(src, timeout=10).read().decode().splitlines()
                    for line in lines:
                        line = line.strip()
                        if line and not line.startswith("#"):
                            # Определяем домен или IP по наличию /
                            if "/" in line or line.replace(".","").isdigit():
                                all_ips.add(line)
                            else:
                                all_domains.add(line)
            except Exception:
                pass   # не критично — продолжаем без этого источника

    cfg = load_mita_config()

    if not all_domains and not all_ips:
        # Нет правил — убираем egress полностью
        cfg.pop("egress", None)
    else:
        domain_list = sorted(all_domains)
        ip_list     = sorted(all_ips)
        warp_rule   = {"action": "PROXY", "proxyNames": ["warp"]}
        if domain_list:
            warp_rule["domainNames"] = domain_list
        if ip_list:
            warp_rule["ipRanges"] = ip_list

        cfg["egress"] = {
            "proxies": [{
                "name": "warp",
                "protocol": "SOCKS5_PROXY_PROTOCOL",
                "host": "127.0.0.1",
                "port": WARP_PORT,
            }],
            "rules": [
                warp_rule,
                {"ipRanges": ["*"], "domainNames": ["*"], "action": "DIRECT"},
            ],
        }

    save_mita_config(cfg)

# ── API: fail2ban config ──────────────────────────────────────────────────────
@app.route(f"{BASE}/api/fail2ban/status")
@login_required
def api_fail2ban_status():
    installed = subprocess.run(["which","fail2ban-client"],
                               capture_output=True).returncode == 0
    active = False
    jail_active = False
    max_retry = _login_limiter.max_attempts
    ban_time  = _login_limiter.window

    if installed:
        r = subprocess.run(["systemctl","is-active","fail2ban"],
                           capture_output=True, text=True)
        active = r.stdout.strip() == "active"
        if active:
            r2 = subprocess.run(
                ["fail2ban-client","status","mita-panel"],
                capture_output=True, text=True)
            jail_active = r2.returncode == 0

    # Read current limits from panel config
    pc = load_panel_config()
    max_retry = pc.get("login_max_attempts", 5)
    ban_time  = pc.get("login_ban_seconds",  3600)

    return jsonify({
        "installed":   installed,
        "active":      active,
        "jail_active": jail_active,
        "max_retry":   max_retry,
        "ban_time":    ban_time,
    })

@app.route(f"{BASE}/api/fail2ban/configure", methods=["POST"])
@login_required
def api_fail2ban_configure():
    data       = request.get_json(silent=True) or {}
    max_retry  = int(data.get("max_retry",  5))
    ban_time   = int(data.get("ban_time",   3600))
    install_f2b = data.get("install", False)

    if max_retry < 1 or max_retry > 100:
        return jsonify({"ok": False, "error": "max_retry должен быть от 1 до 100"}), 400
    if ban_time < 60:
        return jsonify({"ok": False, "error": "ban_time минимум 60 секунд"}), 400

    # Update in-memory limiter
    _login_limiter.update_limits(max_retry, ban_time)

    # Save to panel config
    pc = load_panel_config()
    pc["login_max_attempts"] = max_retry
    pc["login_ban_seconds"]  = ban_time
    Path(PANEL_CONFIG).write_text(json.dumps(pc, indent=2))

    # Install fail2ban if requested
    if install_f2b:
        r = subprocess.run(["apt-get","install","-y","-qq","fail2ban"],
                           capture_output=True, text=True)
        if r.returncode != 0:
            return jsonify({"ok": False, "error": "Ошибка установки fail2ban: " + r.stderr}), 500

    # Write fail2ban filter for mita-panel
    filter_content = """[Definition]
failregex = ^<HOST> .+ "POST /[^"]+/login[^"]*" 4(?:01|29).*$
ignoreregex =
"""
    jail_content = f"""[mita-panel]
enabled  = true
filter   = mita-panel
backend  = auto
logpath  = /var/log/mita-panel-access.log
maxretry = {max_retry}
bantime  = {ban_time}
findtime = {ban_time}
"""
    try:
        Path("/etc/fail2ban/filter.d/mita-panel.conf").write_text(filter_content)
        Path("/etc/fail2ban/jail.d/mita-panel.conf").write_text(jail_content)
        subprocess.run(["systemctl","enable","fail2ban","--now"], capture_output=True)
        r_reload = subprocess.run(["systemctl","restart","fail2ban"], capture_output=True)
        r_active = subprocess.run(["systemctl","is-active","fail2ban"], capture_output=True, text=True)
        if r_active.stdout.strip() == "active":
            ok_msg = "Настройки сохранены и применены"
        else:
            ok_msg = "Настройки сохранены, но fail2ban не запустился — проверьте journalctl -u fail2ban"
    except Exception as e:
        ok_msg = f"Настройки сохранены (fail2ban: {e})"

    return jsonify({"ok": True, "message": ok_msg})

# ── API: скачать конфиг как файл ─────────────────────────────────────────────
@app.route(f"{BASE}/api/users/config/download")
@login_required
def api_user_config_download():
    from flask import Response
    name    = request.args.get("name", "")
    fmt     = request.args.get("format", "mieru")   # mieru | singbox
    if not name:
        abort(400)
    cfg  = load_mita_config()
    user = next((u for u in cfg.get("users", []) if u["name"] == name), None)
    if not user:
        abort(404)

    if fmt == "singbox":
        data     = json.dumps(build_singbox_config(user["name"], user["password"]),
                              indent=2, ensure_ascii=False)
        filename = f"{name}_singbox.json"
    else:
        data     = json.dumps(build_client_config(user["name"], user["password"]),
                              indent=2, ensure_ascii=False)
        filename = f"{name}_mieru.json"

    return Response(
        data,
        mimetype="application/json",
        headers={"Content-Disposition": f'attachment; filename="{filename}"'}
    )


@app.route(f"{BASE}/api/mita/apply", methods=["POST"])
@login_required
def api_mita_apply():
    """Диагностика: вручную применить конфиг mita и вернуть подробный результат."""
    mita_running = _mita_running()
    pb = Path("/etc/mita/server.conf.pb")
    pb_exists_before = pb.exists()

    r = subprocess.run(["mita", "apply", "config", MITA_CONFIG],
                       capture_output=True, text=True)
    pb_exists_after = pb.exists()

    # Chown после apply — нужно если .pb создавался root'ом
    chown_result = None
    if pb_exists_after:
        cr = subprocess.run(["chown", "mita:mita", str(pb)], capture_output=True, text=True)
        chown_result = {"rc": cr.returncode, "err": cr.stderr.strip()}

    rs = subprocess.run(["systemctl", "restart", "mita"], capture_output=True, text=True)

    cfg = load_mita_config()
    return jsonify({
        "mita_was_running":    mita_running,
        "apply_rc":            r.returncode,
        "apply_stdout":        r.stdout.strip(),
        "apply_stderr":        r.stderr.strip(),
        "pb_existed_before":   pb_exists_before,
        "pb_exists_after":     pb_exists_after,
        "chown":               chown_result,
        "restart_rc":          rs.returncode,
        "restart_stderr":      rs.stderr.strip(),
        "users_in_json":       [u["name"] for u in cfg.get("users", [])],
    })

