#!/usr/bin/env python3
"""
mita Telegram Bot — управление сервером через Telegram
"""
import os, json, re, subprocess, psutil, logging
from datetime import datetime
from pathlib import Path

logging.basicConfig(level=logging.INFO,
                    format="%(asctime)s %(levelname)s [bot] %(message)s")
_log = logging.getLogger("mita_bot")

BOT_CONFIG   = os.environ.get("BOT_CONFIG", "/etc/mita/bot.json")
MITA_CONFIG  = "/etc/mita/server_config.json"
PANEL_CONFIG = "/etc/mita/panel.json"

try:
    from telegram import Update
    from telegram.ext import Application, CommandHandler, ContextTypes
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

# ── auth ──────────────────────────────────────────────────────────────────────
def admin_only(func):
    async def wrapper(update: Update, context: ContextTypes.DEFAULT_TYPE):
        user_id = str(update.effective_user.id)
        cfg = load_bot_config()
        admins = cfg.get("admin_ids", [])
        if user_id not in admins:
            await update.message.reply_text("⛔ Доступ запрещён.")
            return
        return await func(update, context)
    return wrapper

# ── commands ──────────────────────────────────────────────────────────────────
@admin_only
async def cmd_start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    await update.message.reply_text(
        "🤖 *mita Bot* готов к работе\\.\n\n"
        "/users \\- список пользователей\n"
        "/create \\[имя\\] \\- создать пользователя\n"
        "/delete \\<имя\\> \\- удалить пользователя\n"
        "/warp \\<имя\\> on\\|off \\- управление WARP\n"
        "/stats \\- статистика сервера\n"
        "/dashboard \\- полный дашборд\n"
        "/help \\- все команды",
        parse_mode="MarkdownV2"
    )

@admin_only
async def cmd_help(update: Update, context: ContextTypes.DEFAULT_TYPE):
    await update.message.reply_text(
        "📋 *Команды*\n\n"
        "/users \\- список пользователей с трафиком и статусом\n"
        "/create \\- создать пользователя \\(случайное имя\\)\n"
        "/create `имя` \\- создать с указанным именем\n"
        "/delete `имя` \\- удалить пользователя\n"
        "/warp `имя` on \\- включить WARP\n"
        "/warp `имя` off \\- выключить WARP\n"
        "/stats \\- CPU, RAM, диск\n"
        "/dashboard \\- полный обзор сервера\n"
        "/config `имя` \\- клиентский конфиг",
        parse_mode="MarkdownV2"
    )

@admin_only
async def cmd_users(update: Update, context: ContextTypes.DEFAULT_TYPE):
    cfg = load_mita_config()
    users = cfg.get("users", [])
    if not users:
        await update.message.reply_text("👤 Нет пользователей.")
        return

    raw = mita_cmd("get", "users")
    pc = load_panel_config()
    warp_users = set(pc.get("warp_users", []))

    lines = []
    today = datetime.now().date()

    data_lines = []
    for line in raw.splitlines():
        line = line.strip()
        if not line or line.upper().startswith("USER"):
            continue
        data_lines.append(line)

    stats_map = {}
    for line in data_lines:
        parts = line.split()
        if len(parts) < 8:
            continue
        try:
            name = parts[0]

            d1_down  = _parse_traffic(parts[2])
            d1_up    = _parse_traffic(parts[3])
            d7_down  = _parse_traffic(parts[4])
            d7_up    = _parse_traffic(parts[5])
            d30_down = _parse_traffic(parts[6])
            d30_up   = _parse_traffic(parts[7])

            d1_bytes = d1_down + d1_up
            d7_bytes = d7_down + d7_up
            d30_bytes = d30_down + d30_up

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

    for u in users:
        name = u["name"]
        s = stats_map.get(name, {})
        w = "🟢" if name in warp_users else "⚪"
        o = "🟢" if s.get("online") else "🔴"
        day = f"{s.get('day_mb', 0):.1f} МБ" if s.get("day_mb") else "—"
        mon = f"{s.get('month_mb', 0):.1f} МБ" if s.get("month_mb") else "—"
        lines.append(f"{o} `{name}` {w}  \\| день: {day} \\| мес: {mon}")

    await update.message.reply_text(
        "👥 *Пользователи*\n\n" + "\n".join(lines),
        parse_mode="MarkdownV2"
    )

@admin_only
async def cmd_create(update: Update, context: ContextTypes.DEFAULT_TYPE):
    args = context.args
    cfg = load_mita_config()
    existing = {u["name"] for u in cfg.get("users", [])}

    if args:
        name = args[0].strip()
    else:
        import secrets
        adj = ["swift","brave","quiet","cool","sharp","calm","bright","dark","wild","free"]
        nouns = ["fox","hawk","river","storm","ember","peak","orbit","tide","frost","spark"]
        name = f"{secrets.choice(adj)}_{secrets.choice(nouns)}_{secrets.randbelow(9000)+1000}"
        while name in existing:
            name = f"{secrets.choice(adj)}_{secrets.choice(nouns)}_{secrets.randbelow(9000)+1000}"

    if name in existing:
        await update.message.reply_text(f"❌ Пользователь `{name}` уже существует\\.")
        return

    import string
    chars = string.ascii_letters + string.digits + "!@#%^*_-=+?."
    password = "".join(secrets.choice(chars) for _ in range(64))

    cfg.setdefault("users", []).append({"name": name, "password": password})
    Path(MITA_CONFIG).write_text(json.dumps(cfg, indent=2, ensure_ascii=False))

    subprocess.run(["mita", "apply", "config", MITA_CONFIG], capture_output=True)
    subprocess.run(["systemctl", "restart", "mita"], capture_output=True)

    ip = get_server_ip()
    bindings = cfg.get("portBindings", [{}])[0]
    port = bindings.get("portRange", str(bindings.get("port","?")))

    await update.message.reply_text(
        f"✅ Пользователь *{name}* создан\\.\n\n"
        f"Сервер: `{ip}`\n"
        f"Порт: `{port}`\n"
        f"Пароль: `{password}`\n\n"
        f"Получить JSON\\-конфиг: /config `{name}`",
        parse_mode="MarkdownV2"
    )

@admin_only
async def cmd_delete(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not context.args:
        await update.message.reply_text("❌ Укажите имя: `/delete имя`", parse_mode="MarkdownV2")
        return
    name = context.args[0].strip()
    cfg = load_mita_config()
    cfg["users"] = [u for u in cfg.get("users", []) if u["name"] != name]
    Path(MITA_CONFIG).write_text(json.dumps(cfg, indent=2, ensure_ascii=False))
    subprocess.run(["mita", "apply", "config", MITA_CONFIG], capture_output=True)
    subprocess.run(["systemctl", "restart", "mita"], capture_output=True)
    await update.message.reply_text(f"🗑 Пользователь `{name}` удалён\\.", parse_mode="MarkdownV2")

@admin_only
async def cmd_warp(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if len(context.args) < 2:
        await update.message.reply_text(
            "❌ Формат: `/warp имя on` или `/warp имя off`", parse_mode="MarkdownV2")
        return
    name = context.args[0].strip()
    action = context.args[1].lower()
    if action not in ("on", "off"):
        await update.message.reply_text("❌ Укажите `on` или `off`\\.", parse_mode="MarkdownV2")
        return

    pc = load_panel_config()
    warp_users = set(pc.get("warp_users", []))
    if action == "on":
        warp_users.add(name)
    else:
        warp_users.discard(name)
    pc["warp_users"] = list(warp_users)
    Path(PANEL_CONFIG).write_text(json.dumps(pc, indent=2))
    await update.message.reply_text(
        f"🔄 WARP для `{name}`: *{action.upper()}* \\(сохранено в panel\\.json\\)",
        parse_mode="MarkdownV2"
    )

@admin_only
async def cmd_config(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not context.args:
        await update.message.reply_text("❌ Укажите имя: `/config имя`", parse_mode="MarkdownV2")
        return
    name = context.args[0].strip()
    cfg = load_mita_config()
    user = next((u for u in cfg.get("users", []) if u["name"] == name), None)
    if not user:
        await update.message.reply_text(f"❌ Пользователь `{name}` не найден\\.", parse_mode="MarkdownV2")
        return
    ip = get_server_ip()
    bindings = cfg.get("portBindings", [{}])[0]
    port = bindings.get("portRange", str(bindings.get("port","?")))
    data = json.dumps({
        "profiles": [{"profileName": "default",
                       "user": {"name": user["name"], "password": user["password"]},
                       "servers": [{"ipAddress": ip,
                                    "portBindings": [{"portRange": port,
                                                      "protocol": bindings.get("protocol","TCP")}]}]}],
        "activeProfile": "default",
        "rpcPort": 8964,
        "socks5Port": 1080,
    }, indent=2, ensure_ascii=False)

    await update.message.reply_text(f"```json\n{data}\n```", parse_mode=None)

@admin_only
async def cmd_stats(update: Update, context: ContextTypes.DEFAULT_TYPE):
    cpu = psutil.cpu_percent(interval=1)
    mem = psutil.virtual_memory()
    disk = psutil.disk_usage("/")
    boot = datetime.fromtimestamp(psutil.boot_time()).strftime("%d.%m.%Y %H:%M")

    await update.message.reply_text(
        f"📊 *Сервер*\n\n"
        f"CPU: `{cpu:.1f}%`\n"
        f"RAM: `{mem.percent:.1f}%` \\({fmt_bytes(mem.used)} / {fmt_bytes(mem.total)}\\)\n"
        f"Диск: `{disk.percent:.1f}%` \\({fmt_bytes(disk.used)} / {fmt_bytes(disk.total)}\\)\n"
        f"Аптайм: с `{boot}`\n"
        f"mita: {'🟢 работает' if _mita_running() else '🔴 остановлен'}",
        parse_mode="MarkdownV2"
    )

@admin_only
async def cmd_dashboard(update: Update, context: ContextTypes.DEFAULT_TYPE):
    cpu = psutil.cpu_percent(interval=1)
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

    traffic = None
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

    w, m = traffic or (0, 0)

    await update.message.reply_text(
        f"📊 *Дашборд*\n\n"
        f"IP сервера: `{ip}`\n"
        f"IP WARP: `{warp_ip}`\n"
        f"Порт mita: `{port}`\n"
        f"Пользователей: `{user_count}`\n"
        f"Трафик нед\\.: `{w} ГБ`\n"
        f"Трафик мес\\.: `{m} ГБ`\n"
        f"mita: {'🟢' if mita_ok else '🔴'}\n"
        f"CPU: `{cpu:.1f}%`  RAM: `{mem.percent:.1f}%`  Диск: `{disk.percent:.1f}%`",
        parse_mode="MarkdownV2"
    )

# ── main ──────────────────────────────────────────────────────────────────────
def main():
    cfg = load_bot_config()
    token = os.environ.get("BOT_TOKEN", cfg.get("token", ""))
    if not token:
        _log.error("BOT_TOKEN не задан — ни в env, ни в %s", BOT_CONFIG)
        raise SystemExit(1)

    app = Application.builder().token(token).build()
    app.add_handler(CommandHandler("start", cmd_start))
    app.add_handler(CommandHandler("help", cmd_help))
    app.add_handler(CommandHandler("users", cmd_users))
    app.add_handler(CommandHandler("create", cmd_create))
    app.add_handler(CommandHandler("delete", cmd_delete))
    app.add_handler(CommandHandler("warp", cmd_warp))
    app.add_handler(CommandHandler("config", cmd_config))
    app.add_handler(CommandHandler("stats", cmd_stats))
    app.add_handler(CommandHandler("dashboard", cmd_dashboard))

    _log.info("Бот запущен")
    app.run_polling()

if __name__ == "__main__":
    main()
