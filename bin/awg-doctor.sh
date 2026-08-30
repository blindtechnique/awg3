#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# awg-doctor.sh — самопроверка сервера AmneziaWG.
#
#   awg-doctor            быстрые проверки (секунды)
#   awg-doctor --deep     + реальный клиент в network namespace и handshake
#   awg-doctor --json     машинно-читаемо (для бота и мониторинга)
#
# Обычная беда — «клиент не подключается», а причина где-то между профилем
# обфускации, портом, NAT и MTU. Скрипт проходит цепочку сверху вниз и
# показывает, на каком звене рвётся.
#
# --deep поднимает временный namespace со своим клиентом, проверяет handshake
# и всё за собой убирает. Рабочую конфигурацию не меняет.
set -uo pipefail

AWG_DIR=/etc/amnezia/amneziawg
SERVICES="$AWG_DIR/services.env"
DEST=/opt/awg3
DEEP=0; JSON=0

while [ $# -gt 0 ]; do
    case "$1" in
        --deep) DEEP=1; shift ;;
        --json) JSON=1; shift ;;
        -h|--help) sed -n '3,15p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) echo "Неизвестный флаг: $1" >&2; exit 2 ;;
    esac
done

PROBLEMS=0
declare -a REPORT=()

ok()   { REPORT+=("OK|$1");   [ "$JSON" = 1 ] || printf '  \033[1;32m✓\033[0m %s\n' "$1"; }
# Второй аргумент — объяснение: что именно это значит и что делать. Раньше он
# принимался и молча выбрасывался, хотя пять вызовов в этом файле его передают.
# В REPORT клеится к той же строке через тире: бот разбирает отчёт по трём
# известным префиксам, и новый статус сломал бы ему разметку.
bad()  {
    local m="$1"
    [ $# -gt 1 ] && m="$1 — $2"
    REPORT+=("FAIL|$m"); PROBLEMS=$((PROBLEMS+1))
    if [ "$JSON" != 1 ]; then
        printf '  \033[1;31m✗\033[0m %s\n' "$1"
        [ $# -gt 1 ] && printf '      %s\n' "$2"
    fi
    return 0
}
warn() {
    local m="$1"
    [ $# -gt 1 ] && m="$1 — $2"
    REPORT+=("WARN|$m")
    if [ "$JSON" != 1 ]; then
        printf '  \033[1;33m!\033[0m %s\n' "$1"
        [ $# -gt 1 ] && printf '      %s\n' "$2"
    fi
    return 0
}
# заголовок секции идёт и в JSON: бот рисует по нему структуру, иначе в чат
# приезжает плоская простыня без разделов
head_() { REPORT+=("SECTION|$1"); [ "$JSON" = 1 ] || printf '\n\033[1m%s\033[0m\n' "$1"; }

# ── оборванные операции ─────────────────────────────────────────────────────
# Стоит ПЕРЕД требованием services.env: операция, убитая до копирования этого
# файла, иначе выглядела бы как «слой не установлен», и метка, объясняющая
# происходящее, не показалась бы никогда.
# Именована и закрыта `}` на своей строке — стенд вырезает её из файла sed-ом,
# как check_ports в tests/test_ports.sh.
check_marks() {
    local m found=0
    for m in "$AWG_DIR/.restore-in-progress" "$AWG_DIR/.migrate-in-progress"; do
        [ -f "$m" ] || continue
        [ "$found" = 1 ] || head_ "Оборванные операции"
        found=1
        MARK_STARTED=""; MARK_ARCHIVE=""; MARK_MODE=""
        # shellcheck disable=SC1090
        . "$m" 2>/dev/null || true
        case "$m" in
            *restore*)
                bad "восстановление не доведено до конца (начато ${MARK_STARTED:-?})"
                warn "файлы могли обновиться, а сервисы остаться на прежних —"
                warn "повтори: awg-backup restore ${MARK_ARCHIVE:-<архив>}" ;;
            *migrate*)
                bad "миграция ${MARK_MODE:-?} → parallel не доведена до конца"
                warn "повтори полный прогон установщика — он доделает начатое" ;;
        esac
    done
}
check_marks

[ -f "$SERVICES" ] || {
    echo "Сервер не установлен: нет $SERVICES" >&2
    [ -f "$AWG_DIR/.restore-in-progress" ] && \
        echo "  восстановление оборвалось до копирования services.env — повтори awg-backup restore" >&2
    exit 3
}
# shellcheck disable=SC1090
. "$SERVICES"
LAYER2="${LAYER2:-0}"; LAYER3="${LAYER3:-0}"; KMOD3="${KMOD3:-0}"

# Юнит слоя 3.0 зависит от режима: userspace-датапас или общий awg-quick
unit3() {
    if [ "$KMOD3" = 1 ]; then echo "awg-quick@${IFACE3:-awg3}"
    else echo "awg3@${IFACE3:-awg3}"; fi
}

# ── система ─────────────────────────────────────────────────────────────────
head_ "Система"
if [ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" = 1 ]; then ok "IP forwarding включён"
else bad "IP forwarding выключен — трафик клиентов никуда не пойдёт"; fi

if [ -n "${WAN:-}" ] && ip link show "$WAN" >/dev/null 2>&1; then ok "внешний интерфейс $WAN на месте"
else bad "внешний интерфейс '${WAN:-не задан}' не найден — проверь services.env"; fi

if command -v awg >/dev/null 2>&1; then ok "amneziawg-tools: $(awg --version 2>&1 | head -1)"
else bad "нет утилиты awg"; fi

# Обёрнуто в функцию, чтобы стенд вырезал её sed-ом, как check_ports.
check_endpoint() {
    [ -n "${ENDPOINT:-}" ] || return 0
    local ip locals got a hit=0
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' || true)"
    # Приватный src означает NAT: машина ПРИНЦИПИАЛЬНО не знает своего внешнего
    # адреса без сети, и сравнивать не с чем. Без этого фильтра на облаках с
    # приватным NIC (AWS/GCP/Oracle, CGNAT) домен никогда не равен ip, и доктор
    # печатал warn на каждом запуске исправного сервера — а жёлтые строки,
    # которые горят всегда, перестают читать вместе с той, что появится при
    # настоящем переезде. Фильтр тот же, что у detect_public_ip в install.sh.
    case "$ip" in 10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*|127.*|169.254.*|0.0.0.0|"") ip="" ;; esac
    # Все адреса машины, а не только src: плавающий адрес может висеть на
    # другом интерфейсе, и сверка только с src дала бы ложную тревогу.
    locals="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' \
              | cut -d/ -f1 | tr '\n' ' ' || true)"
    case "$ENDPOINT" in
        *[a-zA-Z]*)
            # getent отдаёт 2 на нерезолвящемся имени — штатный ответ.
            # Берём ВСЕ A-записи, а не первую: при round-robin порядок в ответе
            # ротируется, и сверка с первой ходила бы между ok и warn от
            # запуска к запуску на одном и том же исправном сервере.
            # Два шага, а не один конвейер: getent отдаёт 2 на
            # нерезолвящемся имени, и под pipefail `|| true` обязан стоять
            # на той же физической строке, что и труба, — иначе он не
            # защищает и не виден аудиту.
            got="$(getent ahostsv4 "$ENDPOINT" 2>/dev/null || true)"
            got="$(printf '%s\n' "$got" | awk '{print $1}' | sort -u | tr '\n' ' ')"
            if [ -z "$got" ]; then
                bad "домен $ENDPOINT не резолвится — клиенты не найдут сервер"
            elif [ -z "$ip" ]; then
                # Объяснение обязательно: без него `ok` выглядит как пройденная
                # проверка, которой на самом деле не было.
                ok "домен $ENDPOINT резолвится в ${got% } (свой внешний адрес машине неизвестен — за NAT, сверка с ним не делалась)"
            else
                for a in $got; do
                    case " $locals $ip " in *" $a "*) hit=1 ;; esac
                done
                if [ "$hit" = 1 ]; then ok "домен $ENDPOINT резолвится в адрес этой машины"
                else warn "домен $ENDPOINT указывает на ${got% }, а у машины ${locals% } — если адрес не плавающий, проверь DNS"; fi
            fi ;;
        # Голый IP не сверяем с адресом машины сознательно: на облаке за NAT
        # или с плавающим адресом это безусловная ложная тревога, а объявленное
        # владельцем значение мы не оспариваем.
        *) ok "адрес сервера: $ENDPOINT" ;;
    esac
}
check_endpoint

# ── интерфейсы слоёв ────────────────────────────────────────────────────────

# ── инвариант портов ────────────────────────────────────────────────────────
# Порт живёт в трёх местах сразу: в services.env (объявленный), в серверном
# конфиге (ListenPort) и в каждом выданном клиенте (Endpoint). Разъехаться они
# могут молча: правка конфига руками, оборванная миграция, перенос сервера. И
# тогда «порт не слушается» — это следствие, а не причина, а лечится оно
# переизданием клиентских конфигов, а не перезапуском сервиса.
# Порт годен, если это число из 1..65535. Вынесено, потому что сравнивать
# приходится в трёх местах, и `[ "$p" -gt 0 ]` на нечисле ещё и ругается.
valid_port() {
    case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac
    [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

# Порт в Endpoint у выданных конфигов. Проверяется САМ ПО СЕБЕ, без сверки с
# объявленным: значение вне 1..65535 недействительно всегда и доказывается
# одним файлом. Раньше этот осмотр выключался ранним выходом из check_ports —
# то есть ровно там, где поломка гарантирована.
check_client_ports() {  # check_client_ports <каталог клиентов> <метка>
    local cldir="$1" label="$2" f ep p n=0 bad_n=0 sample=""
    [ -d "$cldir" ] || return 0
    for f in "$cldir"/*-am.conf; do
        [ -f "$f" ] || continue
        ep="$(sed -n 's/^Endpoint *= *//p' "$f" 2>/dev/null | head -1 || true)"
        [ -n "$ep" ] || continue
        p="${ep##*:}"
        n=$((n + 1))
        valid_port "$p" && continue
        bad_n=$((bad_n + 1))
        [ -n "$sample" ] || sample="$(basename "$f") → $ep"
    done
    [ "$bad_n" = 0 ] && return 0
    bad "$label: у $bad_n из $n конфигов недействительный порт ($sample)" \
        "такой конфиг не подключится никогда — переиздай клиентов после того, как порт будет объявлен"
}

check_ports() {  # check_ports <имя> <объявленный порт> <каталог клиентов> <имя переменной>
    local iface="$1" want="$2" cldir="$3" var="${4:-}"
    local conf="$AWG_DIR/${iface}.conf" got n=0 bad_n=0 sample=""
    # ДО раннего выхода: недействительный порт у клиента доказывается одним
    # файлом, и объявленное значение для этого не нужно.
    check_client_ports "$cldir" "$iface"
    if ! valid_port "$want"; then
        # «Переменной нет вовсе» и «переменная есть, но пуста или ноль» — разные
        # диагнозы. Первое бывает на установке прежних версий, доказать по нему
        # нечего. Второе — сломанный план: слой объявлен включённым, а порта у
        # него нет, и клиенты выписываются с нулевым или чужим портом.
        # [ -f ] перед grep обязателен: с пустым путём grep читает stdin и
        # прогон повисает молча — в стенде SERVICES может быть не задан.
        if [ -n "$var" ] && [ -f "${SERVICES:-}" ] && grep -q "^${var}=" "$SERVICES"; then
            bad "$iface: в services.env $var пуст или недействителен ($want)" \
                "клиенты выписываются с негодным портом — задай порт и переиздай их"
        else
            warn "порт $iface не объявлен в services.env"
        fi
        return
    fi

    got="$(sed -n 's/^ListenPort *= *//p' "$conf" 2>/dev/null | head -1 || true)"
    if [ -z "$got" ]; then
        bad "$conf: нет ListenPort — интерфейс не поднимется"
    elif [ "$got" != "$want" ]; then
        bad "$iface: в services.env порт $want, в конфиге $got" \
            "клиенты стучатся по одному из них, сервер слушает другой"
    else
        ok "$iface: порт в конфиге совпадает с объявленным ($want)"
    fi

    [ -d "$cldir" ] || return 0
    local f ep
    for f in "$cldir"/*-am.conf; do
        [ -f "$f" ] || continue
        n=$((n + 1))
        # Endpoint = host:port — порт это хвост после последнего двоеточия,
        # так что IPv6-адрес в скобках он тоже переживёт.
        ep="$(sed -n 's/^Endpoint *= *//p' "$f" 2>/dev/null | head -1 || true)"
        ep="${ep##*:}"
        [ -n "$ep" ] && [ "$ep" != "$want" ] && {
            bad_n=$((bad_n + 1))
            [ -n "$sample" ] || sample="$(basename "$f") → $ep"
        }
    done
    if [ "$n" = 0 ]; then
        :
    elif [ "$bad_n" = 0 ]; then
        ok "$iface: у всех $n выданных конфигов Endpoint на порт $want"
    else
        bad "$iface: у $bad_n из $n конфигов Endpoint на чужой порт ($sample)" \
            "этим клиентам нужно раздать конфиги заново — перезапуск не поможет"
    fi
}


# ── хост в выданных конфигах ────────────────────────────────────────────────
# Endpoint пишется ровно в одном месте (add_client) и всегда из единственного
# объявленного хоста. Значит несовпадение — всегда настоящее расхождение, и
# сверка эта не ходит в сеть: файл против файла, без ложных тревог за NAT.
# regen-all его НЕ чинит: он правит только строки обфускации, сохраняя ключи,
# IP и peer, — поэтому в подсказке сказано «раздать заново», а не «пересобрать».
ep_host() {  # ep_host <строка Endpoint без имени поля>
    local e="$1"
    case "$e" in
        "[""$"*|"["*) e="${e#[}"; printf '%s' "${e%%]*}"; return ;;
    esac
    # хост — всё до ПОСЛЕДНЕГО двоеточия; без двоеточий вся строка (битый
    # Endpoint без порта тоже надо увидеть, а не молча принять за хост)
    case "$e" in
        *:*) printf '%s' "${e%:*}" ;;
        *)   printf '%s' "$e" ;;
    esac
}
# Скобки снимаются с ОБЕИХ сторон: ep_host отдаёт адрес уже без них, а
# объявленное значение может быть записано и так, и так — иначе одна и та
# же машина выглядела бы расхождением сама с собой.
norm_host() { printf '%s' "$1" | tr 'A-Z' 'a-z' | sed 's/\.$//; s/^\[//; s/\]$//'; }

check_client_hosts() {  # check_client_hosts <объявленный хост> <каталог> <метка>
    local cldir="$2" label="$3" f raw h n=0 diff_n=0 sample="" broken=0
    local want; want="$(norm_host "$1")"
    [ -d "$cldir" ] || return 0
    for f in "$cldir"/*-am.conf; do
        [ -f "$f" ] || continue
        raw="$(sed -n 's/^Endpoint *= *//p' "$f" 2>/dev/null | head -1 || true)"
        [ -n "$raw" ] || continue          # нет Endpoint — не наш файл
        h="$(norm_host "$(ep_host "$raw")")"
        if [ -z "$h" ]; then
            bad "$(basename "$f"): в Endpoint нет адреса сервера ($raw)" \
                "этот конфиг не подключится ни при каких настройках"
            broken=$((broken + 1))
            continue
        fi
        n=$((n + 1))
        [ -n "$want" ] || continue          # объявленного нет — сравнивать не с чем
        if [ "$h" != "$want" ]; then
            diff_n=$((diff_n + 1))
            [ -n "$sample" ] || sample="$(basename "$f") → $h"
        fi
    done
    [ "$n" = 0 ] && return 0
    if [ -z "$want" ]; then
        [ "$broken" = 0 ] && return 0
        return 0
    fi
    if [ "$diff_n" = 0 ]; then
        ok "$label: у всех $n конфигов Endpoint на $want"
    else
        warn "$label: $diff_n из $n конфигов выданы на другой адрес ($sample), объявлен $want"
        warn "  этим клиентам надо раздать конфиги заново — regen-all адрес не меняет"
    fi
}


# ── ключи и пиры ────────────────────────────────────────────────────────────
# Приватный ключ клиента есть ТОЛЬКО в его конфиге, публичный — в [Peer]
# серверного. Пара пишется не атомарно (три отдельные записи в add_client, две
# в del_client), поэтому расхождение достижимо обрывом, а не только переносом.
# Сверка идёт по КЛЮЧУ, а не по адресу: next_ip переиспользует освободившиеся
# адреса, и сверка по AllowedIPs дала бы ложное зелёное.
# ── застрявшие параметры 3.0 ────────────────────────────────────────────────
# Сверка файла с файлом, без демона: если профиль не объявляет header
# protection, а рядом с конфигом лежит .v3 с ключом, значит .v3 остался от
# прежнего профиля. Датапас применит его на ExecStartPost, и сервер разойдётся
# со всеми выданными конфигами.
check_v3_stale() {  # check_v3_stale <путь .v3> <объявлена ли в профиле> <пресет>
    local v3f="$1" want="$2" preset="$3"
    [ -f "$v3f" ] || return 0
    grep -q '^header_protection_key=' "$v3f" 2>/dev/null || return 0
    [ "$want" = 1 ] && return 0
    bad "$v3f содержит header_protection_key, а профиль $preset его не объявляет" \
        "файл остался от прежнего профиля — примени текущий заново: awg-obfuscation --v3 --apply"
}

check_peers() {  # check_peers <серверный конфиг> <каталог клиентов> <метка>
    local conf="$1" cldir="$2" label="$3"
    [ -f "$conf" ] || return 0
    [ -d "$cldir" ] || return 0
    command -v awg >/dev/null 2>&1 || { warn "$label: нет awg — пары ключей не сверялись"; return 0; }

    local srv_priv srv_pub peers f cpriv cpub addr
    srv_priv="$(sed -n 's/^PrivateKey *= *//p' "$conf" 2>/dev/null | head -1 || true)"
    srv_pub=""
    [ -n "$srv_priv" ] && srv_pub="$(printf '%s' "$srv_priv" | awg pubkey 2>/dev/null || true)"
    peers="$(sed -n 's/^PublicKey *= *//p' "$conf" 2>/dev/null | tr '\n' ' ' || true)"

    local n=0 lost=0 lost_s="" wrongsrv=0 wrongsrv_s="" seen="" dup=0 dup_s="" matched=""
    for f in "$cldir"/*-am.conf; do
        [ -f "$f" ] || continue
        cpriv="$(sed -n 's/^PrivateKey *= *//p' "$f" 2>/dev/null | head -1 || true)"
        [ -n "$cpriv" ] || continue          # чужой файл — не наш формат
        cpub="$(printf '%s' "$cpriv" | awg pubkey 2>/dev/null || true)"
        [ -n "$cpub" ] || continue           # ключ не выводится — молчим, доказать нечем
        n=$((n + 1))
        case " $peers " in
            *" $cpub "*) matched="$matched $cpub" ;;
            *) lost=$((lost + 1)); [ -n "$lost_s" ] || lost_s="$(basename "$f")" ;;
        esac
        # Ключ сервера в [Peer] клиента: несовпадение делает handshake
        # невозможным, и законного состояния у него нет.
        if [ -n "$srv_pub" ]; then
            local cs
            cs="$(sed -n 's/^PublicKey *= *//p' "$f" 2>/dev/null | head -1 || true)"
            if [ -n "$cs" ] && [ "$cs" != "$srv_pub" ]; then
                wrongsrv=$((wrongsrv + 1))
                [ -n "$wrongsrv_s" ] || wrongsrv_s="$(basename "$f")"
            fi
        fi
        addr="$(sed -n 's/^Address *= *//p' "$f" 2>/dev/null | head -1 || true)"
        addr="${addr%%,*}"
        if [ -n "$addr" ]; then
            case " $seen " in
                *" $addr "*) dup=$((dup + 1)); [ -n "$dup_s" ] || dup_s="$addr" ;;
                *) seen="$seen $addr" ;;
            esac
        fi
    done
    [ "$n" = 0 ] && return 0

    if [ "$lost" = 0 ]; then
        ok "$label: все $n клиентов есть среди пиров сервера"
    else
        bad "$label: у $lost из $n клиентов ключа нет среди пиров ($lost_s)" \
            "эти конфиги выданы, но сервер их не примет — заведи клиентов заново"
    fi
    if [ "$wrongsrv" != 0 ]; then
        bad "$label: у $wrongsrv из $n конфигов чужой ключ сервера ($wrongsrv_s)" \
            "handshake невозможен: ключ сервера сменился, а конфиги несут прежний"
    fi
    if [ "$dup" != 0 ]; then
        bad "$label: $dup конфигов делят адрес с другим клиентом ($dup_s)" \
            "следующий выданный клиент заберёт маршрут у работающего"
    fi
    # Пир без клиентского файла — доступ, который нельзя отозвать по имени.
    # warn, а не bad: пир мог быть заведён руками, а файл унесён владельцем.
    local p orphan=0
    for p in $peers; do
        case " $matched " in *" $p "*) ;; *) orphan=$((orphan + 1)) ;; esac
    done
    if [ "$orphan" != 0 ]; then
        warn "$label: $orphan пиров без клиентского файла — доступ есть, отозвать по имени нечем"
    fi
}

check_iface() {  # check_iface <имя> <порт> <подсеть> <слой>
    local i="$1" p="$2" sub="$3" layer="$4" unit peers
    [ "$layer" = 3 ] && unit="$(unit3)" || unit="awg-quick@$i"
    if ip link show "$i" >/dev/null 2>&1; then
        ok "$i поднят ($(ip -4 -br addr show "$i" 2>/dev/null | awk '{print $3}'))"
    else
        bad "$i отсутствует — journalctl -u $unit"
        return
    fi
    if systemctl is-active --quiet "$unit"; then ok "$unit активен"
    else bad "$unit не активен"; fi
    # Поле берём с конца, а не по номеру: `ss -lunH` печатает колонку Netid не
    # на всех версиях iproute2, и «четвёртая» верна лишь в одной раскладке.
    # Локальный адрес — предпоследнее поле в любой. Так же считает busy_ports.
    # grep -q оставлен сознательно: вывод ss короткий, в буфер трубы влезает,
    # и SIGPIPE тут не случается — а файл к тому же идёт без set -e.
    # Про недействительный порт уже сказала check_ports, и сказала точнее:
    # «порт 0 не слушается» уводит перезапускать сервис, тогда как чинить надо
    # объявление порта и переиздание конфигов.
    if valid_port "$p"; then
        if ss -lunH 2>/dev/null | awk '{print $(NF-1)}' | grep -qE ":$p\$"; then ok "порт $p слушается"
        else bad "порт $p не слушается"; fi
    fi
    if iptables -w -t nat -C POSTROUTING -s "${sub}.0/24" -o "${WAN:-eth0}" -j MASQUERADE 2>/dev/null; then
        ok "NAT для ${sub}.0/24 настроен"
    else
        bad "нет MASQUERADE для ${sub}.0/24 — клиенты подключатся, но интернета не увидят"
    fi
    peers="$(awg show "$i" peers 2>/dev/null | grep -c . || true)"
    ok "$i: клиентов $peers"
}

if [ "$LAYER2" = 1 ]; then
    head_ "Слой AmneziaWG 2.0 (kernel-модуль)"
    if modinfo amneziawg >/dev/null 2>&1; then ok "модуль amneziawg собран"
    else bad "модуль amneziawg недоступен — dkms status"; fi
    check_iface "${IFACE2:-awg2}" "${PORT2:-0}" "${SUBNET2:-10.29.79}" 2
    check_ports "${IFACE2:-awg2}" "${PORT2:-}" "$DEST/clients/awg2" PORT2
    check_client_hosts "${ENDPOINT:-}" "$DEST/clients/awg2" "${IFACE2:-awg2}"
    check_peers "$AWG_DIR/${IFACE2:-awg2}.conf" "$DEST/clients/awg2" "${IFACE2:-awg2}"
fi

if [ "$LAYER3" = 1 ]; then
    if [ "$KMOD3" = 1 ]; then
        head_ "Слой AmneziaWG 3.0 (kernel-модуль, экспериментально)"
        if grep -rqs WGDEVICE_A_HEADER_PROTECTION_KEY \
             /opt/src/amneziawg-linux-kernel-module/src/uapi/wireguard.h 2>/dev/null; then
            ok "модуль собран из ветки с поддержкой 3.0"
        else
            bad "модуль без поддержки 3.0. Флаг --kmod3 отключён (см. install.sh); слой 3.0 обслуживает userspace-датапас amneziawg-go"
        fi
    else
        head_ "Слой AmneziaWG 3.0 (userspace)"
        if command -v amneziawg-go >/dev/null 2>&1; then ok "amneziawg-go установлен"
        else bad "нет amneziawg-go"; fi
    fi
    check_iface "${IFACE3:-awg3}" "${PORT3:-0}" "${SUBNET3:-10.29.80}" 3
    check_ports "${IFACE3:-awg3}" "${PORT3:-}" "$DEST/clients/awg3" PORT3
    check_client_hosts "${ENDPOINT:-}" "$DEST/clients/awg3" "${IFACE3:-awg3}"
    check_peers "$AWG_DIR/${IFACE3:-awg3}.conf" "$DEST/clients/awg3" "${IFACE3:-awg3}"
    if [ "$KMOD3" = 1 ]; then
        # Известная поломка ветки feat/awg3: политика netlink в модуле объявляет
        # WGPEER_A_PERSISTENT_KEEPALIVE_INTERVAL как NLA_U64, а утилиты шлют u32,
        # поэтому ЛЮБОЙ peer с PersistentKeepalive отвергается. Клиенты при этом
        # молча не подключаются, так что проверяем прицельно и по существу.
        probe="awgprobe$$"
        if ip link add "$probe" type amneziawg 2>/dev/null; then
            probe_conf="$(mktemp)"
            printf '[Interface]\nPrivateKey = %s\n\n[Peer]\nPublicKey = %s\nAllowedIPs = 10.255.255.1/32\nPersistentKeepalive = 15\n' \
                "$(awg genkey)" "$(awg genkey | awg pubkey)" > "$probe_conf"
            if awg setconf "$probe" "$probe_conf" 2>/dev/null; then
                ok "модуль принимает PersistentKeepalive"
            else
                bad "модуль отвергает PersistentKeepalive — клиенты не подключатся. Утилиты и модуль разошлись по версиям: bash install.sh (полный прогон, профиль обфускации не меняется)"
            fi
            rm -f "$probe_conf"
            ip link del "$probe" 2>/dev/null
        fi
    fi
    # Где искать подтверждение: в ядре его печатает сам `awg show`, у
    # userspace-датапаса параметры живут только в памяти — читаем через UAPI.
    #
    # Отсутствие ключа — не всегда поломка: пресеты router и low объявлены с
    # header_protection=False, content_padding=None и timings=False, то есть
    # ключа там нет ПО ЗАМЫСЛУ. Раньше доктор в обоих случаях писал «параметры
    # 3.0 не применены», и владелец исправного сервера шёл искать несуществующую
    # проблему. Поэтому сначала смотрим, что за пресет вообще просили.
    v3_preset="$(sed -n 's/^META_PRESET=//p' "$AWG_DIR/obfuscation3.meta" 2>/dev/null | head -1)"
    # «Спросить не удалось» и «ключа нет» — разные диагнозы. Бит +x не проверяем:
    # скрипт запускается через python3, и потеря права на исполнение раньше
    # давала диагноз «параметры не применены» на пустом месте.
    hp3=0; v3_live=""
    if [ "$KMOD3" = 1 ]; then
        v3_live="$(awg show "${IFACE3:-awg3}" 2>/dev/null || true)"
        case "$v3_live" in *[Hh]eader\ [Pp]rotection*) hp3=1 ;; esac
    elif [ -f "$DEST/awg-uapi.py" ]; then
        v3_live="$(python3 "$DEST/awg-uapi.py" show "${IFACE3:-awg3}" 2>/dev/null || true)"
        case "$v3_live" in *header_protection_key*) hp3=1 ;; esac
    else
        warn "нечем спросить демона: нет $DEST/awg-uapi.py — состояние 3.0 неизвестно"
        v3_live="?"
    fi
    # Источник истины — ПРОФИЛЬ, а не имя пресета: имя это ярлык, а клиентские
    # конфиги выписываются по профилю. Решаем так же, как решает генератор
    # (awg-obfuscation.sh: `[ -n "${AWG_HPK_HEX:-}" ]`), иначе доктор и
    # генератор разойдутся в понимании одного и того же файла.
    hpk_want=0
    # shellcheck disable=SC1090
    if [ -n "$( . "$AWG_DIR/obfuscation3.env" 2>/dev/null || true; printf '%s' "${AWG_HPK_HEX:-}" )" ]; then
        hpk_want=1
    fi
    if [ -z "$v3_live" ]; then
        warn "${IFACE3:-awg3}: демон не ответил — состояние 3.0 неизвестно" \
             "смотри: journalctl -u awg3@${IFACE3:-awg3} -n 30 --no-pager"
    elif [ "$v3_live" = "?" ]; then
        :
    elif [ "$hp3" = 1 ] && [ "$hpk_want" = 1 ]; then
        ok "header protection применена (пресет ${v3_preset:-?})"
    elif [ "$hp3" = 1 ]; then
        # Применена, хотя профиль её не объявляет. Так выглядит застрявший .v3
        # от прежнего, более сильного профиля: сервер ждёт header protection,
        # клиентские конфиги выданы без неё — не сходится НИКТО. Раньше здесь
        # печаталось ok, то есть самый разрушительный исход был зелёным.
        bad "на интерфейсе есть header protection, а профиль ${v3_preset:-?} её не объявляет" \
            "клиенты выданы без неё и не подключатся: примени профиль заново — awg-obfuscation --v3 --apply"
    elif [ "$hpk_want" = 1 ]; then
        warn "профиль ${v3_preset:-?} объявляет header protection, но на интерфейсе её нет" \
             "починить: awg-obfuscation --v3 --regenerate --apply"
        echo "     профиль: $AWG_DIR/obfuscation3.env (ищи AWG_HPK_HEX)" >&2
        echo "     параметры: $AWG_DIR/${IFACE3:-awg3}.v3" >&2
    else
        ok "профиль ${v3_preset:-?} — без header protection, так и задумано"
        echo "     обфускация на уровне 2.0; нужен полный набор 3.0 —" >&2
        echo "     смени пресет: awg-obfuscation --v3 --preset medium --regenerate --apply" >&2
        echo "     и раздай клиентам свежие конфиги: awg-client regen-all" >&2
    fi
    # Та же сверка, но файла с файлом: она работает и тогда, когда демона
    # спросить нечем, и ловит застрявший .v3 ДО перезапуска датапаса.
    check_v3_stale "$AWG_DIR/${IFACE3:-awg3}.v3" "$hpk_want" "${v3_preset:-?}"
fi

# ── профили обфускации ──────────────────────────────────────────────────────
head_ "Профиль обфускации"
for pair in "obfuscation.env|2.0|$LAYER2" "obfuscation3.env|3.0|$LAYER3"; do
    f="${pair%%|*}"; rest="${pair#*|}"; ver="${rest%%|*}"; on="${rest##*|}"
    [ "$on" = 1 ] || continue
    if [ -s "$AWG_DIR/$f" ]; then ok "профиль $ver есть ($f)"; else bad "нет $AWG_DIR/$f"; fi
done
# незаменённый плейсхолдер — классический признак, что профиль не применился
if grep -rqs '__AWG3\?_OBFUSCATION__' "$AWG_DIR"/*.conf 2>/dev/null; then
    bad "в серверном конфиге остался плейсхолдер обфускации — awg-obfuscation --regenerate"
else
    ok "плейсхолдеров в конфигах нет"
fi

# ── клиенты ─────────────────────────────────────────────────────────────────
head_ "Клиенты"
total=0
for svc in awg2 awg3; do
    n="$(ls -1 "$DEST/clients/$svc"/*-am.conf 2>/dev/null | wc -l)"
    [ "$n" -gt 0 ] && ok "$svc: конфигов $n"
    total=$((total + n))
done
[ "$total" = 0 ] && warn "клиентов ещё нет — awg-client add <имя>"
if [ -x "$DEST/awg-selftest.py" ] && [ "$total" -gt 0 ]; then
    if python3 "$DEST/awg-selftest.py" --all >/dev/null 2>&1; then
        ok "выдаваемые конфиги приложение примет"
    else
        warn "самотест конфигов нашёл замечания — awg-selftest.py --all"
    fi
fi

# ── глубокая проверка ───────────────────────────────────────────────────────
deep_check() {  # deep_check <awg2|awg3>
    local svc="$1" ns="awgdoc$$" tmp="doctor$$" veth="vd$$"
    local conf hs=0 dev="$tmp"

    cleanup_deep() {
        ip netns exec "$ns" awg-quick down "$tmp" >/dev/null 2>&1
        # userspace-датапас в namespace завершаем по сокету, а не по имени
        pkill -f "amneziawg-go -f $tmp" >/dev/null 2>&1
        ip netns del "$ns" >/dev/null 2>&1
        ip link del "$veth" >/dev/null 2>&1
        "$DEST/awg-client.sh" del "$tmp" "$svc" >/dev/null 2>&1
        rm -f "$AWG_DIR/$tmp.conf" "/tmp/$tmp.v3" 2>/dev/null
        iptables -w -t nat -D POSTROUTING -s 10.199.0.0/24 -j MASQUERADE 2>/dev/null
    }
    trap cleanup_deep EXIT

    if ! "$DEST/awg-client.sh" add "$tmp" "$svc" >/dev/null 2>&1; then
        bad "$svc: не удалось создать тестового клиента"
        cleanup_deep; trap - EXIT; return
    fi
    conf="$(ls -1 "$DEST/clients/$svc"/*"$tmp"*-am.conf 2>/dev/null | head -1)"
    if [ -z "$conf" ]; then
        warn "$svc: конфиг тестового клиента не найден"
        cleanup_deep; trap - EXIT; return
    fi

    # сеть namespace: veth + NAT, чтобы клиент видел внешний порт сервера
    ip netns add "$ns" 2>/dev/null
    ip link add "$veth" type veth peer name vdp 2>/dev/null
    ip link set vdp netns "$ns" 2>/dev/null
    ip addr add 10.199.0.1/24 dev "$veth" 2>/dev/null; ip link set "$veth" up
    ip netns exec "$ns" ip link set lo up
    ip netns exec "$ns" ip addr add 10.199.0.2/24 dev vdp
    ip netns exec "$ns" ip link set vdp up
    ip netns exec "$ns" ip route add default via 10.199.0.1
    iptables -w -t nat -A POSTROUTING -s 10.199.0.0/24 -j MASQUERADE 2>/dev/null

    # DNS внутри namespace не нужен и мешает поднятию туннеля
    grep -v '^DNS' "$conf" > "$AWG_DIR/$tmp.conf"; chmod 600 "$AWG_DIR/$tmp.conf"

    if [ "$svc" = awg3 ] && [ "${KMOD3:-0}" != 1 ]; then
        # Слой 3.0 нельзя проверить через awg-quick: параметры 3.0 в конфиге
        # утилиты не понимают, а kernel-модуль их не умеет. Поднимаем клиента
        # тем же userspace-демоном и досылаем v3-параметры через UAPI.
        local addr; addr="$(awk -F'[[:space:]]*=[[:space:]]*' '/^Address/{print $2; exit}' "$AWG_DIR/$tmp.conf")"
        python3 - "$AWG_DIR/$tmp.conf" > "/tmp/$tmp.v3" <<'PY'
import base64, sys
names = {"HeaderProtectionKey": "header_protection_key",
         "ContentPaddingAddition": "content_padding_addition",
         "RekeyAfterTime": "rekey_after_time", "RekeyTimeout": "rekey_timeout",
         "RejectAfterTime": "reject_after_time", "KeepaliveTimeout": "keepalive_timeout",
         "MaxHandshakeAttempts": "max_handshake_attempts"}
for line in open(sys.argv[1], encoding="utf-8"):
    if "=" not in line:
        continue
    k, v = (x.strip() for x in line.split("=", 1))
    if k not in names:
        continue
    # ключ header protection в конфиге лежит в base64, а UAPI ждёт hex
    if k == "HeaderProtectionKey":
        v = base64.b64decode(v).hex()
    print(f"{names[k]}={v}")
PY
        ip netns exec "$ns" env LOG_LEVEL=error amneziawg-go -f "$dev" >/dev/null 2>&1 &
        sleep 2
        ip netns exec "$ns" awg setconf "$dev" <(awg-quick strip "$tmp" 2>/dev/null \
            | grep -vE '^(HeaderProtectionKey|ContentPaddingAddition|RekeyAfterTime|RekeyTimeout|RejectAfterTime|KeepaliveTimeout|MaxHandshakeAttempts) *=') >/dev/null 2>&1
        [ -s "/tmp/$tmp.v3" ] && ip netns exec "$ns" python3 "$DEST/awg-uapi.py" set "$dev" --from-file "/tmp/$tmp.v3" >/dev/null 2>&1
        ip netns exec "$ns" ip address add "$addr" dev "$dev" 2>/dev/null
        ip netns exec "$ns" ip link set mtu "${MTU3:-1380}" up dev "$dev"
        ip netns exec "$ns" ip route add default dev "$dev" 2>/dev/null
    else
        ip netns exec "$ns" awg-quick up "$tmp" >/dev/null 2>&1
        dev="$tmp"
    fi

    for _ in $(seq 1 15); do
        hs="$(ip netns exec "$ns" awg show "$dev" latest-handshakes 2>/dev/null | awk '{print $2}')"
        [ "${hs:-0}" != 0 ] && break
        sleep 1
    done
    if [ "${hs:-0}" != 0 ]; then
        ok "$svc: handshake проходит"
        if ip netns exec "$ns" curl -4 -fsS --max-time 8 https://api.ipify.org >/dev/null 2>&1; then
            ok "$svc: трафик ходит через туннель"
        else
            bad "$svc: handshake есть, но наружу трафик не идёт — смотри NAT и forwarding"
        fi
    else
        bad "$svc: handshake не проходит"
    fi
    cleanup_deep; trap - EXIT
}

if [ "$DEEP" = 1 ]; then
    head_ "Связность (реальный клиент)"
    [ "$LAYER2" = 1 ] && deep_check awg2
    [ "$LAYER3" = 1 ] && deep_check awg3
fi

# ── вывод ───────────────────────────────────────────────────────────────────
if [ "$JSON" = 1 ]; then
    printf '{"problems": %d, "checks": [' "$PROBLEMS"
    first=1
    for r in "${REPORT[@]}"; do
        st="${r%%|*}"; msg="${r#*|}"
        [ "$first" = 1 ] || printf ','
        first=0
        printf '{"status":"%s","text":"%s"}' "$st" "$(printf '%s' "$msg" | sed 's/"/\\"/g')"
    done
    printf ']}\n'
else
    echo
    if [ "$PROBLEMS" = 0 ]; then
        printf '\033[1;32mПроверка завершена: проблем не найдено\033[0m\n'
    else
        printf '\033[1;31mПроверка завершена: проблем — %d\033[0m\n' "$PROBLEMS"
    fi
fi
exit 0
