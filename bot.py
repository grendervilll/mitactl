#!/usr/bin/env python3
"""
mita Telegram Bot — управление сервером через Telegram
"""
import os, json, re, subprocess, secrets, string, psutil, logging
from datetime import datetime
from pathlib import Path

logging.basicConfig(level=logging.INFO,
                    format="%(asctime)s %(levelname)s [bot] %(message)s")
_log = logging.getLogger("mita_bot")

BOT_CONFIG   = os.environ.get("BOT_CONFIG", "/etc/mita/bot.json")
MITA_CONFIG  = "/etc/mita/server_config.json"
PANEL_CONFIG = "/etc/mita/panel.json"

try:
    from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup
    from telegram.ext import Application, CommandHandler, CallbackQueryHandler, ContextTypes
except ImportError:
    _log.error("python-telegram-bot не установлен. pip install python-telegram-bot")
    raise SystemExit(1)

# ── config ────────────────────────────────────────────────────────────────────
def load_bot_config():
    try:
        return json.loads(Path(BOT_CONFIG).read_text())
    except Exception:
        return {}

def load_mita_config():
    try:
        return json.loads(Path(MITA_CONFIG).read_text())
    except Exception:
        return {}

def load_panel_config():
    try:
        return json.loads(Path(PANEL_CONFIG).read_text())
    except Exception:
        return {}

# ── helpers ───────────────────────────────────────────────────────────────────
def mita_cmd(*args):
    r = subprocess.run(["mita", *args], capture_output=True, text=True)
    return r.stdout.strip()

def _parse_traffic(s: str) -> float:
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

def fmt_bytes(b):
    if b >= 1024**4: return f"{b/1024**4:.2f} TiB"
    if b >= 1024**3: return f"{b/1024**3:.2f} GiB"
    if b >= 1024**2: return f"{b/1024**2:.1f} MiB"
    if b >= 1024:    return f"{b/1024:.0f} KiB"
    return f"{b:.0f} B"

def get_server_ip():
    try:
        return subprocess.run(
            ["curl","-s","--max-time","5","ifconfig.me"],
            capture_output=True, text=True).stdout.strip() or "?"
    except Exception:
        return "?"

def _mita_running():
    try:
        r = subprocess.run(["systemctl","is-active","mita"],
                           capture_output=True, text=True, timeout=3)
        return r.stdout.strip() == "active"
    except Exception:
        return False

def gen_password(length=64, mode="hard"):
    if mode == "easy":
        chars = string.ascii_letters + string.digits + "-._~*+"
    else:
        chars = string.ascii_letters + string.digits + "!@#%^*_-=+?."
    return "".join(secrets.choice(chars) for _ in range(length))

def gen_username():
    adj = ["swift","brave","quiet","cool","sharp","calm","bright","dark","wild","free"]
    nouns = ["fox","hawk","river","storm","ember","peak","orbit","tide","frost","spark"]
    return f"{secrets.choice(adj)}_{secrets.choice(nouns)}_{secrets.randbelow(9000)+1000}"

def escape_md(text):
    return str(text).replace("_","\\_").replace("*","\\*").replace("[","\\[").replace("]","\\]").replace("(","\\(").replace(")","\\)").replace("~","\\~").replace(">","\\>").replace("#","\\#").replace("+","\\+").replace("-","\\-").replace("=","\\=").replace("|","\\|").replace("{","\\{").replace("}","\\}").replace(".","\\.").replace("!","\\!")

# ── auth ──────────────────────────────────────────────────────────────────────
def admin_only(func):
    async def wrapper(update: Update, context: ContextTypes.DEFAULT_TYPE):
        user_id = str(update.effective_user.id)
        cfg = load_bot_config()
        admins = cfg.get("admin_ids", [])
        if user_id not in admins:
            if update.callback_query:
                await update.callback_query.answer("Доступ запрещён")
            elif update.message:
                await update.message.reply_text("⛔ Доступ запрещён.")
            return
        return await func(update, context)
    return wrapper

# ── keyboards ─────────────────────────────────────────────────────────────────
MAIN_KEYBOARD = InlineKeyboardMarkup([
    [InlineKeyboardButton("👥 Пользователи", callback_data="users"),
     InlineKeyboardButton("📊 Дашборд", callback_data="dashboard")],
    [InlineKeyboardButton("➕ Создать", callback_data="create"),
     InlineKeyboardButton("🗑 Удалить", callback_data="delete_menu")],
    [InlineKeyboardButton("🔄 WARP", callback_data="warp_menu"),
     InlineKeyboardButton("🛡 Безопасность", callback_data="security")],
    [InlineKeyboardButton("ℹ️ Помощь", callback_data="help")],
])

def back_button(data="main"):
    return InlineKeyboardMarkup([[InlineKeyboardButton("« Назад", callback_data=data)]])

# ── main menu ─────────────────────────────────────────────────────────────────
@admin_only
async def cmd_start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    await update.message.reply_text(
        "🤖 *mita Bot*\nВыберите действие:",
        reply_markup=MAIN_KEYBOARD,
        parse_mode="MarkdownV2"
    )

@admin_only
async def show_main(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()
    await query.edit_message_text(
        "🤖 *mita Bot*\nВыберите действие:",
        reply_markup=MAIN_KEYBOARD,
        parse_mode="MarkdownV2"
    )

# ── users ─────────────────────────────────────────────────────────────────────
@admin_only
async def show_users(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()
    try:
        cfg = load_mita_config()
        users = cfg.get("users", [])
        if not users:
            await query.edit_message_text("👤 Нет пользователей.", reply_markup=back_button())
            return

        raw = mita_cmd("get", "users")
        pc = load_panel_config()
        warp_users = set(pc.get("warp_users", []))
        today = datetime.now().date()

        stats_map = {}
        for line in raw.splitlines():
            line = line.strip()
            if not line or line.upper().startswith("USER"):
                continue
            parts = line.split()
            if len(parts) < 8:
                continue
            try:
                name = parts[0]
                d1_bytes = _parse_traffic(parts[2]) + _parse_traffic(parts[3])
                d7_bytes = _parse_traffic(parts[4]) + _parse_traffic(parts[5])
                d30_bytes = _parse_traffic(parts[6]) + _parse_traffic(parts[7])
                online = False
                la_raw = parts[1]
                if la_raw and la_raw.lower() not in ("never","-","n/a","никогда"):
                    try:
                        la_date = datetime.strptime(la_raw[:10], "%Y-%m-%d").date()
                        if (today - la_date).days == 0:
                            online = True
                    except Exception:
                        pass
                stats_map[name] = {"online": online,
                                   "day_mb": round(d1_bytes/1024/1024, 2),
                                   "week_mb": round(d7_bytes/1024/1024, 2),
                                   "month_mb": round(d30_bytes/1024/1024, 2)}
            except Exception:
                continue

        lines = ["👥 *Пользователи*\n"]
        user_buttons = []
        for u in users:
            name = u["name"]
            s = stats_map.get(name, {})
            w = "🟢" if name in warp_users else "⚪"
            o = "🟢" if s.get("online") else "🔴"
            day = f"`{s.get('day_mb', 0):.1f} МБ`" if s.get("day_mb") else "—"
            mon = f"`{s.get('month_mb', 0):.1f} МБ`" if s.get("month_mb") else "—"
            ename = escape_md(name)
            lines.append(f"{o} {ename} {w}  д:{day}  м:{mon}")
            user_buttons.append([InlineKeyboardButton(
                f"{'🟢 ' if s.get('online') else ''}{name}",
                callback_data=f"user_{name}"
            )])

        user_buttons.extend([
            [InlineKeyboardButton("➕ Создать", callback_data="create"),
             InlineKeyboardButton("🗑 Удалить", callback_data="delete_menu")],
            [InlineKeyboardButton("🔄 WARP", callback_data="warp_menu")],
            [InlineKeyboardButton("« Назад", callback_data="main")],
        ])

        text = "\n".join(lines)
        if len(text) > 4000:
            text = text[:3997] + "…"
        if len(user_buttons) > 96:
            user_buttons = user_buttons[:96]

        await query.edit_message_text(
            text,
            reply_markup=InlineKeyboardMarkup(user_buttons),
            parse_mode="MarkdownV2"
        )
    except Exception as e:
        _log.error("show_users failed: %s", e, exc_info=True)
        try:
            await query.edit_message_text(
                f"⚠ Ошибка загрузки пользователей:\n`{e}`",
                reply_markup=back_button(),
                parse_mode="MarkdownV2"
            )
        except Exception:
            pass
    except Exception as e:
        _log.error("show_users failed: %s", e)
        await query.edit_message_text(
            f"⚠ Ошибка: {e}",
            reply_markup=back_button()
        )

# ── create ────────────────────────────────────────────────────────────────────
@admin_only
async def create_user(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()
    await query.edit_message_text(
        "➕ *Создать пользователя*\n\nВыберите сложность пароля:",
        reply_markup=InlineKeyboardMarkup([
            [InlineKeyboardButton("🔓 Лёгкий (A-Z, 0-9, -._~*+)", callback_data="create_easy")],
            [InlineKeyboardButton("🔐 Сложный (со спецсимволами)", callback_data="create_hard")],
            [InlineKeyboardButton("« Назад", callback_data="main")],
        ]),
        parse_mode="MarkdownV2"
    )

@admin_only
async def create_exec(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()
    pwd_mode = "easy" if query.data == "create_easy" else "hard"
    cfg = load_mita_config()
    existing = {u["name"] for u in cfg.get("users", [])}
    name = gen_username()
    while name in existing:
        name = gen_username()

    password = gen_password(mode=pwd_mode)
    cfg.setdefault("users", []).append({"name": name, "password": password})
    Path(MITA_CONFIG).write_text(json.dumps(cfg, indent=2, ensure_ascii=False))

    subprocess.run(["mita", "apply", "config", MITA_CONFIG], capture_output=True)
    subprocess.run(["systemctl", "restart", "mita"], capture_output=True)

    ip = get_server_ip()
    bindings = cfg.get("portBindings", [{}])[0]
    port = bindings.get("portRange", str(bindings.get("port","?")))

    ename = escape_md(name)
    await query.edit_message_text(
        f"✅ Пользователь *{ename}* создан\n\n"
        f"Сервер: `{ip}`\nПорт: `{port}`\nПароль: `{password}`",
        reply_markup=InlineKeyboardMarkup([
            [InlineKeyboardButton("➕ Ещё одного", callback_data="create")],
            [InlineKeyboardButton("« Назад", callback_data="main")],
        ]),
        parse_mode="MarkdownV2"
    )

# ── delete menu ───────────────────────────────────────────────────────────────
@admin_only
async def delete_menu(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()
    cfg = load_mita_config()
    users = cfg.get("users", [])
    if not users:
        await query.edit_message_text("👤 Нет пользователей.", reply_markup=back_button())
        return

    buttons = []
    for u in users:
        buttons.append([InlineKeyboardButton(f"🗑 {u['name']}", callback_data=f"delete_{u['name']}")])
    buttons.append([InlineKeyboardButton("« Назад", callback_data="main")])

    await query.edit_message_text(
        "🗑 *Выберите пользователя для удаления:*",
        reply_markup=InlineKeyboardMarkup(buttons),
        parse_mode="MarkdownV2"
    )

@admin_only
async def delete_user(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()
    name = query.data[len("delete_"):]
    cfg = load_mita_config()
    cfg["users"] = [u for u in cfg.get("users", []) if u["name"] != name]
    Path(MITA_CONFIG).write_text(json.dumps(cfg, indent=2, ensure_ascii=False))
    subprocess.run(["mita", "apply", "config", MITA_CONFIG], capture_output=True)
    subprocess.run(["systemctl", "restart", "mita"], capture_output=True)

    await query.edit_message_text(
        f"🗑 Пользователь `{escape_md(name)}` удалён",
        reply_markup=InlineKeyboardMarkup([
            [InlineKeyboardButton("« Назад", callback_data="main")],
        ]),
        parse_mode="MarkdownV2"
    )

# ── warp menu ─────────────────────────────────────────────────────────────────
@admin_only
async def warp_menu(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()
    cfg = load_mita_config()
    pc = load_panel_config()
    warp_users = set(pc.get("warp_users", []))
    users = cfg.get("users", [])

    buttons = []
    for u in users:
        on = u["name"] in warp_users
        buttons.append([InlineKeyboardButton(
            f"{'🟢' if on else '⚪'} {u['name']}",
            callback_data=f"warp_{u['name']}"
        )])
    buttons.append([InlineKeyboardButton("« Назад", callback_data="main")])

    await query.edit_message_text(
        "🔄 *WARP* — нажмите на пользователя чтобы переключить:",
        reply_markup=InlineKeyboardMarkup(buttons),
        parse_mode="MarkdownV2"
    )

@admin_only
async def toggle_warp(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()
    name = query.data[len("warp_"):]
    pc = load_panel_config()
    warp_users = set(pc.get("warp_users", []))
    if name in warp_users:
        warp_users.discard(name)
        status = "выключен"
    else:
        warp_users.add(name)
        status = "включён"
    pc["warp_users"] = list(warp_users)
    Path(PANEL_CONFIG).write_text(json.dumps(pc, indent=2))

    # Перестроить egress
    cfg = load_mita_config()
    warp_users_after = set(pc.get("warp_users", []))
    if not warp_users_after:
        cfg.pop("egress", None)
    else:
        wp = {"name": "warp", "protocol": "SOCKS5_PROXY_PROTOCOL",
              "host": "127.0.0.1", "port": 40000}
        has_full = any(pc.get("warp_rules", {}).get(u, {}).get("full_warp") for u in warp_users_after)
        if has_full:
            cfg["egress"] = {
                "proxies": [wp],
                "rules": [{"ipRanges": ["*"], "domainNames": ["*"],
                           "action": "PROXY", "proxyNames": ["warp"]}],
            }
        else:
            all_dom = set()
            all_ip = set()
            for uname in warp_users_after:
                r = pc.get("warp_rules", {}).get(uname, {})
                all_dom.update(d for d in r.get("domains", []) if d)
                all_ip.update(i for i in r.get("ips", []) if i)
            if all_dom or all_ip:
                wr = {"action": "PROXY", "proxyNames": ["warp"]}
                if all_dom: wr["domainNames"] = sorted(all_dom)
                if all_ip:  wr["ipRanges"] = sorted(all_ip)
                cfg["egress"] = {
                    "proxies": [wp],
                    "rules": [wr, {"ipRanges": ["*"], "domainNames": ["*"], "action": "DIRECT"}],
                }
            else:
                cfg.pop("egress", None)
    Path(MITA_CONFIG).write_text(json.dumps(cfg, indent=2, ensure_ascii=False))
    subprocess.run(["mita", "apply", "config", MITA_CONFIG], capture_output=True)
    subprocess.run(["systemctl", "restart", "mita"], capture_output=True)

    await query.edit_message_text(
        f"🔄 WARP для `{escape_md(name)}`: *{status}*",
        reply_markup=InlineKeyboardMarkup([
            [InlineKeyboardButton("« К списку WARP", callback_data="warp_menu")],
            [InlineKeyboardButton("« На главную", callback_data="main")],
        ]),
        parse_mode="MarkdownV2"
    )

def _build_client_config(name, password):
    cfg = load_mita_config()
    bindings = cfg.get("portBindings", [{}])[0]
    proto = bindings.get("protocol", "TCP")
    port_range = bindings.get("portRange", str(bindings.get("port", "?")))
    ip = get_server_ip()
    return {
        "profiles": [{"profileName": "default",
                       "user": {"name": name, "password": password},
                       "servers": [{"ipAddress": ip,
                                    "portBindings": [{"portRange": port_range,
                                                      "protocol": proto}]}]}],
        "activeProfile": "default",
        "rpcPort": 8964,
        "socks5Port": 1080,
    }

# ── config / Karing ──────────────────────────────────────────────────────────
@admin_only
async def show_user_menu(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()
    name = query.data[len("user_"):]
    cfg = load_mita_config()
    user = next((u for u in cfg.get("users", []) if u["name"] == name), None)
    if not user:
        await query.answer("Пользователь не найден")
        return
    await query.edit_message_text(
        f"👤 *{escape_md(name)}*",
        reply_markup=InlineKeyboardMarkup([
            [InlineKeyboardButton("📋 JSON-конфиг", callback_data=f"config_{name}"),
             InlineKeyboardButton("📱 Karing", callback_data=f"karing_{name}")],
            [InlineKeyboardButton("« К пользователям", callback_data="users")],
            [InlineKeyboardButton("« На главную", callback_data="main")],
        ]),
        parse_mode="MarkdownV2"
    )

@admin_only
async def show_config(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()
    name = query.data[len("config_"):]
    cfg = load_mita_config()
    user = next((u for u in cfg.get("users", []) if u["name"] == name), None)
    if not user:
        await query.answer("Пользователь не найден")
        return

    data = json.dumps(_build_client_config(name, user["password"]), indent=2, ensure_ascii=False)
    await query.edit_message_text(
        f"📋 Конфиг `{escape_md(name)}`:\n```json\n{data[:3500]}\n```",
        reply_markup=InlineKeyboardMarkup([
            [InlineKeyboardButton("📱 Karing", callback_data=f"karing_{name}")],
            [InlineKeyboardButton("« К пользователю", callback_data=f"user_{name}")],
            [InlineKeyboardButton("« К списку", callback_data="users")],
        ]),
        parse_mode="MarkdownV2"
    )

@admin_only
async def show_karing(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()
    name = query.data[len("karing_"):]
    cfg = load_mita_config()
    user = next((u for u in cfg.get("users", []) if u["name"] == name), None)
    if not user:
        await query.answer("Пользователь не найден")
        return

    data = _build_client_config(name, user["password"])
    ip = data["profiles"][0]["servers"][0]["ipAddress"]
    pb = data["profiles"][0]["servers"][0]["portBindings"][0]
    port = (pb["portRange"] or str(pb.get("port", "?"))).split("-")[0]

    text = (
        f"📱 *Ручная настройка Karing* для `{escape_md(name)}`\n\n"
        f"Поля для ввода в Karing:\n\n"
        f"server:\n```\n{ip}\n```\n"
        f"server port:\n```\n{port}\n```\n"
        f"username:\n```\n{name}\n```\n"
        f"password:\n```\n{user['password']}\n```\n"
        f"transport:\n```\nTCP\n```\n"
        f"multiplexing: *multiplexing\\_low*"
    )

    await query.edit_message_text(
        text,
        reply_markup=InlineKeyboardMarkup([
            [InlineKeyboardButton("📋 JSON-конфиг", callback_data=f"config_{name}")],
            [InlineKeyboardButton("« К пользователю", callback_data=f"user_{name}")],
            [InlineKeyboardButton("« К списку", callback_data="users")],
        ]),
        parse_mode="MarkdownV2"
    )

# ── security ─────────────────────────────────────────────────────────────────
@admin_only
async def show_security(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()

    installed = subprocess.run(["which","fail2ban-client"], capture_output=True).returncode == 0
    active = jail_active = False
    if installed:
        r = subprocess.run(["systemctl","is-active","fail2ban"], capture_output=True, text=True)
        active = r.stdout.strip() == "active"
        if active:
            r2 = subprocess.run(["fail2ban-client","status","mita-panel"], capture_output=True, text=True)
            jail_active = r2.returncode == 0

    pc = load_panel_config()
    max_retry = pc.get("login_max_attempts", 5)
    ban_time  = pc.get("login_ban_seconds", 3600)

    def fmt_sec(s):
        if s >= 86400: return f"{s//86400} дн"
        if s >= 3600:  return f"{s//3600} ч"
        if s >= 60:    return f"{s//60} мин"
        return f"{s} сек"

    text = (
        "🛡 *Безопасность*\n\n"
        f"fail2ban: {'✅ установлен' if installed else '❌ не установлен'}\n"
        f"Статус: {'🟢 активен' if active else '🔴 остановлен'}\n"
        f"Jail mita\\-panel: {'🟢 активен' if jail_active else '⚪ не настроен'}\n\n"
        f"Лимиты входа:\n"
        f"• попыток: *{max_retry}*\n"
        f"• бан: *{fmt_sec(ban_time)}*\n"
        f"• встроенный лимит: {'✅' if pc.get('login_max_attempts') else '⚪'}\n\n"
        "*Применить пресет:*"
    )

    await query.edit_message_text(
        text,
        reply_markup=InlineKeyboardMarkup([
            [InlineKeyboardButton("Строгий 3/30m", callback_data="f2b_3_1800"),
             InlineKeyboardButton("Стандарт 5/1h", callback_data="f2b_5_3600")],
            [InlineKeyboardButton("Мягкий 10/15m", callback_data="f2b_10_900"),
             InlineKeyboardButton("Жёсткий 3/24h", callback_data="f2b_3_86400")],
            [InlineKeyboardButton("Установить fail2ban", callback_data="f2b_install")],
            [InlineKeyboardButton("« Назад", callback_data="main")],
        ]),
        parse_mode="MarkdownV2"
    )

@admin_only
async def apply_f2b_preset(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()
    parts = query.data.split("_")
    if len(parts) >= 3 and parts[1] == "install":
        r = subprocess.run(["apt-get","install","-y","-qq","fail2ban"], capture_output=True, text=True)
        if r.returncode != 0:
            await query.edit_message_text(
                f"❌ Ошибка установки fail2ban: {r.stderr.strip()[:500]}",
                reply_markup=back_button(),
                parse_mode="MarkdownV2"
            )
            return
        await query.edit_message_text(
            "✅ fail2ban установлен. Настройте лимиты через пресеты.",
            reply_markup=InlineKeyboardMarkup([
                [InlineKeyboardButton("« К безопасности", callback_data="security")],
            ]),
            parse_mode="MarkdownV2"
        )
        return

    if len(parts) < 4:
        return
    max_retry = int(parts[2])
    ban_time  = int(parts[3])

    pc = load_panel_config()
    pc["login_max_attempts"] = max_retry
    pc["login_ban_seconds"]  = ban_time
    Path(PANEL_CONFIG).write_text(json.dumps(pc, indent=2))

    filter_content = f"""[Definition]
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
        subprocess.run(["systemctl","restart","fail2ban"], capture_output=True)
    except Exception:
        pass

    def fmt_sec(s):
        if s >= 86400: return f"{s//86400} дн"
        if s >= 3600:  return f"{s//3600} ч"
        if s >= 60:    return f"{s//60} мин"
        return f"{s} сек"

    await query.edit_message_text(
        f"🛡 *Пресет применён*\n\n"
        f"Попыток: *{max_retry}*\nБан: *{fmt_sec(ban_time)}*",
        reply_markup=InlineKeyboardMarkup([
            [InlineKeyboardButton("« К безопасности", callback_data="security")],
            [InlineKeyboardButton("« На главную", callback_data="main")],
        ]),
        parse_mode="MarkdownV2"
    )

# ── dashboard ─────────────────────────────────────────────────────────────────
@admin_only
async def show_dashboard(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()
    cpu = psutil.cpu_percent(interval=0.5)
    mem = psutil.virtual_memory()
    disk = psutil.disk_usage("/")
    ip = get_server_ip()
    mita_ok = _mita_running()

    warp_ip = "недоступен"
    try:
        r = subprocess.run(["curl","-s","--max-time","5","--proxy",
                            "socks5h://127.0.0.1:40000","https://ifconfig.me"],
                           capture_output=True, text=True)
        warp_ip = r.stdout.strip()
    except Exception:
        pass

    cfg = load_mita_config()
    user_count = len(cfg.get("users", []))
    bindings = cfg.get("portBindings", [{}])[0]
    port = bindings.get("portRange", str(bindings.get("port","?")))

    traffic = (0, 0)
    try:
        raw = mita_cmd("get", "users")
        week_total = month_total = 0.0
        for line in raw.splitlines():
            line = line.strip()
            if not line or line.upper().startswith("USER"):
                continue
            parts = line.split()
            if len(parts) < 8:
                continue
            week_total  += _parse_traffic(parts[4]) + _parse_traffic(parts[5])
            month_total += _parse_traffic(parts[6]) + _parse_traffic(parts[7])
        traffic = (round(week_total/1024**3, 2), round(month_total/1024**3, 2))
    except Exception:
        pass

    w, m = traffic

    await query.edit_message_text(
        f"📊 *Дашборд*\n\n"
        f"IP: `{ip}`\nWARP: `{warp_ip}`\nПорт: `{port}`\n"
        f"Пользователей: `{user_count}`\n"
        f"Трафик нед: `{w} ГБ`  мес: `{m} ГБ`\n"
        f"mita: {'🟢' if mita_ok else '🔴'}\n"
        f"CPU: `{cpu:.1f}%`  RAM: `{mem.percent:.1f}%`  Диск: `{disk.percent:.1f}%`",
        reply_markup=InlineKeyboardMarkup([
            [InlineKeyboardButton("🔄 Обновить", callback_data="dashboard")],
            [InlineKeyboardButton("« Назад", callback_data="main")],
        ]),
        parse_mode="MarkdownV2"
    )

# ── help ──────────────────────────────────────────────────────────────────────
@admin_only
async def show_help(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()
    await query.edit_message_text(
        "📋 *Команды*\n\n"
        "Используйте кнопки меню:\n"
        "👥 Пользователи — список с трафиком, конфиг, Karing\n"
        "➕ Создать — создать пользователя\n"
        "🗑 Удалить — выбрать и удалить\n"
        "🔄 WARP — включить/выключить\n"
        "🛡 Безопасность — fail2ban, лимиты\n"
        "📊 Дашборд — полный обзор",
        reply_markup=back_button(),
        parse_mode="MarkdownV2"
    )

# ── callback router ───────────────────────────────────────────────────────────
@admin_only
async def router(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    data = query.data

    if data == "main":
        return await show_main(update, context)
    elif data == "users":
        return await show_users(update, context)
    elif data == "create":
        return await create_user(update, context)
    elif data in ("create_easy", "create_hard"):
        return await create_exec(update, context)
    elif data == "delete_menu":
        return await delete_menu(update, context)
    elif data.startswith("delete_"):
        return await delete_user(update, context)
    elif data == "warp_menu":
        return await warp_menu(update, context)
    elif data.startswith("warp_"):
        return await toggle_warp(update, context)
    elif data.startswith("user_"):
        return await show_user_menu(update, context)
    elif data == "security":
        return await show_security(update, context)
    elif data.startswith("config_"):
        return await show_config(update, context)
    elif data.startswith("karing_"):
        return await show_karing(update, context)
    elif data.startswith("f2b_"):
        return await apply_f2b_preset(update, context)
    elif data == "dashboard":
        return await show_dashboard(update, context)
    elif data == "help":
        return await show_help(update, context)

# ── main ──────────────────────────────────────────────────────────────────────
def main():
    cfg = load_bot_config()
    token = os.environ.get("BOT_TOKEN", cfg.get("token", ""))
    if not token:
        _log.error("BOT_TOKEN не задан — ни в env, ни в %s", BOT_CONFIG)
        raise SystemExit(1)

    app = Application.builder().token(token).build()
    app.add_handler(CommandHandler("start", cmd_start))
    app.add_handler(CallbackQueryHandler(router))

    _log.info("Бот запущен")
    app.run_polling()

if __name__ == "__main__":
    main()
