#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
awg_bot.py — Telegram-бот управления сервером AmneziaWG.
Полностью кнопочный (единственная команда /start). Старается жить одним
сообщением: каждое нажатие РЕДАКТИРУЕТ текущее сообщение, а не шлёт новое.
Файлы (конфиги/QR/бэкап) — отдельными сообщениями (их редактировать нельзя).
"""

import asyncio
import glob
import html
import json
import os
import re
import shlex
import socket
import subprocess
import sys
import time

from aiogram import Bot, Dispatcher, F
from aiogram.filters import Command
from aiogram.fsm.context import FSMContext
from aiogram.fsm.state import State, StatesGroup
from aiogram.fsm.storage.memory import MemoryStorage
from aiogram.exceptions import TelegramBadRequest
from aiogram.types import (
    Message, FSInputFile, CallbackQuery,
    InlineKeyboardMarkup, InlineKeyboardButton,
)

TOKEN = os.environ.get("AWG_BOT_TOKEN", "")
ADMINS = {int(x) for x in os.environ.get("AWG_BOT_ADMINS", "").replace(" ", "").split(",") if x}
CLIENT_SH = os.environ.get("AWG_CLIENT_SH", "/usr/local/bin/awg-client")
DOCTOR_SH = os.environ.get("AWG_DOCTOR_SH", "/usr/local/bin/awg-doctor")
OBF_SH = os.environ.get("AWG_OBF_SH", "/usr/local/bin/awg-obfuscation")
BACKUP_SH = os.environ.get("AWG_BACKUP_SH", "/usr/local/bin/awg-backup")
CLIENT_DIR = os.environ.get("AWG_CLIENT_DIR", "/opt/awg3/clients")
STATS_PY = os.environ.get("AWG_STATS_PY", "/opt/awg3/awg_stats.py")
EXPORT_PY = os.environ.get("AWG_EXPORT_PY", "/opt/awg3/awg-export.py")
VENV_PY = os.environ.get("AWG_VENV_PY", "/opt/awg3/venv/bin/python")
SERVICES_ENV = os.environ.get("AWG_SERVICES_ENV", "/etc/amnezia/amneziawg/services.env")
STATUS_FILE = os.environ.get("AWG_UPDATE_STATUS", "/opt/awg3/az-update-status.json")
INSTALL_SH_URL = os.environ.get(
    "AWG_INSTALL_SH_URL",
    "https://raw.githubusercontent.com/blindtechnique/awg3/main/install.sh")
LOG_DIR = "/var/log"

if not TOKEN or not ADMINS:
    print("AWG_BOT_TOKEN и AWG_BOT_ADMINS обязательны (systemd Environment=)", file=sys.stderr)
    sys.exit(1)


NAME_RE = re.compile(r"^[A-Za-z0-9_-]{1,32}$")
PY = VENV_PY if os.path.exists(VENV_PY) else "python3"
bot = Bot(TOKEN)
dp = Dispatcher(storage=MemoryStorage())
_pending_restore = set()


class Flow(StatesGroup):
    name = State()




def is_admin(cid: int) -> bool:
    return cid in ADMINS


def run(cmd: list, timeout: int = 180, env: dict = None) -> tuple:
    try:
        p = subprocess.run(cmd, capture_output=True, text=True,
                           timeout=timeout, stdin=subprocess.DEVNULL, env=env)
        return p.returncode, p.stdout.strip(), p.stderr.strip()
    except subprocess.TimeoutExpired:
        return 1, "", "timeout"
    except Exception as e:  # noqa: BLE001
        return 1, "", str(e)




def stats(*a) -> str:
    rc, out, err = run([PY, STATS_PY, *a])
    return out or err or "нет данных"


def server_host() -> str:
    """Адрес, который видят клиенты: домен или IP из плана сервисов."""
    try:
        for line in open(SERVICES_ENV, encoding="utf-8"):
            if line.startswith("ENDPOINT="):
                h = line.split("=", 1)[1].strip().strip("'\"")
                if h:
                    return h
    except OSError:
        pass
    try:
        return socket.gethostname()
    except Exception:  # noqa: BLE001
        return "server"


# ── фоновые долгие операции (systemd-run: переживают рестарт бота) ──────────

def obf_env() -> dict:
    """awg-obfuscation.sh применяет профиль к конфигу своего слоя. Имена
    интерфейсов берём из services.env: они выбираются при установке."""
    env = dict(os.environ)
    i2, i3 = "awg2", "awg3"
    try:
        for line in open(SERVICES_ENV, encoding="utf-8"):
            line = line.strip()
            if line.startswith("IFACE2="):
                i2 = line.split("=", 1)[1].strip("'\"")
            elif line.startswith("IFACE3="):
                i3 = line.split("=", 1)[1].strip("'\"")
    except OSError:
        pass
    env["AWG_IFACE2"] = i2
    env["AWG_IFACE3"] = i3
    return env


# пресеты те же, что предлагает установщик; router и low объявлены без
# header protection, паддинга и таймингов — на слое 3.0 это значит, что он
# обфусцирует ровно как 2.0
OBF_PRESETS = ("router", "low", "medium", "high", "paranoid")
OBF_WEAK_FOR_V3 = ("router", "low")


def layer_client_count(v3: bool) -> int:
    """Сколько клиентов потеряют доступ при смене профиля этого слоя."""
    return len(set(awg_names("awg3" if v3 else "awg2")))


def obf_apply_cmd(v3: bool, preset: str, tpl: str) -> list:
    """Команда для transient-юнита: сменить профиль слоя и перевыпустить конфиги.

    Пути к конфигам не передаём: awg-obfuscation.sh сам читает services.env и
    берёт интерфейс своего слоя.

    regen-all выполняется ТОЛЬКО при успешной смене профиля — иначе клиенты
    получили бы конфиги от профиля, который на сервер не лёг.

    Маркер в конце — единственный надёжный способ узнать исход: юнит запущен
    с --collect и до опроса не доживает, а по хвосту лога результат не читается.
    """
    parts = [shlex.quote(OBF_SH)]
    if v3:
        parts.append("--v3")
    parts += ["--preset", shlex.quote(preset), "--fp", "chrome"]
    if tpl != "auto":
        parts += ["--template", shlex.quote(tpl)]
    parts.append("--apply")
    return ["bash", "-c",
            "if %s && %s regen-all; then echo AWG_OBF_RESULT=ok; "
            "else echo AWG_OBF_RESULT=fail; fi"
            % (" ".join(parts), shlex.quote(CLIENT_SH))]


def unit_active(unit: str) -> bool:
    rc, out, _ = run(["systemctl", "is-active", unit], timeout=10)
    return out.strip() in ("active", "activating")


def start_bg_unit(unit: str, cmd: list, logfile: str) -> tuple:
    """Запустить команду фоновым transient-юнитом с логом в файл.
    systemd-run --collect убирает юнит после завершения (даже failed)."""
    if unit_active(unit):
        return 1, "", "операция уже выполняется"
    open(logfile, "w").close()
    full = ["systemd-run", "--collect", f"--unit={unit}",
            "-p", f"StandardOutput=append:{logfile}",
            "-p", f"StandardError=append:{logfile}", "--"] + cmd
    return run(full, timeout=30)


def log_tail(logfile: str, lines: int = 14, width: int = 3200) -> str:
    try:
        data = open(logfile, encoding="utf-8", errors="ignore").read()
    except OSError:
        return "(лог пуст)"
    tail = "\n".join(data.splitlines()[-lines:])
    return tail[-width:] if tail else "(лог пуст)"


def read_status() -> dict:
    try:
        return json.load(open(STATUS_FILE, encoding="utf-8"))
    except Exception:  # noqa: BLE001
        return {}


def write_status_flag(**kw):
    try:
        cur = read_status()
        cur.update(kw)
        json.dump(cur, open(STATUS_FILE, "w", encoding="utf-8"), ensure_ascii=False)
    except Exception:  # noqa: BLE001
        pass


async def watch_unit(c: CallbackQuery, unit: str, logfile: str, title: str,
                     done_note: str, back_cb: str = "upd:menu",
                     poll: float = 4.0, max_minutes: int = 95):
    """Живой прогресс: редактируем одно сообщение хвостом лога, пока юнит жив."""
    started = time.time()
    while unit_active(unit):
        if time.time() - started > max_minutes * 60:
            await show(c, f"{title}\n⚠️ Превышен лимит {max_minutes} мин — "
                          "смотри лог на сервере.", kb([back(back_cb)]))
            return
        await show(c, f"{title}\n<pre>{html.escape(log_tail(logfile))}</pre>",
                   kb([back(back_cb)]), stamp=True)
        await asyncio.sleep(poll)
    # юнит завершился (--collect убрал его; результат — по логу/статусу)
    await show(c, f"{title}\n<pre>{html.escape(log_tail(logfile))}</pre>\n\n{done_note}",
               kb([back(back_cb)]), stamp=True)



def kb(rows) -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text=t, callback_data=d) for t, d in row] for row in rows])


def back(cb="menu:main"):
    return [("⬅️ Назад", cb)]


async def show(c: CallbackQuery, text: str, markup: InlineKeyboardMarkup, stamp: bool = False):
    """Редактировать текущее сообщение (жить одним сообщением). Если нельзя
    (текст не изменился / предыдущее — не текстовое после файла) — послать новое."""
    if stamp:
        text = f"{text}\n\n<i>обновлено {time.strftime('%H:%M:%S')}</i>"
    try:
        await c.message.edit_text(text, parse_mode="HTML", reply_markup=markup)
    except TelegramBadRequest:
        try:
            await c.message.answer(text, parse_mode="HTML", reply_markup=markup)
        except Exception:  # noqa: BLE001
            pass


# ── меню ──────────────────────────────────────────────────────────────────────

def menu_header() -> str:
    # в шапке показываем, какие слои реально подняты
    _l2, _l3 = layers_available()
    ver = "2.0 + 3.0" if (_l2 and _l3) else ("3.0" if _l3 else "2.0")
    return (f"🔐 <b>AmneziaWG {ver}</b> · <code>{html.escape(server_host())}</code>\n"
            "Выбери действие:")


def main_menu() -> InlineKeyboardMarkup:
    return kb([
        [("👥 Клиенты", "clients:menu")],
        [("ℹ️ Информация", "info:server"), ("🩺 Диагностика", "doctor:run")],
        [("🔄 Обновление", "upd:menu")],
        [("🛡 Обфускация", "obf:menu")],
        [("💾 Бэкап", "backup:run"), ("♻️ Восстановить", "restore:ask")],
    ])


def upd_menu() -> InlineKeyboardMarkup:
    return kb([
        [("🔎 Проверить обновления", "upd:check")],
        [("🧬 Обновить код сервера", "upd:awg")],
        [("🛠 Перенастроить обфускацию", "reconf:preset")],
        back(),
    ])


def has_awg_layer() -> bool:
    """Наш слой AmneziaWG 2.0 установлен."""
    return os.path.exists(SERVICES_ENV)


def layers_available() -> tuple:
    """(есть_2_0, есть_3_0) по services.env.

    Слои независимы: 2.0 живёт на kernel-модуле, 3.0 — на userspace-демоне
    amneziawg-go, у каждого свои интерфейсы, порты и профиль обфускации.
    Установщик мог поднять любой из них или оба сразу.
    """
    l2, l3 = True, False
    try:
        for line in open(SERVICES_ENV, encoding="utf-8"):
            line = line.strip()
            if line.startswith("LAYER2="):
                l2 = line.split("=", 1)[1].strip("'\"") == "1"
            elif line.startswith("LAYER3="):
                l3 = line.split("=", 1)[1].strip("'\"") == "1"
    except OSError:
        pass
    return l2, l3


# человекочитаемые названия сервисов обоих слоёв
SVC_TITLE = {"awg2": "AmneziaWG 2.0", "awg3": "AmneziaWG 3.0"}
SVC_TAG = {"awg2": "🔒²", "awg3": "🔒³"}


def render_doctor(out: str, err: str = "") -> str:
    """awg-doctor --json → аккуратный экран в стиле остальных.

    Сырой вывод скрипта в чат не годится: там ANSI-раскраска, которая в Telegram
    превращается в мусор вида «[1;32m», и никакой структуры. Поэтому берём JSON
    и рисуем сами — разделы жирным, статусы кружками, итог отдельной строкой.
    """
    try:
        data = json.loads(out)
    except (ValueError, TypeError):
        # скрипт не смог даже стартовать (слой не установлен и т.п.)
        msg = (err or out or "").strip() or "не удалось получить результат"
        return f"🩺 <b>Диагностика</b>\n\n{html.escape(msg[:1500])}"

    icon = {"OK": "🟢", "FAIL": "🔴", "WARN": "🟡"}
    lines, first = [], True
    for ch in data.get("checks", []):
        st, text = ch.get("status", ""), html.escape(ch.get("text", ""))
        if st == "SECTION":
            lines.append(("" if first else "\n") + f"<b>{text}</b>")
            first = False
        else:
            lines.append(f"{icon.get(st, '•')} {text}")

    problems = data.get("problems", 0)
    total = sum(1 for ch in data.get("checks", []) if ch.get("status") != "SECTION")
    warns = sum(1 for ch in data.get("checks", []) if ch.get("status") == "WARN")
    if problems:
        tail = f"🔴 <b>Проблем: {problems}</b> из {total} проверок"
    elif warns:
        tail = f"🟡 <b>Всё работает</b>, замечаний: {warns}"
    else:
        tail = f"🟢 <b>Всё в порядке</b> — {total} проверок пройдено"
    return "🩺 <b>Диагностика</b>\n\n" + "\n".join(lines) + "\n\n" + tail


def render_selftest(out: str) -> str:
    """awg-selftest → тот же стиль: файл строкой, замечания под ним."""
    body = []
    for ln in (out or "").splitlines():
        s = ln.strip()
        if not s:
            continue
        if s.startswith("✓"):
            body.append("🟢 " + html.escape(s[1:].strip()))
        elif s.startswith("✗"):
            body.append("🔴 " + html.escape(s[1:].strip()))
        elif s.startswith(("конфигов с проблемами", "проверено")):
            body.append("\n<b>" + html.escape(s) + "</b>")
        else:
            body.append("   <i>" + html.escape(s) + "</i>")
    if not body:
        body = ["клиентских конфигов не найдено"]
    return "📄 <b>Проверка выдаваемых конфигов</b>\n\n" + "\n".join(body)[:3500]


def clients_menu() -> InlineKeyboardMarkup:
    rows = []
    _l2, _l3 = layers_available()
    # подпись зависит от того, какие слои подняты
    _lbl = "➕ AmneziaWG 2.0" if not _l3 else ("➕ AmneziaWG 3.0" if not _l2
                                              else "➕ AmneziaWG 2.0 / 3.0")
    rows.append([(_lbl, "awg:menu")])
    rows.append([("⏳ Временный клиент", "temp:menu")])
    rows.append([("📋 Список клиентов", "clients:list")])
    rows.append(back())
    return kb(rows)


def client_menu(svc: str, name: str) -> InlineKeyboardMarkup:
    return kb([
        [("ℹ️ Информация", f"clinfo:{svc}:{name}")],
        [("📥 Скачать конфиг", f"cldl:{svc}:{name}")],
        [("🗑 Удалить", f"cldel:{svc}:{name}")],
        [("⬅️ К списку", "clients:list")],
    ])


# ── списки ────────────────────────────────────────────────────────────────────

def awg_names(svc: str) -> list:
    rc, out, _ = run([CLIENT_SH, "list", svc])
    return [s.strip() for s in out.splitlines() if NAME_RE.match(s.strip())]


# ── отправка артефактов (отдельными сообщениями) ─────────────────────────────

async def send_awg_files(chat: int, svc: str, name: str):
    base = os.path.join(CLIENT_DIR, svc, f"{svc}-{name}")
    conf, qr, vpn = base + "-am.conf", base + ".png", base + ".vpn"
    if os.path.exists(conf):
        await bot.send_document(chat, FSInputFile(conf, filename=f"{name}.conf"),
                                caption=f"📄 {svc}/{name} — AmneziaWG")
    # getsize > 0 — страховка от битого нулевого PNG: send_photo на пустом файле
    # роняет хендлер целиком, и пользователь остаётся с «⏳ Создаю…» навсегда.
    if os.path.exists(qr) and os.path.getsize(qr) > 0:
        await bot.send_photo(chat, FSInputFile(qr),
                             caption="📱 QR — отсканируй в приложении AmneziaWG")
    else:
        # Молча пропасть QR не должен: экспортёр теперь не падает на слишком
        # длинном конфиге, а просто не делает картинку — объясняем, что дальше.
        await bot.send_message(
            chat, "ℹ️ QR не сгенерирован: конфиг не влезает в QR-код. "
                  "Импортируй файл .conf или ссылку vpn:// ниже.")
    if os.path.exists(vpn):
        uri = open(vpn, encoding="utf-8").read().strip()
        await bot.send_message(chat, "🔗 <b>Ссылка vpn:// для приложения Amnezia</b>:",
                               parse_mode="HTML")
        for chunk in (uri[i:i + 3800] for i in range(0, len(uri), 3800)):
            await bot.send_message(chat, f"<code>{html.escape(chunk)}</code>", parse_mode="HTML")


# ── /start ───────────────────────────────────────────────────────────────────

@dp.message(Command("start"))
async def cmd_start(m: Message, state: FSMContext):
    if not is_admin(m.chat.id):
        return await m.answer("⛔️ Доступ запрещён.")
    await state.clear()
    await m.answer(menu_header(), parse_mode="HTML", reply_markup=main_menu())


# ── ввод имени клиента ───────────────────────────────────────────────────────

@dp.message(Flow.name, F.text)
async def on_name(m: Message, state: FSMContext):
    if not is_admin(m.chat.id):
        return
    name = m.text.strip()
    if not NAME_RE.match(name):
        return await m.answer("Имя: 1–32 символа (буквы, цифры, _ , -). Ещё раз:")
    data = await state.get_data()
    await state.clear()
    mid = data.get("_mid")
    try:
        await m.delete()                     # убрать введённое имя — меньше сообщений
    except Exception:  # noqa: BLE001
        pass

    async def upd(text, markup=None):        # редактируем исходное сообщение диалога
        if mid:
            try:
                return await bot.edit_message_text(text, m.chat.id, mid,
                                                   parse_mode="HTML", reply_markup=markup)
            except Exception:  # noqa: BLE001
                pass
        await m.answer(text, parse_mode="HTML", reply_markup=markup)

    kind = data.get("kind")
    if kind in ("awg", "temp_awg"):
        svc = data["svc"]; ttl = data.get("ttl")
        await upd(f"⏳ Создаю <b>{html.escape(name)}</b> ({svc})…")
        cmd = [CLIENT_SH, "add", name, svc] + (["--ttl", ttl] if ttl else [])
        rc, out, err = run(cmd)
        if rc != 0:
            return await upd(f"❌ {html.escape(err or out)}", main_menu())
        await send_awg_files(m.chat.id, svc, name)
        await upd(f"✅ <b>{html.escape(name)}</b> ({svc}) готов"
                  + (f" · удалится через {ttl}" if ttl else ""))
        await m.answer(menu_header(), parse_mode="HTML", reply_markup=main_menu())
    await m.answer(menu_header(), parse_mode="HTML", reply_markup=main_menu())


async def ask_name(c: CallbackQuery, state: FSMContext, **data):
    await state.set_state(Flow.name)
    data["_mid"] = c.message.message_id      # чтобы дальше редактировать это же сообщение
    await state.set_data(data)
    await show(c, "✍️ Введи имя клиента (буквы, цифры, _ , -):",
               kb([[("✖️ Отмена", "menu:main")]]))


# ── все callbacks (через show() — редактирование одного сообщения) ───────────

@dp.callback_query()
async def on_cb(c: CallbackQuery, state: FSMContext):
    if not is_admin(c.message.chat.id):
        return await c.answer("⛔️", show_alert=True)
    d = c.data or ""
    await c.answer()

    if d == "menu:main":
        await state.clear()
        return await show(c, menu_header(), main_menu())

    if d == "info:server":
        return await show(c, stats("server"),
                          kb([[("🔄 Обновить", "info:server")], back()]), stamp=True)

    if d == "clients:menu":
        return await show(c, "👥 <b>Клиенты</b>", clients_menu())

    if d == "clients:list":
        items = []
        for svc in ("awg2", "awg3"):
            items += [(svc, n) for n in awg_names(svc)]
        rows = []
        for svc, n in items[:80]:
            rows.append([(f"{SVC_TAG[svc]} {n}", f"cli:{svc}:{n}")])
        if not rows:
            rows = [[("(клиентов нет)", "clients:menu")]]
        rows.append(back("clients:menu"))
        _l2, _l3 = layers_available()
        legend = "Выбери клиента:"
        if _l2 and _l3:
            legend += "\n🔒² AmneziaWG 2.0   🔒³ AmneziaWG 3.0"
        return await show(c, legend, kb(rows))

    if d.startswith("cli:"):
        _, svc, name = d.split(":", 2)
        return await show(c, f"👤 <b>{html.escape(name)}</b>\n{SVC_TITLE.get(svc, svc)}",
                          client_menu(svc, name))

    if d.startswith("clinfo:"):
        _, svc, name = d.split(":", 2)
        # имя уникально внутри слоя: одинаковые имена в 2.0 и 3.0 — норма,
        # поэтому статистику всегда просим с указанием слоя
        return await show(c, stats("client", name, svc),
                          kb([[("🔄 Обновить", f"clinfo:{svc}:{name}")],
                              [("⬅️ Назад", f"cli:{svc}:{name}")]]), stamp=True)

    if d.startswith("cldl:"):
        _, svc, name = d.split(":", 2)
        await show(c, f"📥 Отправляю конфиг <b>{html.escape(name)}</b>…",
                   kb([[("⬅️ Назад", f"cli:{svc}:{name}")]]))
        await send_awg_files(c.message.chat.id, svc, name)
        return await c.message.answer(menu_header(), parse_mode="HTML",
                                      reply_markup=main_menu())

    if d.startswith("cldel:"):
        _, svc, name = d.split(":", 2)
        return await show(c, f"🗑 Удалить <b>{html.escape(name)}</b> ({SVC_TITLE.get(svc, svc)})?\n"
                          "<i>Клиент потеряет доступ сразу.</i>",
                          kb([[("❌ Удалить", f"cldelok:{svc}:{name}")],
                              [("⬅️ Отмена", f"cli:{svc}:{name}")]]))

    if d.startswith("cldelok:"):
        _, svc, name = d.split(":", 2)
        rc, out, err = run([CLIENT_SH, "del", name, svc])
        txt = (f"🗑 Удалён: {html.escape(name)}" if rc == 0
               else f"❌ {html.escape(err or out)[:500]}")
        return await show(c, txt, kb([[("⬅️ К списку", "clients:list")], back()]))

    if d == "awg:menu":
        _l2, _l3 = layers_available()
        if _l2 and _l3:
            return await show(c, "Версия протокола:\n"
                                 "<i>3.0 — header protection, content padding и"
                                 " рандомные тайминги; нужны свежие клиенты.\n"
                                 "2.0 — работает с любыми, включая старые.</i>",
                              kb([[("AmneziaWG 2.0", "awgsvc:awg2")],
                                  [("AmneziaWG 3.0", "awgsvc:awg3")],
                                  back("clients:menu")]))
        return await ask_name(c, state, kind="awg", svc=("awg3" if _l3 else "awg2"))

    if d.startswith("awgsvc:"):
        return await ask_name(c, state, kind="awg", svc=d.split(":", 1)[1])

    if d == "temp:menu":
        _l2, _l3 = layers_available()
        rows = []
        if _l2:
            rows.append([("🔒² AmneziaWG 2.0", "temptype:awg2")])
        if _l3:
            rows.append([("🔒³ AmneziaWG 3.0", "temptype:awg3")])
        rows.append(back("clients:menu"))
        return await show(c, "Временный клиент — слой:", kb(rows))

    if d.startswith("temptype:"):
        svc = d.split(":", 1)[1]
        return await show(c, "Время жизни (авто-удаление):", kb([
            [("1 час", f"tempad:{svc}:1h"), ("6 часов", f"tempad:{svc}:6h")],
            [("1 день", f"tempad:{svc}:1d"), ("7 дней", f"tempad:{svc}:7d")],
            [("30 дней", f"tempad:{svc}:30d")], back("temp:menu")]))

    if d.startswith("tempad:"):
        _, svc, ttl = d.split(":")
        return await ask_name(c, state, kind="temp_awg", svc=svc, ttl=ttl)

    if d == "upd:menu":
        return await show(c, "🔄 <b>Обновление</b>", upd_menu())

    if d == "upd:check":
        await show(c, "🔎 Сверяю версии с апстримом…", kb([back("upd:menu")]))
        rc, out, err = await asyncio.get_event_loop().run_in_executor(
            None, lambda: run(["/opt/awg3/awg-upstream-check.sh"], timeout=90))
        body = html.escape((out or err or "").strip()[-3000:]) or "(пусто)"
        head = ("🔎 <b>Проверка обновлений</b>\n"
                + ("Есть что обновить — кнопка «Обновить код сервера»."
                   if rc == 10 else "Всё актуально.")
                + "\n\n")
        return await show(c, head + f"<pre>{body}</pre>", kb([
            [("🧬 Обновить код сервера", "upd:awg")], back("upd:menu")]))

    if d == "upd:awg":
        return await show(c, "🧬 <b>Обновление кода сервера</b>\n\n"
                          "Подтянет свежий код и бота с GitHub. Обфускация, "
                          "порты и клиенты не меняются. В конце <b>бот "
                          "перезапустится</b> — итог пришлю после рестарта.",
                          kb([[("✅ Обновить", "updawg:go")], back("upd:menu")]))
    if d == "updawg:go":
        logf = f"{LOG_DIR}/az-awg-update.log"
        write_status_flag(awg_upd="running", awg_reported=False)
        marker_ok = f"python3 - <<'PYEOF'\nimport json\ns = {{}}\ntry: s = json.load(open('{STATUS_FILE}'))\nexcept Exception: pass\ns['awg_upd'] = 'ok'\njson.dump(s, open('{STATUS_FILE}', 'w'))\nPYEOF"
        marker_fail = marker_ok.replace("'ok'", "'fail'")
        script = (f"if curl -fsSL {INSTALL_SH_URL} | bash -s -- --update; "
                  f"then {marker_ok}\nelse {marker_fail}\nfi")
        rc, _, err = start_bg_unit("az-awg-update", ["bash", "-c", script], logf)
        if rc != 0:
            return await show(c, f"❌ {html.escape(err)[:400]}", kb([back("upd:menu")]))
        return await watch_unit(c, "az-awg-update", logf, "🧬 <b>Обновление кода…</b>",
                                "Если бот перезапустился — итог придёт отдельным сообщением.")

    # ── перенастройка обфускации кнопками (порты и клиентские ключи не меняются)
    #    reconf:*  — слой 2.0, reconf3:* — слой 3.0. Шаги и вид меню одинаковые.
    if d == "reconf:preset":
        _l2, _l3 = layers_available()
        if _l3 and _l2:
            # оба слоя: сперва спрашиваем, какому менять профиль
            return await show(c, "🛠 <b>Перенастройка обфускации</b>\nКакой слой:",
                              kb([[("AmneziaWG 2.0", "reconf:preset:2")],
                                  [("AmneziaWG 3.0", "reconf3:preset")],
                                  back("upd:menu")]))
        if _l3 and not _l2:
            d = "reconf3:preset"
    if d in ("reconf:preset", "reconf:preset:2", "reconf3:preset"):
        p = "reconf3" if d.startswith("reconf3") else "reconf"
        ttl = " 3.0" if p == "reconf3" else ""
        # Для слоя 3.0 «поменьше шума» значит не то, что для 2.0: router и low
        # объявлены с header_protection=False, content_padding=None и
        # timings=False. Выбрав их, владелец получает слой 3.0 без единого
        # признака 3.0 — и потом ищет поломку там, где её нет.
        hint = ("\n\n⚠️ <b>router</b> и <b>low</b> — без header protection, "
                "паддинга и таймингов: слой 3.0 на них работает как 2.0.\n"
                "Полный набор 3.0 начинается с <b>medium</b>." if p == "reconf3" else "")
        return await show(c, f"🛠 <b>Перенастройка обфускации{ttl}</b>\n"
                          f"Интенсивность:{hint}",
                          kb([[("router", f"{p}:p:router"), ("low", f"{p}:p:low")],
                              [("medium", f"{p}:p:medium"), ("high", f"{p}:p:high")],
                              [("paranoid", f"{p}:p:paranoid")], back("obf:menu")]))
    if d.startswith("reconf:p:") or d.startswith("reconf3:p:"):
        p, _, preset = d.split(":", 2)
        return await show(c, f"Пресет <b>{preset}</b>. Мимикрия:",
                          kb([[("авто", f"{p}:t:{preset}:auto"),
                               ("quic", f"{p}:t:{preset}:quic"),
                               ("tls", f"{p}:t:{preset}:tls")],
                              [("web", f"{p}:t:{preset}:web"),
                               ("voip", f"{p}:t:{preset}:voip"),
                               ("dns", f"{p}:t:{preset}:dns")],
                              [("mixed", f"{p}:t:{preset}:mixed")],
                              back(f"{p}:preset")]))
    if d.startswith("reconf:t:") or d.startswith("reconf3:t:"):
        # Шаг подтверждения. Раньше выбор шаблона применял профиль СРАЗУ, и одно
        # случайное нажатие отключало всех клиентов слоя без единого вопроса.
        p, _, preset, tpl = d.split(":", 3)
        v3 = p == "reconf3"
        ver, other = ("3.0", "2.0") if v3 else ("2.0", "3.0")
        n = layer_client_count(v3)
        weak = ("\n\n⚠️ Пресет <b>{}</b> объявлен без header protection: слой 3.0 "
                "на нём обфусцирует ровно как 2.0.".format(preset)
                if v3 and preset in OBF_WEAK_FOR_V3 else "")
        return await show(
            c,
            f"⚠️ <b>Смена профиля обфускации — слой {ver}</b>\n"
            f"Новый профиль: <b>{preset}</b> / {tpl}{weak}\n\n"
            f"Параметры обфускации обязаны совпадать на сервере и у клиента, "
            f"поэтому <b>все выданные конфиги слоя {ver} перестанут работать</b>.\n"
            f"• затронуто клиентов: <b>{n}</b>\n"
            f"• конфиги пересоздадутся сами, но каждому придётся заново скачать "
            f"свой (Клиенты → имя → Скачать конфиг)\n"
            f"• туннель слоя {ver} на время операции разорвётся\n"
            f"• слой {other}, порты и ключи не затрагиваются",
            kb([[("✅ Да, сменить профиль", f"{p}:go:{preset}:{tpl}")],
                back(f"{p}:preset")]))

    if d.startswith("reconf:go:") or d.startswith("reconf3:go:"):
        p, _, preset, tpl = d.split(":", 3)
        v3 = p == "reconf3"
        ver = "3.0" if v3 else "2.0"
        # Операция долгая: смена профиля перезапускает интерфейс, а regen-all
        # на сотне клиентов идёт минутами. В обработчике callback её держать
        # нельзя — Telegram оборвёт запрос, а бот всё это время глухой.
        # Юнит заодно служит замком: второй админ получит отказ, а не гонку.
        unit = "awg-obf-reconf"
        logf = f"{LOG_DIR}/awg-obf-reconf.log"
        rc, _, err = start_bg_unit(unit, obf_apply_cmd(v3, preset, tpl), logf)
        if rc != 0:
            return await show(c, f"❌ {html.escape(err)[:400]}", kb([back("obf:menu")]))
        await watch_unit(c, unit, logf, f"🛠 <b>Меняю профиль {ver} на {preset}/{tpl}…</b>",
                         "", back_cb="obf:menu")
        tail = log_tail(logf, lines=200, width=100000)
        if "AWG_OBF_RESULT=ok" in tail:
            note = (f"✅ Профиль <b>{preset}/{tpl}</b> ({ver}) применён, конфиги "
                    f"клиентов пересозданы.\n⚠️ Каждому клиенту слоя {ver} нужно "
                    f"заново скачать и импортировать конфиг.\nПорты и ключи не менялись.")
            if "НЕ доехали" in tail:
                note = (f"⚠️ Профиль <b>{preset}/{tpl}</b> записан, но параметры 3.0 "
                        f"не приняты демоном — туннель работает как 2.0.\n"
                        f"Лог: {logf}")
        else:
            note = (f"❌ Сменить профиль не удалось. Конфиги клиентов НЕ трогались.\n"
                    f"Лог: {logf}")
        return await show(c, f"🛠 <b>Слой {ver}</b>\n"
                          f"<pre>{html.escape(log_tail(logf))}</pre>\n\n{note}",
                          kb([back("obf:menu")]), stamp=True)

    if d in ("doctor:run", "doctor:deep", "doctor:selftest"):
        deep = d == "doctor:deep"
        if d == "doctor:selftest":
            await show(c, "🩺 Проверяю выдаваемые конфиги…", kb([back()]))
            rc, out, err = run([PY, "/opt/awg3/awg-selftest.py", "--all"],
                               timeout=120)
            body = render_selftest(out or err)
        else:
            await show(c, "🩺 Проверяю связность…" +
                       ("\n<i>глубокая проверка поднимает клиента в namespace, "
                        "это до минуты</i>" if deep else ""), kb([back()]))
            rc, out, err = run(["/usr/local/bin/awg-doctor", "--json"]
                               + (["--deep"] if deep else []), timeout=240)
            body = render_doctor(out, err)
        rows = [[("🔄 Ещё раз", d)]]
        if d != "doctor:deep":
            rows.append([("🔬 Глубокая проверка", "doctor:deep")])
        if d != "doctor:selftest":
            rows.append([("📄 Проверить конфиги клиентов", "doctor:selftest")])
        rows.append(back())
        return await show(c, body, kb(rows), stamp=True)

    if d == "obf:menu":
        # у слоёв 2.0 и 3.0 отдельные профили (obfuscation.env / obfuscation3.env):
        # разные интерфейсы, разные датапасы. Если стоят оба — показываем оба ряда.
        _l2, _l3 = layers_available()
        # «Сменить» раньше вело на obf:regen, который пресет НЕ меняет — он
        # лишь перевыпускает сигнатуры внутри прежнего пресета. Смена пресета
        # жила в меню обновлений, где её никто не искал.
        rows = []
        if _l2:
            rows.append([("👁 Показать 2.0", "obf:show"), ("🎲 Новые сигнатуры 2.0", "obf:regen")]
                        if _l3 else [("👁 Показать", "obf:show"),
                                     ("🎲 Новые сигнатуры", "obf:regen")])
        if _l3:
            rows.append([("👁 Показать 3.0", "obf:show:3"),
                         ("🎲 Новые сигнатуры 3.0", "obf:regen:3")])
        rows.append([("🛠 Сменить пресет", "reconf:preset")])
        rows.append(back())
        return await show(c, "🛡 Обфускация:", kb(rows))
    if d in ("obf:show", "obf:show:3"):
        v3 = d.endswith(":3")
        rc, out, err = run([OBF_SH] + (["--v3"] if v3 else []) + ["--show"], env=obf_env())
        head = "🛡 <b>AmneziaWG 3.0</b>\n" if v3 else ""
        return await show(c, f"{head}<code>{html.escape((out or err)[:3500])}</code>",
                          kb([back("obf:menu")]))
    if d in ("obf:regen", "obf:regen:3"):
        v3 = d.endswith(":3")
        ver = "3.0" if v3 else "2.0"
        await show(c, f"⏳ Перегенерация профиля {ver}…", kb([back("obf:menu")]))
        rc, out, err = run([OBF_SH] + (["--v3"] if v3 else []) + ["--regenerate"],
                           timeout=120, env=obf_env())
        if rc == 0:
            run([CLIENT_SH, "regen-all"], timeout=180)
            return await show(c, f"✅ Новый профиль {ver} применён, конфиги пересозданы.\n"
                              "Клиентам нужно переимпортировать конфиги.", kb([back("obf:menu")]))
        return await show(c, f"❌ {html.escape(err or out)[:800]}", kb([back("obf:menu")]))

    if d == "backup:run":
        await show(c, "💾 Создаю бэкап…", kb([back()]))
        rc, out, err = run([BACKUP_SH, "backup"], timeout=300)
        path = out.splitlines()[-1].strip() if out else ""
        if rc == 0 and os.path.exists(path):
            await bot.send_document(c.message.chat.id, FSInputFile(path, filename=os.path.basename(path)),
                                    caption="✅ Бэкап (OpenVPN + AmneziaWG + конфиги + статистика)")
            return await show(c, "✅ Бэкап отправлен.", kb([back()]))
        return await show(c, f"❌ {html.escape(err or out)[:800]}", kb([back()]))

    if d == "restore:ask":
        _pending_restore.add(c.message.chat.id)
        return await show(c, "♻️ Пришли файл бэкапа (.tar.gz) следующим сообщением.",
                          kb([[("✖️ Отмена", "menu:main")]]))


# ── приём файла бэкапа ───────────────────────────────────────────────────────

@dp.message(F.document)
async def on_document(m: Message):
    if not is_admin(m.chat.id) or m.chat.id not in _pending_restore:
        return
    fn = (m.document.file_name or "").lower()
    if not fn.endswith((".tar.gz", ".tgz")):
        return await m.answer("Нужен .tar.gz от «Бэкап».")
    _pending_restore.discard(m.chat.id)
    dst = f"/tmp/awg-restore-{m.chat.id}.tar.gz"
    f = await bot.get_file(m.document.file_id)
    await bot.download_file(f.file_path, dst)
    note = await m.answer("♻️ Восстанавливаю и перезапускаю сервисы…")
    rc, out, err = run([BACKUP_SH, "restore", dst], timeout=300)
    if os.path.exists(dst):
        os.remove(dst)
    await note.edit_text("✅ Восстановлено." if rc == 0 else f"❌ {html.escape(err or out)[:800]}",
                         parse_mode="HTML")
    await m.answer(menu_header(), parse_mode="HTML", reply_markup=main_menu())


async def report_pending():
    """После рестарта бота (перезагрузка сервера / обновление слоя) — отчитаться
    о завершившихся фоновых операциях. Флаг reported ставится ТОЛЬКО после
    успешной отправки: сразу после ребута сеть может быть не готова, поэтому
    ждём и повторяем — иначе отчёт потеряется навсегда."""
    st = read_status()
    # (сообщение, каким флагом пометить после успешной отправки)
    jobs = []
    if st.get("awg_upd") == "ok" and not st.get("awg_reported"):
        jobs.append(("✅ <b>Код сервера обновлён</b>, бот перезапущен. "
                     "Клиенты и обфускация не менялись.",
                     dict(awg_reported=True, awg_upd=None)))
    elif st.get("awg_upd") == "fail" and not st.get("awg_reported"):
        jobs.append(("❌ <b>Обновление кода сервера не удалось.</b> "
                     "Лог: /var/log/az-awg-update.log",
                     dict(awg_reported=True, awg_upd=None)))
    if not jobs:
        return
    for text, flag in jobs:
        sent = False
        for attempt in range(30):                 # до ~5 минут ожидания сети
            for admin in ADMINS:
                try:
                    await bot.send_message(admin, text, parse_mode="HTML")
                    sent = True
                except Exception:  # noqa: BLE001
                    pass
            if sent:
                write_status_flag(**flag)          # помечаем ТОЛЬКО после отправки
                break
            await asyncio.sleep(10)


async def main():
    from aiogram.types import BotCommand
    await bot.set_my_commands([BotCommand(command="start", description="Меню")])
    print(f"AmneziaWG bot up. Admins: {sorted(ADMINS)}")
    # в фоне: ретраи ожидания сети не должны задерживать старт polling
    asyncio.create_task(report_pending())
    await dp.start_polling(bot)


if __name__ == "__main__":
    asyncio.run(main())
