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
bad()  { REPORT+=("FAIL|$1"); PROBLEMS=$((PROBLEMS+1)); [ "$JSON" = 1 ] || printf '  \033[1;31m✗\033[0m %s\n' "$1"; }
warn() { REPORT+=("WARN|$1"); [ "$JSON" = 1 ] || printf '  \033[1;33m!\033[0m %s\n' "$1"; }
# заголовок секции идёт и в JSON: бот рисует по нему структуру, иначе в чат
# приезжает плоская простыня без разделов
head_() { REPORT+=("SECTION|$1"); [ "$JSON" = 1 ] || printf '\n\033[1m%s\033[0m\n' "$1"; }

[ -f "$SERVICES" ] || { echo "Сервер не установлен: нет $SERVICES" >&2; exit 3; }
# shellcheck disable=SC1090
. "$SERVICES"
LAYER2="${LAYER2:-0}"; LAYER3="${LAYER3:-0}"

# ── система ─────────────────────────────────────────────────────────────────
head_ "Система"
if [ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" = 1 ]; then ok "IP forwarding включён"
else bad "IP forwarding выключен — трафик клиентов никуда не пойдёт"; fi

if [ -n "${WAN:-}" ] && ip link show "$WAN" >/dev/null 2>&1; then ok "внешний интерфейс $WAN на месте"
else bad "внешний интерфейс '${WAN:-не задан}' не найден — проверь services.env"; fi

if command -v awg >/dev/null 2>&1; then ok "amneziawg-tools: $(awg --version 2>&1 | head -1)"
else bad "нет утилиты awg"; fi

if [ -n "${ENDPOINT:-}" ]; then
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' || true)"
    case "$ENDPOINT" in
        *[a-zA-Z]*)
            got="$(getent ahostsv4 "$ENDPOINT" 2>/dev/null | awk '{print $1; exit}')"
            if [ -z "$got" ]; then bad "домен $ENDPOINT не резолвится — клиенты не найдут сервер"
            elif [ -n "$ip" ] && [ "$got" != "$ip" ]; then
                warn "домен $ENDPOINT указывает на $got, а адрес сервера $ip"
            else ok "домен $ENDPOINT резолвится в $got"; fi ;;
        *) ok "адрес сервера: $ENDPOINT" ;;
    esac
fi

# ── интерфейсы слоёв ────────────────────────────────────────────────────────
check_iface() {  # check_iface <имя> <порт> <подсеть> <слой>
    local i="$1" p="$2" sub="$3" layer="$4" unit peers
    [ "$layer" = 3 ] && unit="awg3@$i" || unit="awg-quick@$i"
    if ip link show "$i" >/dev/null 2>&1; then
        ok "$i поднят ($(ip -4 -br addr show "$i" 2>/dev/null | awk '{print $3}'))"
    else
        bad "$i отсутствует — journalctl -u $unit"
        return
    fi
    if systemctl is-active --quiet "$unit"; then ok "$unit активен"
    else bad "$unit не активен"; fi
    # ВНИМАНИЕ: у `ss -lunH` локальный адрес — четвёртая колонка; пятая это peer
    if ss -lunH 2>/dev/null | awk '{print $4}' | grep -qE ":$p\$"; then ok "порт $p слушается"
    else bad "порт $p не слушается"; fi
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
fi

if [ "$LAYER3" = 1 ]; then
    head_ "Слой AmneziaWG 3.0 (userspace)"
    if command -v amneziawg-go >/dev/null 2>&1; then ok "amneziawg-go установлен"
    else bad "нет amneziawg-go"; fi
    check_iface "${IFACE3:-awg3}" "${PORT3:-0}" "${SUBNET3:-10.29.80}" 3
    # параметры 3.0 живут только в памяти демона — читаем через UAPI
    if [ -x "$DEST/awg-uapi.py" ] && python3 "$DEST/awg-uapi.py" show "${IFACE3:-awg3}" 2>/dev/null \
         | grep -q header_protection_key; then
        ok "header protection применена"
    else
        warn "параметры 3.0 не применены — датапас работает как 2.0"
    fi
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

    if [ "$svc" = awg3 ]; then
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
