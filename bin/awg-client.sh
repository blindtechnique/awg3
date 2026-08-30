#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# awg-client.sh — клиенты AmneziaWG.
#
#   awg-client add  <имя> [awg2|awg3] [--ttl 2h]   создать (conf + QR + vpn://)
#   awg-client del  <имя> [awg2|awg3]              удалить
#   awg-client list [awg2|awg3]                    список
#   awg-client regen-all                           пересобрать конфиги под
#                                                  текущий профиль обфускации
#   awg-client expire-check                        удалить просроченные временные
#
# Сервис = слой: awg2 — kernel-датапас (2.0), awg3 — userspace (3.0). У каждого
# своя подсеть, свой порт и свой профиль обфускации; параметры обфускации у
# сервера и клиента обязаны совпадать, иначе handshake невозможен.
set -euo pipefail

AWG_DIR=/etc/amnezia/amneziawg
DEST=/opt/awg3
SERVICES="$AWG_DIR/services.env"
CLIENT_DIR="$DEST/clients"
EXPORT="$DEST/awg-export.py"
EXPIRY_FILE="$DEST/expiry.tsv"
# Экспортёру нужен segno для QR — он ставится в venv, а не в системный python.
# Если venv есть, работаем им, иначе откатываемся на системный интерпретатор.
PY="$DEST/venv/bin/python"
[ -x "$PY" ] || PY=python3

log() { printf '\033[1;36m[awg-client]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[awg-client]\033[0m %s\n' "$*" >&2; }
die() { err "$*"; exit 1; }

[ -f "$SERVICES" ] || die "нет $SERVICES — сначала установка"

default_service() {
    # shellcheck disable=SC1090
    . "$SERVICES"
    [ "${LAYER2:-0}" = 1 ] && { echo awg2; return 0; }
    echo awg3
}

# ── сервис → интерфейс, подсеть, порт, слой ──────────────────────────────────
resolve_service() {
    local svc="${1:-}"
    # shellcheck disable=SC1090
    . "$SERVICES"
    [ -n "$svc" ] || svc="$(default_service)"
    LAYER=2
    case "$svc" in
        awg2|2)
            [ "${LAYER2:-0}" = 1 ] || die "слой 2.0 не установлен"
            SVC=awg2; IFACE="${IFACE2:-awg2}"; SUBNET="${SUBNET2:-10.29.79}"
            PORT="${PORT2:-0}"; MTU="${MTU2:-1420}"; LAYER=2 ;;
        awg3|3)
            [ "${LAYER3:-0}" = 1 ] || die "слой 3.0 не установлен"
            SVC=awg3; IFACE="${IFACE3:-awg3}"; SUBNET="${SUBNET3:-10.29.80}"
            PORT="${PORT3:-0}"; MTU="${MTU3:-1380}"; LAYER=3 ;;
        *) die "неизвестный сервис '$svc' (awg2|awg3)" ;;
    esac
    SERVER_CONF="$AWG_DIR/${IFACE}.conf"
    [ -f "$SERVER_CONF" ] || die "нет серверного конфига $SERVER_CONF"
    return 0
}

# ── профиль обфускации своего слоя ───────────────────────────────────────────
load_obfuscation() {
    local keys="Jc Jmin Jmax S1 S2 S3 S4 H1 H2 H3 H4 I1 I2 I3 I4 I5"
    # STATE_ENV задаём явно в обеих ветках: regen-all перебирает оба слоя в
    # одном процессе, и «залипшее» значение указало бы на чужой профиль
    STATE_ENV="$AWG_DIR/obfuscation.env"
    if [ "${LAYER:-2}" = 3 ]; then
        STATE_ENV="$AWG_DIR/obfuscation3.env"
        keys="$keys HeaderProtectionKey ContentPaddingAddition RekeyAfterTime"
        keys="$keys RekeyTimeout RejectAfterTime KeepaliveTimeout MaxHandshakeAttempts"
    fi
    [ -f "$STATE_ENV" ] || die "нет $STATE_ENV — сначала awg-obfuscation"
    # shellcheck disable=SC1090
    . "$STATE_ENV"
    AWG_OBFUSCATION=""
    local k v val
    for k in $keys; do
        v="AWG_${k}"; val="${!v:-}"
        [ -n "$val" ] && AWG_OBFUSCATION+="${k} = ${val}"$'\n'
    done
    AWG_OBFUSCATION="${AWG_OBFUSCATION%$'\n'}"
    return 0
}

server_pubkey() {
    # cut -d= -f2- сохраняет хвостовой '=' base64-ключа (awk -F' *= *' его срезал бы)
    # Читаем отдельно, а не одной трубой в awg pubkey: под pipefail grep без
    # совпадения отдаёт 1, и вся команда умирала молча — без единой строки о
    # том, что в серверном конфиге нет ключа. Пустой ключ здесь означает
    # ненастроенный сервер, и сказать это надо вслух.
    local priv
    priv="$(grep '^PrivateKey' "$SERVER_CONF" | head -1 | cut -d= -f2- | tr -d ' \t' || true)"
    [ -n "$priv" ] || die "в $SERVER_CONF нет PrivateKey — сервер не настроен"
    printf '%s' "$priv" | awg pubkey
}

next_ip() {
    local used i
    used="$(grep -oE "AllowedIPs = ${SUBNET//./\\.}\.[0-9]+" "$SERVER_CONF" | grep -oE '[0-9]+$' || true)"
    for i in $(seq 2 254); do
        # Без трубы: `echo | grep -q` под pipefail отдаёт 141 при совпадении в
        # начале списка, и занятый адрес выдавался бы как свободный — двум
        # клиентам достался бы один IP. В az-awg2 это уже исправлено.
        case $'\n'"$used"$'\n' in
            *$'\n'"$i"$'\n'*) ;;              # занят — берём следующий
            *) echo "${SUBNET}.${i}"; return 0 ;;
        esac
    done
    die "свободные адреса в ${SUBNET}.0/24 закончились"
}

ttl_seconds() {
    local t="$1" n unit
    n="${t%[smhd]}"; unit="${t##*[0-9]}"
    case "$unit" in
        s) echo "$n" ;; m) echo $((n*60)) ;; h) echo $((n*3600)) ;;
        d) echo $((n*86400)) ;; *) echo "" ;;
    esac
}

# ── создать клиента ──────────────────────────────────────────────────────────
add_client() {
    local name="$1" svc="${2:-}" ttl="${3:-}"
    resolve_service "$svc"; load_obfuscation
    local outdir="${CLIENT_DIR}/${SVC}"; mkdir -p "$outdir"
    local conf="${outdir}/${SVC}-${name}-am.conf"
    [ -f "$conf" ] && die "клиент '$name' ($SVC) уже существует"

    local cpriv cpub cpsk cip host dns
    cpriv="$(awg genkey)"; cpub="$(printf '%s' "$cpriv" | awg pubkey)"
    cpsk="$(awg genpsk)"; cip="$(next_ip)"
    host="${ENDPOINT:-}"
    [ -n "$host" ] || host="$(curl -4 -fsS --max-time 10 https://api.ipify.org 2>/dev/null || true)"
    dns="${DNS:-1.1.1.1, 8.8.8.8}"

    # Ключ сервера берём ДО рендера, обычным присваиванием: die внутри $( ) в
    # heredoc убивает только подоболочку — cat дописал бы «PublicKey = »
    # пустым, и клиент получил бы заведомо нерабочий профиль со словом
    # «создан». Здесь отказ виден вызывающему.
    # `|| die` на самом присваивании: без него отказ `awg pubkey` (в отличие от
    # отсутствия ключа, которое ловит сама server_pubkey) убивал бы add_client
    # молча, и проверка на пустоту ниже стала бы недостижимой. Измерено:
    # plain-присваивание с упавшей подстановкой под set -e роняет скрипт.
    local spub
    spub="$(server_pubkey)" || die "не удалось получить публичный ключ сервера — клиент не создан"
    [ -n "$spub" ] || die "публичный ключ сервера пуст — клиент не создан"
    umask 077
    cat > "$conf" <<EOF
[Interface]
PrivateKey = ${cpriv}
Address = ${cip}/32
DNS = ${dns}
MTU = ${MTU}
${AWG_OBFUSCATION}

[Peer]
PublicKey = ${spub}
PresharedKey = ${cpsk}
Endpoint = ${host}:${PORT}
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 15
EOF
    chmod 600 "$conf"

    # peer на сервере: в рантайме и в конфиге (чтобы пережил перезапуск)
    awg set "$IFACE" peer "$cpub" preshared-key <(printf '%s' "$cpsk") \
        allowed-ips "${cip}/32" 2>/dev/null || \
        log "интерфейс не поднят — peer записан только в конфиг"
    cat >> "$SERVER_CONF" <<EOF

[Peer]
# ${name}
PublicKey = ${cpub}
PresharedKey = ${cpsk}
AllowedIPs = ${cip}/32
EOF

    # QR (сырой conf) + ссылка vpn:// + QR ссылки
    # stderr НЕ глушим: экспортёр объясняет там, почему не собрался QR —
    # «не влезает в QR» и «нет segno/qrcode» лечатся по-разному, а с 2>&1
    # обе причины выглядели одинаково молча.
    "$PY" "$EXPORT" "$conf" --name "${SVC}-${name}" --outdir "$outdir" --all >/dev/null || \
        log "экспортёр отработал с замечаниями (см. выше) — .conf на месте"

    local note=""
    if [ -n "$ttl" ]; then
        local secs; secs="$(ttl_seconds "$ttl")"
        if [ -n "$secs" ]; then
            local when=$(( $(date +%s) + secs ))
            mkdir -p "$(dirname "$EXPIRY_FILE")"
            printf '%s\t%s\t%s\n' "$name" "$SVC" "$when" >> "$EXPIRY_FILE"
            note=" · до $(date -d "@$when" '+%Y-%m-%d %H:%M')"
        else
            log "TTL '$ttl' не распознан (примеры: 30m, 2h, 7d) — клиент бессрочный"
        fi
    fi

    log "клиент '$name' ($SVC)${note} создан:"
    log "  conf  : $conf"
    # Путь печатаем по факту наличия файла: QR может не собраться (конфиг не
    # влезает либо нет segno/qrcode), и обещание несуществующего файла отправляет
    # владельца искать его на диске вместо чтения предупреждения выше.
    if [ -f "${outdir}/${SVC}-${name}.png" ]; then
        log "  QR    : ${outdir}/${SVC}-${name}.png"
    else
        log "  QR    : (не создан — см. предупреждение экспортёра выше)"
    fi
    if [ -f "${outdir}/${SVC}-${name}.vpn" ]; then
        log "  vpn://: ${outdir}/${SVC}-${name}.vpn"
    fi
    echo "$conf"
}

# ── удалить клиента ──────────────────────────────────────────────────────────
del_client() {
    local name="$1" svc="${2:-}"
    resolve_service "$svc"
    local outdir="${CLIENT_DIR}/${SVC}"
    local conf="${outdir}/${SVC}-${name}-am.conf"
    [ -f "$conf" ] || die "клиент '$name' ($SVC) не найден"
    local cpriv cpub
    # `|| true` обязателен: под pipefail grep без совпадения отдаёт 1, и
    # удаление умирало без единой строки вывода. В az-awg2 уже исправлено.
    cpriv="$(grep '^PrivateKey' "$conf" | head -1 | cut -d= -f2- | tr -d ' \t' || true)"
    [ -n "$cpriv" ] || die "в конфиге '$conf' нет PrivateKey — по ключу удалять нечего"
    # Проверять здесь обязательно, и вот почему. expire_check зовёт del_client
    # левым операндом ||, а в таком вызове errexit подавлен на ВСЁ тело
    # функции: отказ `awg pubkey` не остановил бы удаление, а оставил бы cpub
    # пустым. Фильтр ниже ищет вхождение подстроки, и пустая входит в любой
    # блок — серверный конфиг вычищался бы целиком, молча, из-под таймера.
    cpub="$(printf '%s' "$cpriv" | awg pubkey)" \
        || die "не удалось вывести публичный ключ клиента из '$conf'"
    [ -n "$cpub" ] || die "пустой публичный ключ клиента ('$conf') — серверный конфиг не трогаю"
    awg set "$IFACE" peer "$cpub" remove 2>/dev/null || true
    python3 - "$SERVER_CONF" "$cpub" <<'PY'
import sys
path, pub = sys.argv[1], sys.argv[2]
# Пустой ключ сюда попасть уже не может, но цена ошибки — стёртый серверный
# конфиг, поэтому проверяем ещё раз: пустая подстрока входит в любой блок.
if not pub:
    sys.exit("пустой PublicKey — фильтр совпал бы со всем файлом")
blocks, cur = [], []
for line in open(path, encoding="utf-8").read().splitlines():
    if line.strip().startswith("[Peer]"):
        blocks.append(cur); cur = [line]
    else:
        cur.append(line)
blocks.append(cur)
keep = [b for b in blocks if pub not in "\n".join(b)]
open(path, "w", encoding="utf-8").write(
    "\n".join("\n".join(b) for b in keep).rstrip() + "\n")
PY
    rm -f "$conf" "${outdir}/${SVC}-${name}"*.png "${outdir}/${SVC}-${name}.vpn"
    if [ -f "$EXPIRY_FILE" ]; then
        grep -v -P "^${name}\t${SVC}\t" "$EXPIRY_FILE" > "${EXPIRY_FILE}.tmp" 2>/dev/null || true
        mv -f "${EXPIRY_FILE}.tmp" "$EXPIRY_FILE" 2>/dev/null || true
    fi
    log "клиент '$name' ($SVC) удалён"
    return 0
}

list_clients() {
    local svc="${1:-}"
    resolve_service "$svc"
    ls -1 "${CLIENT_DIR}/${SVC}"/*-am.conf 2>/dev/null \
        | sed "s#.*/${SVC}-##;s/-am.conf//" || true
    return 0
}

# ── пересобрать конфиги под текущий профиль ──────────────────────────────────
regen_all() {
    # сколько конфигов реально изменилось: см. итог в конце функции
    local same=0 changed=0 changed_list="" before after
    # shellcheck disable=SC1090
    . "$SERVICES"
    local svc conf name
    # Ненужные слои отсеиваем ДО resolve_service: она завершается через die(),
    # то есть уронила бы весь regen-all, а не одну итерацию.
    for svc in awg2 awg3; do
        case "$svc" in
            awg2) [ "${LAYER2:-0}" = 1 ] || continue
                  [ -f "$AWG_DIR/obfuscation.env" ] || continue ;;
            awg3) [ "${LAYER3:-0}" = 1 ] || continue
                  [ -f "$AWG_DIR/obfuscation3.env" ] || continue ;;
        esac
        [ -d "${CLIENT_DIR}/${svc}" ] || continue
        resolve_service "$svc"; load_obfuscation
        for conf in "${CLIENT_DIR}/${svc}"/*-am.conf; do
            [ -f "$conf" ] || continue
            name="$(basename "$conf" | sed "s/^${svc}-//;s/-am.conf//")"
            before="$(md5sum "$conf" | cut -d" " -f1)"
            python3 - "$conf" "$AWG_OBFUSCATION" <<'PY'
import sys
path, block = sys.argv[1], sys.argv[2]
txt = open(path, encoding="utf-8").read().splitlines()
obf = {"Jc","Jmin","Jmax","S1","S2","S3","S4","H1","H2","H3","H4","I1","I2","I3","I4","I5",
       "HeaderProtectionKey","ContentPaddingAddition","RekeyAfterTime","RekeyTimeout",
       "RejectAfterTime","KeepaliveTimeout","MaxHandshakeAttempts"}
out, in_iface = [], False
for line in txt:
    key = line.split("=", 1)[0].strip() if "=" in line else ""
    if line.strip().startswith("[Interface]"):
        in_iface = True; out.append(line); continue
    if line.strip().startswith("[Peer]"):
        if in_iface:
            # Хвостовые пустые строки [Interface] убираем ПЕРЕД вставкой:
            # иначе каждый прогон regen-all добавлял бы ещё одну, файл
            # менялся бы без единого содержательного изменения, и владелец
            # думал бы, что клиентам пора раздавать конфиги заново.
            while out and not out[-1].strip():
                out.pop()
            out.append("")
            out.extend(block.splitlines()); out.append("")
        in_iface = False; out.append(line); continue
    if key in obf:
        continue
    out.append(line)
open(path, "w", encoding="utf-8").write("\n".join(out) + "\n")
PY
            after="$(md5sum "$conf" | cut -d" " -f1)"
            "$PY" "$EXPORT" "$conf" --name "${svc}-${name}" \
                --outdir "$(dirname "$conf")" --all >/dev/null \
                || log "  QR не собран для $svc/$name (см. предупреждение выше)"
            if [ "$before" = "$after" ]; then
                same=$((same+1))
            else
                changed=$((changed+1)); changed_list="$changed_list $svc/$name"
                log "изменён: $svc/$name"
            fi
        done
    done
    # Итог важнее перечисления: после обновления слоя нужно знать не «что-то
    # происходило», а придётся ли людям заново импортировать конфиги.
    if [ "$changed" = 0 ]; then
        log "Конфиги клиентов: $same без изменений — переимпорт не нужен"
    else
        log "Конфиги клиентов: $same без изменений, $changed изменено"
        log "   Заново скачать конфиг нужно:$changed_list"
    fi
    return 0
}

# ── временные клиенты ────────────────────────────────────────────────────────
expire_check() {
    [ -f "$EXPIRY_FILE" ] || exit 0
    local now tmp name svc when
    now="$(date +%s)"; tmp="$(mktemp)"
    while IFS=$'\t' read -r name svc when; do
        [ -n "$name" ] || continue
        if [ "$now" -ge "$when" ] 2>/dev/null; then
            log "срок клиента '$name' ($svc) истёк — удаляю"
            # Подоболочка обязательна: die внутри del_client — это exit, и он
            # оборвал бы ВЕСЬ прогон до mv ниже, оставив список просроченных
            # нетронутым, а остальных — неудалёнными.
            ( del_client "$name" "$svc" >/dev/null ) \
                || log "клиента '$name' удалить не удалось — см. ошибку выше"
        else
            printf '%s\t%s\t%s\n' "$name" "$svc" "$when" >> "$tmp"
        fi
    done < "$EXPIRY_FILE"
    mv "$tmp" "$EXPIRY_FILE"
}

case "${1:-}" in
    add)
        [ $# -ge 2 ] || die "укажи имя: add <имя> [awg2|awg3] [--ttl 2h]"
        name="$2"; svc=""; ttl=""
        shift 2
        while [ $# -gt 0 ]; do
            case "$1" in
                --ttl) ttl="$2"; shift 2 ;;
                awg2|awg3|2|3) svc="$1"; shift ;;
                # молчаливое игнорирование незнакомого слова прячет опечатки:
                # запрос на несуществующий слой должен быть ошибкой, а не сюрпризом
                *) die "неизвестный аргумент '$1' (сервисы: awg2|awg3, срок: --ttl 2h)" ;;
            esac
        done
        add_client "$name" "$svc" "$ttl" ;;
    del)
        [ $# -ge 2 ] || die "укажи имя: del <имя> [awg2|awg3]"
        del_client "$2" "${3:-}" ;;
    list)         list_clients "${2:-}" ;;
    regen-all)    regen_all ;;
    expire-check) expire_check ;;
    *) grep '^#' "$0" | sed 's/^# \?//'; exit 0 ;;
esac
