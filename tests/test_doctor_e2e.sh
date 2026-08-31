#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Доктор целиком: синтетическое состояние → настоящий awg-doctor.sh → разбор.
#
# Все прочие проверки доктора вырезают из него одну функцию и гоняют её
# отдельно. Это ловит логику функции, но НЕ ловит главного: кому её задают.
# В соседнем проекте на этом вышла ложная тревога — сама функция была права,
# ошибкой был список интерфейсов, которым её задавали, и жёлтое замечание
# выпадало на каждом исправном сервере. Такой набор увидел бы это сразу.
#
# Отсюда главное утверждение раздела 1: на полностью исправном сервере доктор
# не говорит НИЧЕГО — ни красного, ни жёлтого. Это не формальность: каждое
# лишнее замечание на здоровом сервере приучает пролистывать вывод мимо
# настоящего.
#
# Здесь строитель интерфейсов один на оба слоя и <iface>.env пишет обоим,
# поэтому раздел 2 требует обратного, чем в соседнем проекте: пропажа файла
# должна быть слышна у КАЖДОГО слоя.
#
# Состояние собирается в пространстве имён поверх tmpfs, потому что пути в
# докторе прибиты (/etc/amnezia/amneziawg, /opt/awg3). Ответы системы дают
# заглушки на PATH: они читают тот же стенд, поэтому «живое ядро» и «файлы на
# диске» расходятся ровно тогда, когда мы этого хотим.
#
#   bash tests/test_doctor_e2e.sh

fail=0
ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
cd "$ROOT" || exit 1

if ! unshare -Urm --map-root-user true 2>/dev/null; then
    printf '\n  · пространства имён недоступны — сквозной прогон доктора пропущен\n\n'
    [ -n "${GITHUB_ACTIONS:-}" ] && printf '::notice title=%s::%s\n' \
        "test_doctor_e2e" \
        "пропущено: unshare -Urm недоступен, доктор целиком не запускался"
    exit 0
fi

export STAND_REPO="$ROOT"
unshare -Urm --map-root-user bash -s <<'INNER'
set -uo pipefail
fail=0
ok()  { printf '  ✔ %s\n' "$1"; }
bad() { printf '  ✘ %s\n' "$1"; [ $# -gt 1 ] && printf '     %s\n' "$2"; fail=1; }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

W="$(mktemp -d)"
mkdir -p "$W/etc-orig"
mount --rbind /etc "$W/etc-orig" 2>/dev/null || { echo "  · не подложить /etc"; exit 0; }
for d in /etc /root /opt /usr/local /run; do
    mount -t tmpfs none "$d" 2>/dev/null || { echo "  · не смонтировать tmpfs на $d"; exit 0; }
done
cp -a "$W/etc-orig/." /etc/ 2>/dev/null || true

AWG=/etc/amnezia/amneziawg
DEST=/opt/awg3
# Голый IP, а не домен: доктор сознательно не сверяет его с адресом машины
# (на облаке за NAT это безусловная ложная тревога), поэтому стенд не зависит
# ни от DNS, ни от того, что вернёт `ip route get`.
HOST=203.0.113.10
export STUB_STATE="$W/stub-state"

# ── заглушки системы ────────────────────────────────────────────────────────
S="$W/stub"; mkdir -p "$S" "$STUB_STATE/if"
cat > "$S/ip" <<'EOS'
#!/bin/sh
case "$*" in
    *route*get*) exit 0 ;;
    *-o*addr*show*) exit 0 ;;
    *link*show*) i="${*##* }"; [ -f "$STUB_STATE/if/$i" ] && exit 0 || exit 1 ;;
    *addr*show*) i="${*##* }"; cat "$STUB_STATE/if/$i" 2>/dev/null && exit 0 || exit 1 ;;
esac
exit 0
EOS
cat > "$S/awg" <<'EOS'
#!/bin/sh
if [ "$1" = pubkey ]; then read -r k; printf 'PUB_%s\n' "$k"; exit 0; fi
if [ "$1" = show ]; then
    case "$3" in
        peers)      cat "$STUB_STATE/$2.peers" 2>/dev/null; exit 0 ;;
        public-key) cat "$STUB_STATE/$2.pub"   2>/dev/null; exit 0 ;;
    esac
fi
exit 0
EOS
cat > "$S/ss" <<'EOS'
#!/bin/sh
cat "$STUB_STATE/ports" 2>/dev/null
exit 0
EOS
printf '#!/bin/sh\necho 1\n'  > "$S/sysctl"
printf '#!/bin/sh\nexit 0\n' > "$S/modinfo"
printf '#!/bin/sh\nexit 0\n' > "$S/systemctl"
printf '#!/bin/sh\nexit 0\n' > "$S/dkms"
printf '#!/bin/sh\nexit 0\n' > "$S/amneziawg-go"
printf '#!/bin/sh\nexit 0\n' > "$S/awg-quick"
# NAT: правило считается настроенным, если подсеть есть в списке стенда
cat > "$S/iptables" <<'EOS'
#!/bin/sh
for a in "$@"; do
    case "$a" in */24) grep -qx "$a" "$STUB_STATE/nat" 2>/dev/null && exit 0 || exit 1 ;;
    esac
done
exit 0
EOS
chmod +x "$S"/*
export PATH="$S:$PATH"

# ── стенд: полностью исправный сервер с обоими слоями ───────────────────────
mk_stand() {
    rm -rf "$AWG" "$DEST"
    rm -rf "$STUB_STATE"; mkdir -p "$STUB_STATE/if"
    mkdir -p "$AWG" "$DEST/clients"
    printf '%s\n' 'print("header_protection_key=deadbeef")' > "$DEST/awg-uapi.py"

    {
        echo "LAYER2='1'"; echo "LAYER3='1'"; echo "KMOD3='0'"
        echo "IFACE2='awg2'";  echo "SUBNET2='10.29.79'"; echo "PORT2='51820'"; echo "MTU2='1420'"
        echo "IFACE3='awg3'";  echo "SUBNET3='10.29.80'"; echo "PORT3='51821'"; echo "MTU3='1380'"
        echo "DNS='1.1.1.1, 8.8.8.8'"
        echo "ENDPOINT='$HOST'"
        echo "WAN='eth0'"
        echo "CLIENT_DIR='$DEST/clients'"
    } > "$AWG/services.env"

    printf "AWG_Jc='4'\n" > "$AWG/obfuscation.env"
    printf "AWG_Jc='4'\nAWG_HPK_HEX='deadbeef'\n" > "$AWG/obfuscation3.env"

    : > "$STUB_STATE/ports"
    : > "$STUB_STATE/nat"
    # внешний интерфейс машины — доктор проверяет его существование
    printf 'eth0 UP 203.0.113.10/24\n' > "$STUB_STATE/if/eth0"
    # <иф> <подсеть> <порт> <mtu> <слой>
    while read -r i sub port mtu layer; do
        [ -n "$i" ] || continue
        printf '%s UNKNOWN %s.1/24\n' "$i" "$sub" > "$STUB_STATE/if/$i"
        printf 'UNCONN 0 0 0.0.0.0:%s 0.0.0.0:*\n' "$port" >> "$STUB_STATE/ports"
        printf 'PUB_SRV_%s\n' "$i" > "$STUB_STATE/$i.pub"
        mkdir -p "$DEST/clients/$i"
        {
            echo "[Interface]"
            echo "PrivateKey = SRV_$i"
            echo "Address = ${sub}.1/24"
            echo "ListenPort = $port"
            echo "MTU = $mtu"
        } > "$AWG/$i.conf"
        # <iface>.env пишется ОБОИМ слоям — здесь строитель один
        { echo "SUBNET=${sub}.0/24"; echo "PORT=$port"; echo "NAT=1"
          echo "MTU=$mtu"; echo "WAN=eth0"; } > "$AWG/$i.env"
        [ "$layer" = 3 ] && printf 'header_protection_key=deadbeef\n' > "$AWG/$i.v3"
        printf '%s.0/24\n' "$sub" >> "$STUB_STATE/nat"
        {
            echo; echo "[Peer]"; echo "# alice"
            echo "PublicKey = PUB_CLI_${i}"
            echo "AllowedIPs = ${sub}.2/32"
        } >> "$AWG/$i.conf"
        printf 'PUB_CLI_%s\n' "$i" > "$STUB_STATE/$i.peers"
        {
            echo "[Interface]"
            echo "PrivateKey = CLI_${i}"
            echo "Address = ${sub}.2/32"
            echo "MTU = $mtu"
            echo; echo "[Peer]"
            echo "PublicKey = PUB_SRV_${i}"
            echo "Endpoint = ${HOST}:${port}"
            echo "AllowedIPs = 0.0.0.0/0, ::/0"
        } > "$DEST/clients/$i/${i}-alice-am.conf"
    done <<EOT
awg2 10.29.79 51820 1420 2
awg3 10.29.80 51821 1380 3
EOT
}

run_doctor() { bash "$STAND_REPO/bin/awg-doctor.sh" --json 2>"$W/doc.err"; }
n_of() { grep -o "\"status\":\"$1\"" "$W/out" 2>/dev/null | wc -l; }
texts_of() { grep -o "\"status\":\"$1\",\"text\":\"[^\"]*\"" "$W/out" 2>/dev/null | sed 's/.*"text":"//;s/"$//'; }

# ═══════════════════════════════════════════════════════════════════════════
head_ "1. Исправный сервер: доктор молчит"
mk_stand
run_doctor > "$W/out"
nf="$(n_of FAIL)"; nw="$(n_of WARN)"; no="$(n_of OK)"
if [ "$no" -lt 15 ]; then
    bad "доктор сделал всего $no проверок" "стенд не доехал до осмотра: $(head -3 "$W/doc.err")"
elif [ "$nf" = 0 ] && [ "$nw" = 0 ]; then
    ok "ни одного замечания на $no проверках"
else
    bad "на исправном сервере $nf ошибок и $nw замечаний" "$(texts_of FAIL; texts_of WARN)"
fi

# ═══════════════════════════════════════════════════════════════════════════
head_ "2. Пропажа <iface>.env слышна у ОБОИХ слоёв"
# Обратное соседнему проекту, и намеренно: там .env пишет только слой 3.0,
# здесь — оба, поэтому и спрашивать надо у обоих.
# Переменная НЕ `i`: внутри mk_stand такой же `while read -r i`, и он затирал
# её — раздел печатал пустое имя и был зелёным по случайности, потому что
# пустая подстрока находится в любом выводе.
for _svc in awg2 awg3; do
    mk_stand
    rm -f "$AWG/$_svc.env"
    run_doctor > "$W/out"
    case "$(texts_of FAIL)$(texts_of WARN)" in
        *"$_svc.env"*) ok "пропажа у $_svc названа" ;;
        *) bad "пропажа <iface>.env у $_svc пропущена" \
               "датапас потеряет подсеть и не поставит MASQUERADE: $(texts_of FAIL)$(texts_of WARN)" ;;
    esac
done

# ═══════════════════════════════════════════════════════════════════════════
head_ "3. Клиенту выдан конфиг, а пира на сервере нет"
mk_stand
sed -i '/PUB_CLI_awg2$/d' "$AWG/awg2.conf"
run_doctor > "$W/out"
case "$(texts_of FAIL)$(texts_of WARN)" in
    *awg2*) ok "разлад клиента и сервера найден" ;;
    *) bad "клиент без пира пропущен" "ошибки: $(texts_of FAIL); замечания: $(texts_of WARN)" ;;
esac

# ═══════════════════════════════════════════════════════════════════════════
head_ "4. Интерфейс поднят НЕ из нынешнего конфига"
mk_stand
printf 'PUB_ЧУЖОЙ\n' > "$STUB_STATE/awg3.pub"
run_doctor > "$W/out"
case "$(texts_of FAIL)" in
    *awg3*"ДРУГОМУ ключу"*) ok "чужой ключ на интерфейсе найден" ;;
    *) bad "подмена ключа интерфейса пропущена" "$(texts_of FAIL)" ;;
esac

printf '\n'
[ "$fail" = 0 ] && echo "═══ ВСЁ ЗЕЛЁНОЕ ═══" || echo "═══ ЕСТЬ ПАДЕНИЯ ═══"
exit $fail
INNER
rc=$?
[ "$rc" = 0 ] || fail=1
exit $fail
