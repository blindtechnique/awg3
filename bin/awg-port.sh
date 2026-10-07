#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# awg-port.sh — показать и сменить UDP-порт слоя.
#
#   awg-port.sh                            # что объявлено и что слушается
#   awg-port.sh show
#   awg-port.sh set <awg2|awg3> <порт|auto> [--force]
#
# ЗАЧЕМ. Порт — ровно то, что блокируют. До появления этой команды сменить его
# было нельзя: установщик закрепляет порт навсегда, а `regen-all` правит только
# строки обфускации и Endpoint не трогает вовсе. Поменять порт руками значило
# переехать сервером, оставив ВСЕ выданные конфиги указывать на прежний:
# клиенты молча перестают соединяться, а доктор показывает «у N из M конфигов
# Endpoint на чужой порт». Такой переезд уже случался — он описан в
# az-awg2/install.sh как разобранный дефект.
#
# ПОСЛЕ СМЕНЫ КЛИЕНТАМ НУЖЕН ПЕРЕИМПОРТ. Иначе смысла нет: порт записан в
# каждом выданном файле, и старый файл после переезда мёртв.
#
# ПОРЯДОК НАМЕРЕННЫЙ: сначала сервер (services.env, <iface>.env, ListenPort,
# перезапуск), потом клиентские файлы. Обрыв между этими половинами оставляет
# состояние, которое доктор ВИДИТ («Endpoint на чужой порт») и которое лечится
# повтором этой же команды: она идемпотентна, повторный запуск с тем же портом
# просто дочищает отставшие конфиги. Обратный порядок оставил бы клиентов с
# новым портом там, где сервер слушает старый, — а это уже никакой проверкой
# не отличить от блокировки UDP.
set -euo pipefail

AWG_DIR=/etc/amnezia/amneziawg
DEST=/opt/awg3
SERVICES="$AWG_DIR/services.env"
CLIENT_DIR="$DEST/clients"
EXPORT="$DEST/awg-export.py"
PY="$DEST/venv/bin/python"
[ -x "$PY" ] || PY=python3

log() { printf '\033[1;36m[awg-port]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[awg-port]\033[0m %s\n' "$*" >&2; }
die() { err "$*"; exit 1; }

# ── замок на состояние слоя ────────────────────────────────────────────────
# Тот же файл и тот же дескриптор, что у awg-client.sh и awg-backup.sh: под
# замком серверные конфиги и каталог клиентов, а мы правим и то, и другое.
# Перезапуск держим ПОД замком сознательно: ни awg-quick, ни awg3@ с его
# awg-datapath.sh этого замка не берут (проверено), поэтому самодедлока нет, а
# отпустить его посреди переезда значило бы дать таймеру выдать клиента с уже
# новым портом, пока конфиги ещё на старом.
AWG_LOCK="${AWG_LOCK:-/run/awg3.lock}"

_lock_open() {
    command -v flock >/dev/null 2>&1 || return 2
    # Фигурные скобки обязательны: `exec 9>файл` с неудачной перенаправкой
    # завершает неинтерактивную оболочку ЦЕЛИКОМ, и `|| return` до неё не
    # доходит.
    { exec 9>"$AWG_LOCK"; } 2>/dev/null || return 3
}
lock_wait() {  # lock_wait <секунд> <что защищаем>
    local o=0
    _lock_open || o=$?
    if [ "$o" != 0 ]; then
        case "$o" in
            2) err "нет flock (пакет util-linux): $2 идёт без защиты от таймеров" ;;
            *) err "не открыть замок $AWG_LOCK: $2 идёт без защиты от таймеров" ;;
        esac
        return 0
    fi
    flock -w "$1" 9 && return 0
    err "$2: за $1 с не удалось взять $AWG_LOCK — идёт другая операция"
    return 1
}

# ── порты ───────────────────────────────────────────────────────────────────
# Поле берём с конца: `ss -lunH` печатает колонку Netid не на всех версиях
# iproute2. Без трубы в проверке — `grep -qx` под pipefail отдаёт 141, когда
# совпадение в начале списка, и ЗАНЯТЫЙ порт объявлялся бы свободным.
busy_ports() { ss -lunH 2>/dev/null | awk '{print $(NF-1)}' | grep -oE '[0-9]+$' | sort -u || true; }
valid_port() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }
port_busy() {
    local busy; busy="$(busy_ports)"
    case $'\n'"$busy"$'\n' in *$'\n'"$1"$'\n'*) return 0 ;; esac
    return 1
}
pick_free_port() {  # pick_free_port <исключить…>
    local extra="$*" busy p
    busy="$(busy_ports; printf '%s\n' $extra; echo 22; echo 53; echo 80; echo 443)"
    for _ in $(seq 1 200); do
        p=$(( 20000 + RANDOM % 40000 ))
        case $'\n'"$busy"$'\n' in
            *$'\n'"$p"$'\n'*) ;;
            *) echo "$p"; return 0 ;;
        esac
    done
    die "не удалось подобрать свободный порт за 200 попыток"
}

resolve_layer() {  # resolve_layer <awg2|awg3>
    [ -f "$SERVICES" ] || die "нет $SERVICES — слой не установлен"
    # shellcheck disable=SC1090
    . "$SERVICES"
    case "${1:-}" in
        awg2|2) LAYER=2; SVC=awg2; PORT_KEY=PORT2
                IFACE="${IFACE2:-awg2}"; PORT_CUR="${PORT2:-0}"; PORT_OTHER="${PORT3:-0}"
                [ "${LAYER2:-0}" = 1 ] || die "слой 2.0 не установлен" ;;
        awg3|3) LAYER=3; SVC=awg3; PORT_KEY=PORT3
                IFACE="${IFACE3:-awg3}"; PORT_CUR="${PORT3:-0}"; PORT_OTHER="${PORT2:-0}"
                [ "${LAYER3:-0}" = 1 ] || die "слой 3.0 не установлен" ;;
        *) die "укажи слой: awg2 или awg3" ;;
    esac
    SERVER_CONF="$AWG_DIR/${IFACE}.conf"
    IFACE_ENV="$AWG_DIR/${IFACE}.env"
    [ -f "$SERVER_CONF" ] || die "нет серверного конфига $SERVER_CONF"
    # Слой 3.0 живёт в своём юните: у него userspace-датапас, а не awg-quick.
    if [ "$LAYER" = 3 ] && [ "${KMOD3:-0}" != 1 ]; then UNIT="awg3@${IFACE}"
    else UNIT="awg-quick@${IFACE}"; fi
}

# Правка одного значения: во временный файл рядом, с сохранением прав, затем
# mv. И ОБЯЗАТЕЛЬНАЯ сверка результата: шаблон, не совпавший ни с одной
# строкой, оставил бы файл прежним, а переезд выглядел бы удавшимся — именно
# так порт и разъезжался с Endpoint в прошлый раз.
set_value() {  # set_value <файл> <sed-выражение> <что должно получиться (grep -E)>
    local f="$1" expr="$2" want="$3" tmp="$1.awgport.tmp"
    sed "$expr" "$f" > "$tmp" || { rm -f "$tmp"; die "не переписать $f"; }
    chmod --reference="$f" "$tmp" 2>/dev/null || chmod 600 "$tmp"
    mv -f "$tmp" "$f" || { rm -f "$tmp"; die "не заменить $f"; }
    grep -qE "$want" "$f" || die "в $f значение не изменилось — шаблон не совпал"
}

show() {
    [ -f "$SERVICES" ] || die "нет $SERVICES — слой не установлен"
    # shellcheck disable=SC1090
    . "$SERVICES"
    local busy; busy="$(busy_ports)"
    printf '%-6s %-10s %-8s %s\n' СЛОЙ ИНТЕРФЕЙС ПОРТ СОСТОЯНИЕ
    local l
    for l in 2 3; do
        local on iface port
        case "$l" in
            2) on="${LAYER2:-0}"; iface="${IFACE2:-awg2}"; port="${PORT2:-0}" ;;
            *) on="${LAYER3:-0}"; iface="${IFACE3:-awg3}"; port="${PORT3:-0}" ;;
        esac
        [ "$on" = 1 ] || continue
        local state="НЕ слушается"
        case $'\n'"$busy"$'\n' in *$'\n'"$port"$'\n'*) state="слушается" ;; esac
        printf '%-6s %-10s %-8s %s\n' "${l}.0" "$iface" "$port" "$state"
    done
    echo
    echo "Сменить:  awg-port set awg3 <порт|auto>"
    echo "После смены каждому клиенту слоя нужно заново скачать конфиг."
}

do_set() {  # do_set <слой> <порт|auto> [--force]
    local want="$2" force=0
    [ "${3:-}" = --force ] && force=1
    resolve_layer "$1"

    if [ "$want" = auto ]; then
        want="$(pick_free_port "$PORT_OTHER" "$PORT_CUR")"
        log "Выбран свободный порт $want"
    fi
    valid_port "$want" || die "порт '$want' недействителен (нужно 1..65535)"
    [ "$want" = "$PORT_OTHER" ] && die "порт $want занят другим слоем — выбери другой"

    if [ "$want" = "$PORT_CUR" ]; then
        log "Слой ${LAYER}.0 уже объявлен на порту $want — проверю только клиентские конфиги"
    elif port_busy "$want" && [ "$force" != 1 ]; then
        err "порт $want уже слушается на сервере."
        err "Если это сам слой в другом сетевом пространстве имён — повтори с --force."
        exit 1
    fi

    lock_wait 60 "смена порта" || die "занято другой операцией — повтори"

    # ── половина первая: сервер ─────────────────────────────────────────────
    if [ "$want" != "$PORT_CUR" ]; then
        set_value "$SERVICES" "s#^${PORT_KEY}=.*#${PORT_KEY}='${want}'#" "^${PORT_KEY}='${want}'$"
        log "services.env: ${PORT_KEY} = $want"
        if [ -f "$IFACE_ENV" ]; then
            set_value "$IFACE_ENV" "s#^PORT=.*#PORT=${want}#" "^PORT=${want}$"
            log "${IFACE}.env: PORT = $want"
        fi
        set_value "$SERVER_CONF" "s#^ListenPort *=.*#ListenPort = ${want}#" "^ListenPort = ${want}$"
        log "${IFACE}.conf: ListenPort = $want"

        if systemctl cat "$UNIT" >/dev/null 2>&1; then
            log "Перезапуск $UNIT"
            if ! systemctl restart "$UNIT"; then
                err "$UNIT не перезапустился: journalctl -u $UNIT"
                err "Порт в файлах уже новый, клиентские конфиги ещё нет."
                err "Починить: подними юнит и повтори эту же команду."
                exit 1
            fi
            # Спрашиваем ядро, а не файл: файл мы только что правили сами.
            local ok=0
            for _ in 1 2 3 4 5; do
                port_busy "$want" && { ok=1; break; }
                sleep 1
            done
            if [ "$ok" = 1 ]; then log "Порт $want слушается"
            else err "порт $want не слушается после перезапуска — клиентские конфиги НЕ тронуты"
                 err "Разберись с $UNIT и повтори команду."
                 exit 1
            fi
        else
            log "юнита $UNIT нет — перезапускать нечего (порт применится при старте)"
        fi
    fi

    # ── половина вторая: выданные конфиги ───────────────────────────────────
    local dir="$CLIENT_DIR/$SVC" conf name ep host n=0 fixed=0 broken=0
    if [ ! -d "$dir" ]; then
        log "клиентов слоя ${LAYER}.0 нет — переимпортировать нечего"
        exit 0
    fi
    for conf in "$dir"/*-am.conf; do
        [ -f "$conf" ] || continue
        n=$((n + 1))
        name="$(basename "$conf")"; name="${name#"$SVC"-}"; name="${name%-am.conf}"
        ep="$(sed -n 's/^Endpoint *= *//p' "$conf" 2>/dev/null | head -1 || true)"
        if [ -z "$ep" ]; then
            err "$name: в конфиге нет Endpoint — пропущен, разберись руками"
            broken=$((broken + 1)); continue
        fi
        # Хост сохраняем как есть: там может быть и домен, и IPv6 в скобках.
        host="${ep%:*}"
        if [ "$ep" = "${host}:${want}" ]; then continue; fi
        set_value "$conf" "s#^Endpoint *=.*#Endpoint = ${host}:${want}#" \
            "^Endpoint = ${host}:${want}$"
        # QR и vpn:// несут тот же Endpoint — без пересборки человек получил бы
        # свежий .conf и картинку со старым портом.
        if ! "$PY" "$EXPORT" "$conf" --name "${SVC}-${name}" --outdir "$dir" --all >/dev/null 2>&1; then
            err "$name: конфиг переписан, а QR и vpn:// пересобрать не удалось"
            broken=$((broken + 1))
        fi
        fixed=$((fixed + 1))
    done

    echo
    log "Слой ${LAYER}.0 переехал на порт $want"
    log "Клиентских конфигов: $n, переписано $fixed"
    if [ "$broken" != 0 ]; then
        err "не доведено до конца: $broken — повтори команду после разбора"
        exit 1
    fi
    if [ "$fixed" != 0 ]; then
        log "ВСЕМ $fixed клиентам нужно заново скачать и импортировать конфиг:"
        log "  старый файл указывает на прежний порт и больше не соединится."
    fi
    exit 0
}

case "${1:-show}" in
    show) show ;;
    set)
        [ $# -ge 3 ] || die "укажи слой и порт: set <awg2|awg3> <порт|auto> [--force]"
        do_set "$2" "$3" "${4:-}" ;;
    # Справка — это шапка файла, а не диапазон строк: жёсткие номера ошибаются
    # молча в обе стороны.
    -h|--help) awk 'NR==1||/^# *SPDX-/{next} /^#/{sub(/^# ?/,"");print;next} {exit}' "$0" ;;
    *) die "неизвестная команда '$1' (show|set)" ;;
esac
