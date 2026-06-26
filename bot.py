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

def gen_password(length=64):
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
     InlineKeyboardButton("📊 Статистика", callback_data="stats")],
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
    for u in users:
        name = u["name"]
        s = stats_map.get(name, {})
        w = "🟢" if name in warp_users else "⚪"
        o = "🟢" if s.get("online") else "🔴"
        day = f"{s.get('day_mb', 0):.1f} МБ" if s.get("day_mb") else "—"
        wk = f"{s.get('week_mb', 0):.1f} МБ" if s.get("week_mb") else "—"
        mon = f"{s.get('month_mb', 0):.1f} МБ" if s.get("month_mb") else "—"
        ename = escape_md(name)
        lines.append(f"{o} {ename} {w}  день: {day}  нед: {wk}  мес: {mon}")

    await query.edit_message_text(
        "\n".join(lines),
        reply_markup=InlineKeyboardMarkup([
            [InlineKeyboardButton("➕ Создать", callback_data="create"),
             InlineKeyboardButton("🗑 Удалить", callback_data="delete_menu")],
            [InlineKeyboardButton("🔄 WARP", callback_data="warp_menu")],
            [InlineKeyboardButton("« Назад", callback_data="main")],
        ]),
        parse_mode="MarkdownV2"
    )

# ── create ────────────────────────────────────────────────────────────────────
@admin_only
async def create_user(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()
    cfg = load_mita_config()
    existing = {u["name"] for u in cfg.get("users", [])}
    name = gen_username()
    while name in existing:
        name = gen_username()

    password = gen_password()
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
    await query.edit_message_text(
        f"🔄 WARP для `{escape_md(name)}`: *{status}*",
        reply_markup=InlineKeyboardMarkup([
            [InlineKeyboardButton("« К списку WARP", callback_data="warp_menu")],
            [InlineKeyboardButton("« На главную", callback_data="main")],
        ]),
        parse_mode="MarkdownV2"
    )

# ── stats ─────────────────────────────────────────────────────────────────────
@admin_only
async def show_stats(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()
    cpu = psutil.cpu_percent(interval=0.5)
    mem = psutil.virtual_memory()
    disk = psutil.disk_usage("/")
    boot = datetime.fromtimestamp(psutil.boot_time()).strftime("%d.%m.%Y %H:%M")

    await query.edit_message_text(
        f"📊 *Сервер*\n\n"
        f"CPU: `{cpu:.1f}%`\n"
        f"RAM: `{mem.percent:.1f}%` \\({fmt_bytes(mem.used)} / {fmt_bytes(mem.total)}\\)\n"
        f"Диск: `{disk.percent:.1f}%` \\({fmt_bytes(disk.used)} / {fmt_bytes(disk.total)}\\)\n"
        f"Аптайм: с `{boot}`\n"
        f"mita: {'🟢 работает' if _mita_running() else '🔴 остановлен'}",
        reply_markup=InlineKeyboardMarkup([
            [InlineKeyboardButton("🔄 Обновить", callback_data="stats")],
            [InlineKeyboardButton("« Назад", callback_data="main")],
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
        "👥 Пользователи — список с трафиком\n"
        "➕ Создать — создать пользователя\n"
        "🗑 Удалить — выбрать и удалить\n"
        "🔄 WARP — включить/выключить\n"
        "📊 Статистика — CPU, RAM, диск\n"
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
    elif data == "delete_menu":
        return await delete_menu(update, context)
    elif data.startswith("delete_"):
        return await delete_user(update, context)
    elif data == "warp_menu":
        return await warp_menu(update, context)
    elif data.startswith("warp_"):
        return await toggle_warp(update, context)
    elif data == "stats":
        return await show_stats(update, context)
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
