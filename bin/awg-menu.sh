#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# awg-menu.sh — интерактивное меню управления сервером AmneziaWG.
#
# Ставится как /usr/local/bin/awg3, поэтому из-под root достаточно набрать:
#     awg3
#
# Умеет то же, что и Telegram-бот: клиенты, статистика, обфускация, бэкапы,
# диагностика, обновление и полное удаление. Бот при этом не обязателен —
# сервером можно управлять только отсюда.
#
# Имя специально не `awg`: так зовётся утилита из amneziawg-tools, и её нельзя
# перекрывать — на неё опираются и наши скрипты, и awg-quick.
#
# Короткие команды тоже работают:
#     awg3 add ivan awg3     = awg-client add ivan awg3
#     awg3 list              = awg-client list
#     awg3 doctor            = awg-doctor
set -uo pipefail

DEST=/opt/awg3
AWG_DIR=/etc/amnezia/amneziawg
SERVICES="$AWG_DIR/services.env"
CLIENT="$DEST/awg-client.sh"
PY="$DEST/venv/bin/python"
[ -x "$PY" ] || PY=python3

c_hdr=$'\033[1;35m'; c_ok=$'\033[1;32m'; c_no=$'\033[1;31m'
c_dim=$'\033[2m'; c_b=$'\033[1m'; c_x=$'\033[0m'

# Справка не требует ни root, ни установленного сервера: владелец, набравший
# --help, получал отказ вместо справки — сначала про права, потом про
# services.env. Всё остальное меню без того и другого действительно
# бессмысленно, и там проверки остаются.
case "${1:-}" in
    -h|--help|help) ;;
    *)
        [ "$(id -u)" = 0 ] || { echo "Нужны права root." >&2; exit 1; }
        [ -f "$SERVICES" ] || { echo "Сервер не установлен: нет $SERVICES" >&2; exit 1; }
        # shellcheck disable=SC1090
        . "$SERVICES"
        ;;
esac

pause() { printf '\n%sНажми Enter…%s' "$c_dim" "$c_x"; read -r _ || true; }

# Очистка экрана. `clear` есть не везде (нет TERM, урезанный образ) — тогда
# отправляем управляющую последовательность напрямую.
cls() { clear 2>/dev/null || printf '\033[H\033[2J'; }

# Юнит слоя 3.0 зависит от режима: userspace-датапас или общий awg-quick
unit3() {
    if [ "${KMOD3:-0}" = 1 ]; then echo "awg-quick@${IFACE3:-awg3}"
    else echo "awg3@${IFACE3:-awg3}"; fi
}

layers() {  # печатает доступные слои: awg2 awg3
    local out=""
    [ "${LAYER2:-0}" = 1 ] && out="awg2"
    [ "${LAYER3:-0}" = 1 ] && out="$out awg3"
    echo "$out"
}

pick_layer() {  # pick_layer <имя_переменной>
    local __v="$1" avail; avail="$(layers)"
    set -- $avail
    if [ $# -le 1 ]; then printf -v "$__v" '%s' "${1:-awg2}"; return 0; fi
    echo
    echo "  Версия протокола:"
    echo "   1) AmneziaWG 2.0 — работает с любыми клиентами"
    echo "   2) AmneziaWG 3.0 — header protection, нужны свежие клиенты"
    local a; printf '  Выбор [1]: '; read -r a || a=1
    case "${a:-1}" in 2) printf -v "$__v" 'awg3' ;; *) printf -v "$__v" 'awg2' ;; esac
}

# ── экраны ───────────────────────────────────────────────────────────────────
screen_status() {
    cls
    printf '%s═══ Состояние ═══%s\n\n' "$c_hdr" "$c_x"
    printf '  Адрес сервера : %s%s%s\n' "$c_b" "${ENDPOINT:-—}" "$c_x"
    local svc iface port sub unit state n
    for svc in $(layers); do
        case "$svc" in
            awg2) iface="${IFACE2}"; port="${PORT2}"; sub="${SUBNET2}"; unit="awg-quick@${IFACE2}" ;;
            awg3) iface="${IFACE3}"; port="${PORT3}"; sub="${SUBNET3}"; unit="$(unit3)" ;;
        esac
        if systemctl is-active --quiet "$unit"; then state="${c_ok}работает${c_x}"; else state="${c_no}остановлен${c_x}"; fi
        n="$(ls -1 "$DEST/clients/$svc"/*-am.conf 2>/dev/null | wc -l)"
        printf '\n  %sAmneziaWG %s%s  %b\n' "$c_b" "${svc#awg}.0" "$c_x" "$state"
        printf '    интерфейс %s · порт %s · подсеть %s.0/24 · клиентов %s\n' \
            "$iface" "$port" "$sub" "$n"
    done
    echo
    if systemctl is-active --quiet awg-bot 2>/dev/null; then
        printf '  Telegram-бот  : %sработает%s\n' "$c_ok" "$c_x"
    elif [ -f /etc/systemd/system/awg-bot.service ]; then
        printf '  Telegram-бот  : %sостановлен%s\n' "$c_no" "$c_x"
    else
        printf '  Telegram-бот  : не установлен\n'
    fi
    pause
}

screen_info() {
    cls
    printf '%s═══ Информация о сервере ═══%s\n\n' "$c_hdr" "$c_x"
    "$PY" "$DEST/awg_stats.py" server 2>/dev/null | sed 's/<[^>]*>//g' || \
        echo "статистика недоступна"
    pause
}

screen_clients_list() {
    cls
    printf '%s═══ Клиенты ═══%s\n' "$c_hdr" "$c_x"
    local svc n
    for svc in $(layers); do
        printf '\n  %sAmneziaWG %s%s\n' "$c_b" "${svc#awg}.0" "$c_x"
        n=0
        while IFS= read -r name; do
            [ -n "$name" ] || continue
            printf '    • %s\n' "$name"; n=$((n+1))
        done < <("$CLIENT" list "$svc" 2>/dev/null)
        [ "$n" = 0 ] && printf '    %s(пусто)%s\n' "$c_dim" "$c_x"
    done
    pause
}

screen_client_add() {
    cls
    printf '%s═══ Новый клиент ═══%s\n' "$c_hdr" "$c_x"
    local svc name ttl a
    pick_layer svc
    printf '\n  Имя (буквы, цифры, _ , -): '; read -r name || return 0
    [ -n "$name" ] || return 0
    printf '  Временный? Срок вроде 6h или 7d (Enter — бессрочный): '; read -r ttl || ttl=""
    echo
    if [ -n "$ttl" ]; then a="$("$CLIENT" add "$name" "$svc" --ttl "$ttl")"; else a="$("$CLIENT" add "$name" "$svc")"; fi
    local base; base="${a%-am.conf}"
    if [ -f "${base}.vpn" ]; then
        echo
        printf '%sСсылка vpn:// для приложения Amnezia:%s\n' "$c_b" "$c_x"
        cat "${base}.vpn"; echo
    fi
    if command -v qrencode >/dev/null 2>&1 && [ -f "$a" ]; then
        echo
        printf '%sQR-код конфига (сканируй в приложении AmneziaWG):%s\n' "$c_b" "$c_x"
        qrencode -t ANSIUTF8 < "$a"
    fi
    pause
}

screen_client_del() {
    cls
    printf '%s═══ Удалить клиента ═══%s\n' "$c_hdr" "$c_x"
    local svc name a
    pick_layer svc
    echo
    "$CLIENT" list "$svc" | sed 's/^/    • /'
    printf '\n  Имя клиента: '; read -r name || return 0
    [ -n "$name" ] || return 0
    printf '  Удалить «%s»? Клиент потеряет доступ сразу. [y/N]: ' "$name"
    read -r a || a=n
    case "${a:-n}" in y|Y|д|Д) "$CLIENT" del "$name" "$svc" ;; *) echo "  Отменено" ;; esac
    pause
}

screen_client_show() {
    cls
    printf '%s═══ Конфиг клиента ═══%s\n' "$c_hdr" "$c_x"
    local svc name conf base
    pick_layer svc
    echo
    "$CLIENT" list "$svc" | sed 's/^/    • /'
    printf '\n  Имя клиента: '; read -r name || return 0
    [ -n "$name" ] || return 0
    conf="$DEST/clients/$svc/$svc-$name-am.conf"
    [ -f "$conf" ] || { echo "  Не найден: $conf"; pause; return 0; }
    base="${conf%-am.conf}"
    echo
    printf '  Файл : %s\n' "$conf"
    [ -f "${base}.vpn" ] && { printf '\n%sСсылка vpn://%s\n' "$c_b" "$c_x"; cat "${base}.vpn"; echo; }
    if command -v qrencode >/dev/null 2>&1; then
        printf '\n%sQR-код:%s\n' "$c_b" "$c_x"
        qrencode -t ANSIUTF8 < "$conf"
    fi
    pause
}

screen_stats() {
    cls
    printf '%s═══ Статистика ═══%s\n\n' "$c_hdr" "$c_x"
    "$PY" "$DEST/awg_stats.py" poll >/dev/null 2>&1 || true
    "$PY" "$DEST/awg_stats.py" overview 2>/dev/null | sed 's/<[^>]*>//g' || echo "нет данных"
    pause
}

screen_obfuscation() {
    while :; do
        cls
        printf '%s═══ Обфускация ═══%s\n\n' "$c_hdr" "$c_x"
        echo "   1) Показать текущий профиль"
        echo "   2) Перегенерировать (новые сигнатуры, тот же пресет)"
        echo "   3) Сменить пресет и мимикрию"
        echo "   0) Назад"
        local a svc; printf '\n  Выбор: '; read -r a || return 0
        case "$a" in
            1) pick_layer svc; clear
               if [ "$svc" = awg3 ]; then "$DEST/awg-obfuscation.sh" --v3 --show; else "$DEST/awg-obfuscation.sh" --show; fi
               pause ;;
            2) pick_layer svc
               printf '\n  Клиентам понадобятся новые конфиги. Продолжить? [y/N]: '
               local b; read -r b || b=n
               case "${b:-n}" in y|Y|д|Д)
                   if [ "$svc" = awg3 ]; then "$DEST/awg-obfuscation.sh" --v3 --regenerate; else "$DEST/awg-obfuscation.sh" --regenerate; fi
                   "$CLIENT" regen-all ;; *) echo "  Отменено" ;; esac
               pause ;;
            3) pick_layer svc
               echo
               echo "  Пресет: 1) router  2) low  3) medium  4) high  5) paranoid"
               local p pr; printf '  Выбор [3]: '; read -r p || p=3
               case "${p:-3}" in 1) pr=router ;; 2) pr=low ;; 4) pr=high ;; 5) pr=paranoid ;; *) pr=medium ;; esac
               echo "  Мимикрия: 0) авто  1) quic  2) tls  3) web  4) voip  5) dns  6) mixed"
               local m tm; printf '  Выбор [0]: '; read -r m || m=0
               case "${m:-0}" in 1) tm=quic ;; 2) tm=tls ;; 3) tm=web ;; 4) tm=voip ;; 5) tm=dns ;; 6) tm=mixed ;; *) tm="" ;; esac
               echo
               if [ "$svc" = awg3 ]; then
                   "$DEST/awg-obfuscation.sh" --v3 --preset "$pr" ${tm:+--template "$tm"} --apply
               else
                   "$DEST/awg-obfuscation.sh" --preset "$pr" ${tm:+--template "$tm"} --apply
               fi
               "$CLIENT" regen-all
               pause ;;
            0|"") return 0 ;;
        esac
    done
}

screen_backup() {
    cls
    printf '%s═══ Бэкап ═══%s\n\n' "$c_hdr" "$c_x"
    echo "   1) Создать архив"
    echo "   2) Создать зашифрованный архив"
    echo "   3) Восстановить из архива"
    echo "   0) Назад"
    local a f; printf '\n  Выбор: '; read -r a || return 0
    case "$a" in
        1) "$DEST/awg-backup.sh" backup ;;
        2) "$DEST/awg-backup.sh" backup --encrypt ;;
        3) printf '  Путь к архиву: '; read -r f || return 0
           [ -n "$f" ] && "$DEST/awg-backup.sh" restore "$f" ;;
        *) return 0 ;;
    esac
    pause
}

screen_doctor() {
    cls
    printf '%s═══ Диагностика ═══%s\n\n' "$c_hdr" "$c_x"
    echo "   1) Быстрая проверка"
    echo "   2) Глубокая (поднимает тестовый туннель, до минуты)"
    echo "   3) Проверить выдаваемые конфиги"
    echo "   0) Назад"
    local a; printf '\n  Выбор [1]: '; read -r a || a=1
    cls
    case "${a:-1}" in
        1) "$DEST/awg-doctor.sh" ;;
        2) "$DEST/awg-doctor.sh" --deep ;;
        3) "$PY" "$DEST/awg-selftest.py" --all ;;
        *) return 0 ;;
    esac
    pause
}

screen_bot() {
    cls
    printf '%s═══ Telegram-бот ═══%s\n\n' "$c_hdr" "$c_x"
    if [ -f /etc/systemd/system/awg-bot.service ]; then
        systemctl status awg-bot --no-pager -l 2>/dev/null | head -6
        echo
        echo "   1) Перезапустить"
        echo "   2) Показать журнал"
        echo "   3) Сменить токен/админов"
        echo "   4) Удалить бота"
        echo "   0) Назад"
        local a; printf '\n  Выбор: '; read -r a || return 0
        case "$a" in
            1) systemctl restart awg-bot && echo "  перезапущен" ;;
            2) journalctl -u awg-bot -n 40 --no-pager ;;
            3) bash "$DEST/install.sh" --install-bot 2>/dev/null || \
               echo "  запусти: bash <(curl -fsSL $(cat "$DEST/.url" 2>/dev/null)) --install-bot" ;;
            4) bash "$DEST/install.sh" --remove-bot 2>/dev/null || echo "  установщик недоступен" ;;
            *) return 0 ;;
        esac
    else
        echo "  Бот не установлен."
        echo "  Поставить: install.sh --install-bot"
    fi
    pause
}

screen_service() {
    cls
    printf '%s═══ Сервисы ═══%s\n\n' "$c_hdr" "$c_x"
    echo "   1) Перезапустить туннели"
    echo "   2) Журнал слоя 2.0"
    echo "   3) Журнал слоя 3.0"
    echo "   0) Назад"
    local a svc; printf '\n  Выбор: '; read -r a || return 0
    case "$a" in
        1) for svc in $(layers); do
               case "$svc" in
                   awg2) systemctl restart "awg-quick@${IFACE2}" && echo "  2.0 перезапущен" ;;
                   awg3) systemctl restart "$(unit3)" && echo "  3.0 перезапущен" ;;
               esac
           done ;;
        2) journalctl -u "awg-quick@${IFACE2:-awg2}" -n 40 --no-pager ;;
        3) journalctl -u "$(unit3)" -n 40 --no-pager ;;
        *) return 0 ;;
    esac
    pause
}

screen_uninstall() {
    cls
    printf '%s═══ Удаление ═══%s\n\n' "$c_no" "$c_x"
    echo "  Будут удалены сервисы, интерфейсы, правила NAT, ВСЕ клиенты"
    echo "  и ключи сервера, статистика и собранные бинарники."
    echo
    if [ -x "$DEST/install.sh" ]; then
        bash "$DEST/install.sh" --uninstall
    else
        echo "  Установщик не найден рядом. Запусти:"
        echo "  bash <(curl -fsSL https://raw.githubusercontent.com/blindtechnique/awg3/main/install.sh) --uninstall"
        pause
    fi
}

# ── прямые команды: awg add …, awg list, awg doctor ─────────────────────────
if [ $# -gt 0 ]; then
    case "$1" in
        add|del|list|regen-all|expire-check) exec "$CLIENT" "$@" ;;
        doctor) shift; exec "$DEST/awg-doctor.sh" "$@" ;;
        backup) shift; exec "$DEST/awg-backup.sh" backup "$@" ;;
        stats)  exec "$PY" "$DEST/awg_stats.py" overview ;;
        menu)   ;;   # явный вызов меню
        # Справка — это шапка файла, а не диапазон строк: жёсткие номера не
        # знают, где она кончилась, и ошибаются молча в обе стороны.
        -h|--help) awk 'NR==1||/^# *SPDX-/{next} /^#/{sub(/^# ?/,"");print;next} {exit}' "$0"; exit 0 ;;
        *) echo "Неизвестная команда: $1 (без аргументов открывается меню)" >&2; exit 2 ;;
    esac
fi

# ── главное меню ────────────────────────────────────────────────────────────
while :; do
    cls
    ver="2.0"; [ "${LAYER2:-0}" = 1 ] && [ "${LAYER3:-0}" = 1 ] && ver="2.0 + 3.0"
    [ "${LAYER2:-0}" = 0 ] && ver="3.0"
    printf '%s╔══════════════════════════════════════════════╗%s\n' "$c_hdr" "$c_x"
    printf '%s║%s  AmneziaWG %-34s%s║%s\n' "$c_hdr" "$c_x" "$ver" "$c_hdr" "$c_x"
    printf '%s║%s  %-44s%s║%s\n' "$c_hdr" "$c_x" "${ENDPOINT:-—}" "$c_hdr" "$c_x"
    printf '%s╚══════════════════════════════════════════════╝%s\n\n' "$c_hdr" "$c_x"
    echo "   1) Состояние"
    echo "   2) Список клиентов"
    echo "   3) Новый клиент"
    echo "   4) Показать конфиг клиента (QR и ссылка)"
    echo "   5) Удалить клиента"
    echo "   6) Статистика"
    echo "   7) Информация о сервере"
    echo "   8) Обфускация"
    echo "   9) Диагностика"
    echo "  10) Бэкап и восстановление"
    echo "  11) Сервисы и журналы"
    echo "  12) Telegram-бот"
    echo "  13) Удалить AmneziaWG полностью"
    echo "   0) Выход"
    printf '\n  Выбор: '
    read -r choice || exit 0
    case "$choice" in
        1) screen_status ;;
        2) screen_clients_list ;;
        3) screen_client_add ;;
        4) screen_client_show ;;
        5) screen_client_del ;;
        6) screen_stats ;;
        7) screen_info ;;
        8) screen_obfuscation ;;
        9) screen_doctor ;;
        10) screen_backup ;;
        11) screen_service ;;
        12) screen_bot ;;
        13) screen_uninstall ;;
        0|q|"") clear; exit 0 ;;
        *) ;;
    esac
done
