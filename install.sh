#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# install.sh — установщик VPN-сервера AmneziaWG 2.0 и 3.0.
#
# Ставится на чистый сервер одной командой и живёт сам по себе: свои
# интерфейсы, свои подсети, свой NAT, свой автозапуск. Никакими чужими
# сервисами не управляет и ни от чего не зависит.
#
# ДВА СЛОЯ
# --------
#   2.0 — kernel-модуль amneziawg. Работает с любыми клиентами AmneziaWG.
#   3.0 — userspace-демон amneziawg-go. Header protection, content padding,
#         рандомизация таймингов. Требует свежих клиентских приложений.
# Слои независимы: свои интерфейсы, порты и профили обфускации. Можно поднять
# любой из них или оба сразу и выдавать клиентам то, что понимает их приложение.
#
# Почему 3.0 не на модуле: kernel-модуль знает параметры только до 2.0, а
# awg-quick молча уходит в него, если модуль загружен. Поэтому датапас 3.0
# запускается явно через amneziawg-go.
#
# Флаги:
#   --awg 2|3|both    какие версии поднять (по умолчанию спросит)
#   --host HOST       домен или IP для Endpoint клиентских конфигов
#   --preset X --template Y --fp Z --mtu N   обфускация без вопросов
#   --ports A,B       зафиксировать UDP-порты (2.0,3.0), иначе рандомные
#   --dns "1.1.1.1, 8.8.8.8"   DNS, который получат клиенты
#   --no-bot          не спрашивать про Telegram-бота
#   --install-bot [токен chat_id]   доустановить бота после установки
#   --bot-token X / --bot-admins X  то же без интерактива
#   --remove-bot      удалить только бота
#   --update          обновить код и бинарники БЕЗ смены обфускации и клиентов
#   --reconfigure     новый профиль обфускации (клиентам нужны новые конфиги)
#   --uninstall       удалить всё, что поставил этот скрипт
#   --yes             не переспрашивать (для автоматизации)
#
# Без флагов на уже установленном сервере открывается меню.
set -euo pipefail

REPO_URL="https://github.com/blindtechnique/awg3"
REPO_BRANCH="${AWG_REPO_BRANCH:-main}"
DEST=/opt/awg3
AWG_DIR=/etc/amnezia/amneziawg
STATE="$DEST/install-state.env"
SERVICES="$AWG_DIR/services.env"
CLIENT_DIR="$DEST/clients"

# версии апстрима (переопределяются переменными окружения)
AWG_GO_REF="${AWG_GO_REF:-v3.0.1}"
AWG_TOOLS_REF="${AWG_TOOLS_REF:-v1.0.20260618-2}"
GO_VER="${GO_VER:-1.24.4}"
SRC=/opt/src

NO_BOT=0; RECONFIGURE=0; UPDATE=0; UNINSTALL=0
INSTALL_BOT=0; REMOVE_BOT=0; ASSUME_YES=0
CLI_VER=""; CLI_PRESET=""; CLI_TEMPLATE=""; CLI_FP=""; CLI_MTU=""; CLI_HOST=""
CLI_PORTS=""; CLI_DNS=""; CLI_BOT_TOKEN=""; CLI_BOT_ADMINS=""

# ── самозагрузка (curl | bash): клонируем репозиторий и перезапускаемся ──────
SELF="${BASH_SOURCE[0]:-$0}"
SELF_DIR="$(cd "$(dirname "$SELF")" 2>/dev/null && pwd || echo /nonexistent)"
if [ ! -f "$SELF_DIR/bin/awg-client.sh" ]; then
    if [ -n "${AWG_NO_BOOTSTRAP:-}" ]; then
        echo "[bootstrap] неполная структура репозитория" >&2; exit 1
    fi
    echo "[bootstrap] загружаю репозиторий…"
    command -v git >/dev/null 2>&1 || { apt-get update -y >/dev/null; apt-get install -y -qq git >/dev/null; }
    BOOT_DIR="$(mktemp -d)"
    git clone --depth 1 --branch "$REPO_BRANCH" "$REPO_URL" "$BOOT_DIR/repo"
    # Защита от CRLF: если файлы попали в репозиторий с Windows-машины, bash
    # спотыкается уже на первой строке — «: invalid option nameset: pipefail».
    find "$BOOT_DIR/repo" -type f \( -name '*.sh' -o -name '*.py' -o -name '*.service' \
        -o -name '*.timer' -o -name '*.template' \) -exec sed -i 's/\r$//' {} + 2>/dev/null || true
    exec env AWG_NO_BOOTSTRAP=1 bash "$BOOT_DIR/repo/install.sh" "$@"
fi
REPO_DIR="$SELF_DIR"

while [ $# -gt 0 ]; do
    case "$1" in
        --awg)        CLI_VER="$2"; shift 2 ;;
        --host|--endpoint) CLI_HOST="$2"; shift 2 ;;
        --preset)     CLI_PRESET="$2"; shift 2 ;;
        --template)   CLI_TEMPLATE="$2"; shift 2 ;;
        --fp)         CLI_FP="$2"; shift 2 ;;
        --mtu)        CLI_MTU="$2"; shift 2 ;;
        --ports)      CLI_PORTS="$2"; shift 2 ;;
        --dns)        CLI_DNS="$2"; shift 2 ;;
        --no-bot)     NO_BOT=1; shift ;;
        --install-bot) INSTALL_BOT=1; shift
                      [ $# -gt 0 ] && [ "${1#--}" = "$1" ] && { CLI_BOT_TOKEN="$1"; shift; }
                      [ $# -gt 0 ] && [ "${1#--}" = "$1" ] && { CLI_BOT_ADMINS="$1"; shift; } ;;
        --bot-token)  CLI_BOT_TOKEN="$2"; shift 2 ;;
        --bot-admins) CLI_BOT_ADMINS="$2"; shift 2 ;;
        --remove-bot) REMOVE_BOT=1; shift ;;
        --update)     UPDATE=1; shift ;;
        --reconfigure) RECONFIGURE=1; shift ;;
        --uninstall)  UNINSTALL=1; shift ;;
        --yes|-y)     ASSUME_YES=1; shift ;;
        -h|--help)    grep '^#' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) echo "Неизвестный флаг: $1" >&2; exit 2 ;;
    esac
done

log() { printf '\033[1;35m[install]\033[0m %s\n' "$*" >&2; }
err() { printf '\033[1;31m[install]\033[0m %s\n' "$*" >&2; }
installed() { [ -f "$SERVICES" ]; }

[ "$(id -u)" = 0 ] || { err "нужны права root"; exit 1; }

# ── ввод ─────────────────────────────────────────────────────────────────────
# /dev/tty может существовать, но не открываться (systemd-run, cron) — проверяем
# именно открытием, а не тестом файла.
has_tty() { (exec </dev/tty) 2>/dev/null; }

# Строго Y или N: любой другой ответ переспрашивается. Молчаливое «считаю за
# да» на вопросе об удалении данных — слишком дорогая ошибка.
ask_yn() {  # ask_yn "<вопрос>" <y|n по умолчанию>
    local q="$1" def="${2:-y}" a hint
    # --yes нужен для автоматизации: без терминала вопрос об удалении данных
    # иначе всегда трактуется как «нет», и скрипт молча ничего не делает
    [ "${ASSUME_YES:-0}" = 1 ] && return 0
    [ "$def" = y ] && hint="[Y/n]" || hint="[y/N]"
    has_tty || { [ "$def" = y ]; return; }
    while :; do
        printf '%s %s: ' "$q" "$hint" > /dev/tty
        read -r a < /dev/tty || { [ "$def" = y ]; return; }
        # tr не трогает кириллицу — переводим нужные буквы вручную
        a="$(printf '%s' "$a" | tr -d ' \t' | tr '[:upper:]' '[:lower:]' \
             | sed 's/Д/д/g; s/А/а/g; s/Н/н/g; s/Е/е/g; s/Т/т/g')"
        case "$a" in
            "")      [ "$def" = y ]; return ;;
            y|yes|д|да)  return 0 ;;
            n|no|н|нет)  return 1 ;;
            *) printf 'Ответь Y или N.\n' > /dev/tty ;;
        esac
    done
}

ask_pick() {  # ask_pick <имя_переменной> <по умолчанию> "<допустимые>"
    local __v="$1" def="$2" allowed="$3" a
    has_tty || { printf -v "$__v" '%s' "$def"; return; }
    while :; do
        printf 'Выбор [%s]: ' "$def" > /dev/tty
        read -r a < /dev/tty || a=""
        a="$(printf '%s' "$a" | tr -d ' \t')"
        [ -z "$a" ] && a="$def"
        case " $allowed " in *" $a "*) printf -v "$__v" '%s' "$a"; return ;; esac
        printf 'Допустимые варианты: %s\n' "$allowed" > /dev/tty
    done
}

ask_str() {  # ask_str <имя> "<подсказка>" "<дефолт>"
    local __v="$1" prompt="$2" def="${3:-}" a
    has_tty || { printf -v "$__v" '%s' "$def"; return; }
    printf '%s' "$prompt" > /dev/tty
    read -r a < /dev/tty || a=""
    a="$(printf '%s' "$a" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [ -z "$a" ] && a="$def"
    printf -v "$__v" '%s' "$a"
}

# ── порты ────────────────────────────────────────────────────────────────────
# ВНИМАНИЕ: у `ss -lunH` локальный адрес — четвёртая колонка. Пятая это peer
# («0.0.0.0:*»), и по ней список занятых портов всегда получается пустым.
busy_ports() { ss -lunH 2>/dev/null | awk '{print $4}' | grep -oE '[0-9]+$' | sort -u; }
valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }

pick_random_port() {  # pick_random_port <занятые через пробел>
    local extra="${1:-}" busy p i
    busy="$(busy_ports; printf '%s\n' $extra; echo 22; echo 53; echo 80; echo 443)"
    for i in $(seq 1 200); do
        p=$(( 20000 + RANDOM % 40000 ))
        echo "$busy" | grep -qx "$p" || { echo "$p"; return 0; }
    done
    echo 51820
}

# ── зависимости ──────────────────────────────────────────────────────────────
install_base_deps() {
    log "Пакеты: базовые зависимости…"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y -qq >/dev/null
    apt-get install -y -qq curl git make gcc iptables iproute2 qrencode \
        python3 python3-venv ca-certificates >/dev/null 2>&1 || \
        apt-get install -y -qq curl git make gcc iptables iproute2 python3 python3-venv >/dev/null
}

install_go() {
    if command -v go >/dev/null 2>&1; then
        log "Go уже установлен: $(go version | awk '{print $3}')"
        return 0
    fi
    local arch tgz url
    case "$(uname -m)" in
        x86_64|amd64) arch=amd64 ;;
        aarch64|arm64) arch=arm64 ;;
        *) err "неизвестная архитектура $(uname -m)"; return 1 ;;
    esac
    tgz="go${GO_VER}.linux-${arch}.tar.gz"
    url="https://go.dev/dl/${tgz}"
    log "Go ${GO_VER}: скачиваю…"
    curl -fsSL -o "/tmp/$tgz" "$url"
    rm -rf /usr/local/go
    tar -C /usr/local -xzf "/tmp/$tgz"
    rm -f "/tmp/$tgz"
    ln -sf /usr/local/go/bin/go /usr/local/bin/go
    ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt
    log "Go установлен: $(go version | awk '{print $3}')"
}

# amneziawg-tools нужны обоим слоям: ими читается состояние интерфейса и
# применяется конфиг (для 3.0 — всё, кроме собственно параметров 3.0).
install_tools() {
    if command -v awg >/dev/null 2>&1 && command -v awg-quick >/dev/null 2>&1; then
        log "amneziawg-tools уже установлены"
        return 0
    fi
    log "amneziawg-tools ($AWG_TOOLS_REF): сборка из исходников…"
    mkdir -p "$SRC"
    rm -rf "$SRC/amneziawg-tools"
    git clone --quiet --depth 1 --branch "$AWG_TOOLS_REF" \
        https://github.com/amnezia-vpn/amneziawg-tools.git "$SRC/amneziawg-tools" 2>/dev/null || \
        git clone --quiet --depth 1 https://github.com/amnezia-vpn/amneziawg-tools.git "$SRC/amneziawg-tools"
    make -s -C "$SRC/amneziawg-tools/src" -j"$(nproc)" >/dev/null
    make -s -C "$SRC/amneziawg-tools/src" install >/dev/null
    command -v awg >/dev/null || { err "awg не собрался"; return 1; }
    log "amneziawg-tools готовы: $(awg --version 2>&1 | head -1)"
}

# kernel-модуль нужен только слою 2.0
install_kmod() {
    if modinfo amneziawg >/dev/null 2>&1; then
        log "kernel-модуль amneziawg уже собран"
        modprobe amneziawg 2>/dev/null || true
        return 0
    fi
    log "kernel-модуль amneziawg: сборка DKMS…"
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y -qq dkms "linux-headers-$(uname -r)" build-essential >/dev/null 2>&1 || true
    mkdir -p "$SRC"
    rm -rf "$SRC/amneziawg-linux-kernel-module"
    git clone --quiet --depth 1 \
        https://github.com/amnezia-vpn/amneziawg-linux-kernel-module.git \
        "$SRC/amneziawg-linux-kernel-module"
    ( cd "$SRC/amneziawg-linux-kernel-module/src" && make -s >/dev/null && make -s install >/dev/null ) || {
        err "модуль не собрался — слой 2.0 недоступен"
        return 1
    }
    depmod -a || true
    modprobe amneziawg 2>/dev/null || true
    modinfo amneziawg >/dev/null 2>&1 || { err "модуль не загружается"; return 1; }
    log "kernel-модуль amneziawg готов"
}

# userspace-датапас нужен слою 3.0
install_awg_go() {
    if command -v amneziawg-go >/dev/null 2>&1; then
        log "amneziawg-go уже установлен"
        return 0
    fi
    install_go
    log "amneziawg-go ($AWG_GO_REF): сборка из исходников…"
    mkdir -p "$SRC"
    rm -rf "$SRC/amneziawg-go"
    git clone --quiet --depth 1 --branch "$AWG_GO_REF" \
        https://github.com/amnezia-vpn/amneziawg-go.git "$SRC/amneziawg-go" 2>/dev/null || \
        git clone --quiet --depth 1 https://github.com/amnezia-vpn/amneziawg-go.git "$SRC/amneziawg-go"
    ( cd "$SRC/amneziawg-go" && make -s >/dev/null )
    install -m0755 "$SRC/amneziawg-go/amneziawg-go" /usr/local/bin/amneziawg-go
    command -v amneziawg-go >/dev/null || { err "amneziawg-go не собрался"; return 1; }
    log "amneziawg-go готов"
}

# ── раскладка кода ───────────────────────────────────────────────────────────
deploy_files() {
    log "Раскладка в $DEST"
    mkdir -p "$DEST" "$CLIENT_DIR" "$AWG_DIR"
    cp "$REPO_DIR"/bin/*.sh "$REPO_DIR"/bin/*.py "$DEST/"
    cp "$REPO_DIR"/obfuscation/*.py "$DEST/"
    chmod +x "$DEST"/*.sh "$DEST"/*.py
    chmod 700 "$AWG_DIR"

    # Единая точка входа: `awg3` из-под root открывает меню. Имя специально не
    # `awg` — так зовётся утилита из amneziawg-tools, и перекрывать её нельзя.
    ln -sf "$DEST/awg-menu.sh"        /usr/local/bin/awg3
    ln -sf "$DEST/awg-client.sh"      /usr/local/bin/awg-client
    ln -sf "$DEST/awg-obfuscation.sh" /usr/local/bin/awg-obfuscation
    ln -sf "$DEST/awg-backup.sh"      /usr/local/bin/awg-backup
    ln -sf "$DEST/awg-doctor.sh"      /usr/local/bin/awg-doctor

    cp "$REPO_DIR/systemd/awg3@.service" /etc/systemd/system/
    cp "$REPO_DIR/systemd/awg-stats.service" "$REPO_DIR/systemd/awg-stats.timer" \
       "$REPO_DIR/systemd/awg-expire.service" "$REPO_DIR/systemd/awg-expire.timer" \
       /etc/systemd/system/ 2>/dev/null || true
    systemctl daemon-reload

    # ревизия кода — для проверки обновлений
    ( rev="$(git -C "$REPO_DIR" rev-parse --short=12 HEAD 2>/dev/null)"
      [ -n "$rev" ] && echo "$rev" > "$DEST/.rev" ) 2>/dev/null || true
    echo "$REPO_BRANCH" > "$DEST/.branch"
}

# ── внешний адрес ────────────────────────────────────────────────────────────
detect_public_ip() {
    local ip
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' || true)"
    case "$ip" in 10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|"") ip="" ;; esac
    [ -n "$ip" ] || ip="$(curl -4 -fsS --max-time 10 https://api.ipify.org 2>/dev/null || true)"
    echo "$ip"
}

check_host_dns() {  # check_host_dns <домен> <наш IP>
    local host="$1" our="$2" got
    case "$host" in *[a-zA-Z]*) ;; *) return 0 ;; esac   # это IP — проверять нечего
    got="$(getent ahostsv4 "$host" 2>/dev/null | awk '{print $1; exit}')"
    [ -n "$got" ] || { err "домен $host не резолвится"; return 1; }
    [ "$got" = "$our" ] && return 0
    err "домен $host указывает на $got, а внешний адрес сервера — $our"
    return 1
}

resolve_endpoint() {
    local ip; ip="$(detect_public_ip)"
    if [ -n "$CLI_HOST" ]; then ENDPOINT="$CLI_HOST"; check_host_dns "$ENDPOINT" "$ip" || true; return 0; fi
    if [ -n "${ENDPOINT:-}" ]; then return 0; fi
    if ! has_tty; then ENDPOINT="$ip"; return 0; fi
    echo "═══════════════════════════════════════════════════════════════" > /dev/tty
    echo "  Адрес сервера для клиентских конфигов" > /dev/tty
    echo > /dev/tty
    echo "  Это то, что попадёт в Endpoint: домен или IP. Домен удобнее —" > /dev/tty
    echo "  при переезде сервера не придётся перевыпускать клиентов, и в" > /dev/tty
    echo "  трафике он выглядит естественнее голого адреса." > /dev/tty
    echo "  Enter — использовать IP $ip" > /dev/tty
    while :; do
        ask_str ENDPOINT "Домен или IP [$ip]: " "$ip"
        [ -n "$ENDPOINT" ] || ENDPOINT="$ip"
        if check_host_dns "$ENDPOINT" "$ip"; then break; fi
        ask_yn "Всё равно использовать «$ENDPOINT»?" n && break
    done
}

# ── план сервисов ────────────────────────────────────────────────────────────
plan_services() {
    # порты закрепляются навсегда: от них зависят все выданные конфиги
    if installed; then
        # shellcheck disable=SC1090
        . "$SERVICES"
        log "Параметры из $SERVICES (порты и подсети не меняются)"
        return 0
    fi
    local p2 p3
    if [ -n "$CLI_PORTS" ]; then
        p2="${CLI_PORTS%%,*}"; p3="${CLI_PORTS##*,}"
        valid_port "$p2" && valid_port "$p3" && [ "$p2" != "$p3" ] || {
            err "--ports: нужно два разных порта через запятую"; exit 2; }
    else
        p2="$(pick_random_port)"
        p3="$(pick_random_port "$p2")"
    fi
    IFACE2="${IFACE2:-awg2}"; IFACE3="${IFACE3:-awg3}"
    SUBNET2="${SUBNET2:-10.29.79}"; SUBNET3="${SUBNET3:-10.29.80}"
    PORT2="$p2"; PORT3="$p3"
    MTU2="${CLI_MTU:-1420}"; MTU3="${CLI_MTU:-1380}"
    DNS="${CLI_DNS:-1.1.1.1, 8.8.8.8}"
    WAN="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}')"
    log "Порты: 2.0 → $PORT2, 3.0 → $PORT3 (закрепляются навсегда)"
}

write_services() {
    umask 077
    {
        echo "# awg3 — план сервисов. Правится установщиком, не руками."
        echo "LAYER2='$LAYER2'"
        echo "LAYER3='$LAYER3'"
        echo "IFACE2='$IFACE2'"
        echo "IFACE3='$IFACE3'"
        echo "SUBNET2='$SUBNET2'"
        echo "SUBNET3='$SUBNET3'"
        echo "PORT2='$PORT2'"
        echo "PORT3='$PORT3'"
        echo "MTU2='$MTU2'"
        echo "MTU3='$MTU3'"
        # значения в кавычках: DNS содержит запятую и пробел, без кавычек
        # оболочка попыталась бы выполнить вторую часть как команду
        echo "DNS='$DNS'"
        echo "ENDPOINT='$ENDPOINT'"
        echo "WAN='$WAN'"
        echo "CLIENT_DIR='$CLIENT_DIR'"
    } > "$SERVICES"
    chmod 600 "$SERVICES"
}

# ── серверные интерфейсы ─────────────────────────────────────────────────────
build_iface() {  # build_iface <имя> <подсеть> <порт> <mtu> <слой>
    local name="$1" subnet="$2" port="$3" mtu="$4" layer="$5"
    local conf="$AWG_DIR/${name}.conf" priv="" peers=""
    if [ -f "$conf" ]; then
        # ключ сервера и peers переживают переустановку: иначе все выданные
        # клиенты разом перестанут подключаться
        priv="$(grep '^PrivateKey' "$conf" 2>/dev/null | head -1 | cut -d= -f2- | tr -d ' \t')"
        peers="$(awk '/^\[Peer\]/{p=1} p{print}' "$conf")"
    fi
    if [ -n "$priv" ] && printf '%s' "$priv" | awg pubkey >/dev/null 2>&1; then
        log "Интерфейс $name: ключ сервера сохранён"
    else
        priv="$(awg genkey)"
        log "Интерфейс $name: сгенерирован новый ключ"
    fi
    umask 077
    {
        echo "# awg3 — серверный интерфейс $name (слой ${layer}.0)"
        [ "$layer" = 3 ] && echo "# Параметры 3.0 лежат отдельно в ${name}.v3: awg setconf их не понимает."
        echo "[Interface]"
        echo "PrivateKey = $priv"
        echo "Address = ${subnet}.1/24"
        echo "ListenPort = $port"
        echo "MTU = $mtu"
        echo "__AWG_OBFUSCATION__"
        [ -n "$peers" ] && { echo; printf '%s\n' "$peers"; }
    } > "$conf"
    chmod 600 "$conf"

    {
        echo "SUBNET=${subnet}.0/24"
        echo "PORT=$port"
        echo "NAT=1"
        echo "MTU=$mtu"
        echo "WAN=$WAN"
    } > "$AWG_DIR/${name}.env"
    chmod 600 "$AWG_DIR/${name}.env"
}

# NAT и форвардинг для слоя 2.0 (у слоя 3.0 этим занимается awg-datapath.sh).
# Правила прописываются в PostUp/PostDown самого конфига, чтобы жить ровно
# столько, сколько поднят интерфейс.
add_nat_rules() {  # add_nat_rules <имя> <подсеть>
    # ВНИМАНИЕ: отдельными операторами. В одном `local a=… b=$a` bash делает
    # все имена локальными ДО присваиваний, и под set -u обращение к соседней
    # переменной падает с «unbound variable».
    local name="$1" subnet="$2"
    local conf="$AWG_DIR/${name}.conf"
    local tmp
    grep -q '^PostUp' "$conf" && return 0
    tmp="$(mktemp)"
    awk -v net="${subnet}.0/24" -v wan="$WAN" -v ifc="$name" '
        /^MTU/ {
            print
            print "PostUp = sysctl -q -w net.ipv4.ip_forward=1"
            print "PostUp = iptables -w -t nat -A POSTROUTING -s " net " -o " wan " -j MASQUERADE"
            print "PostUp = iptables -w -A FORWARD -i " ifc " -j ACCEPT"
            print "PostUp = iptables -w -A FORWARD -o " ifc " -j ACCEPT"
            print "PostUp = iptables -w -t mangle -A FORWARD -i " ifc " -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu"
            print "PostDown = iptables -w -t nat -D POSTROUTING -s " net " -o " wan " -j MASQUERADE"
            print "PostDown = iptables -w -D FORWARD -i " ifc " -j ACCEPT"
            print "PostDown = iptables -w -D FORWARD -o " ifc " -j ACCEPT"
            print "PostDown = iptables -w -t mangle -D FORWARD -i " ifc " -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu"
            next
        }
        { print }' "$conf" > "$tmp"
    mv "$tmp" "$conf"; chmod 600 "$conf"
}

build_interfaces() {
    [ "$LAYER2" = 1 ] && { build_iface "$IFACE2" "$SUBNET2" "$PORT2" "$MTU2" 2; add_nat_rules "$IFACE2" "$SUBNET2"; }
    [ "$LAYER3" = 1 ] && build_iface "$IFACE3" "$SUBNET3" "$PORT3" "$MTU3" 3
    return 0
}

# ── обфускация ───────────────────────────────────────────────────────────────
gen_obfuscation() {
    local P="${AWG_PRESET:-medium}" T="${AWG_TEMPLATE:-}" F="${AWG_FP:-chrome}"
    if [ "$LAYER2" = 1 ]; then
        log "Профиль обфускации 2.0: preset=$P template=${T:-default}"
        AWG_CONFS="$AWG_DIR/${IFACE2}.conf" "$DEST/awg-obfuscation.sh" \
            --preset "$P" ${T:+--template "$T"} --fp "$F" --mtu "$MTU2" \
            ${ENDPOINT:+--host "$ENDPOINT"} --apply
    fi
    if [ "$LAYER3" = 1 ]; then
        log "Профиль обфускации 3.0: preset=$P template=${T:-default}"
        AWG_CONFS="$AWG_DIR/${IFACE3}.conf" "$DEST/awg-obfuscation.sh" --v3 \
            --preset "$P" ${T:+--template "$T"} --fp "$F" --mtu "$MTU3" \
            ${ENDPOINT:+--host "$ENDPOINT"} --apply
    fi
}

enable_units() {
    if [ "$LAYER2" = 1 ]; then
        systemctl enable "awg-quick@${IFACE2}" >/dev/null 2>&1 || true
        systemctl stop "awg-quick@${IFACE2}" 2>/dev/null || true
        ip link del "$IFACE2" 2>/dev/null || true
        systemctl start "awg-quick@${IFACE2}" || err "слой 2.0 не стартовал — journalctl -u awg-quick@${IFACE2}"
    fi
    if [ "$LAYER3" = 1 ]; then
        systemctl enable "awg3@${IFACE3}" >/dev/null 2>&1 || true
        systemctl stop "awg3@${IFACE3}" 2>/dev/null || true
        ip link del "$IFACE3" 2>/dev/null || true
        systemctl start "awg3@${IFACE3}" || {
            err "слой 3.0 не стартовал. Последние строки журнала:"
            journalctl -u "awg3@${IFACE3}" -n 12 --no-pager 2>/dev/null | sed 's/^/    /' >&2
        }
    fi
    # статистика и авто-удаление временных клиентов
    systemctl enable --now awg-stats.timer >/dev/null 2>&1 || true
    systemctl enable --now awg-expire.timer >/dev/null 2>&1 || true
}

setup_stats() {
    [ -d "$DEST/venv" ] || python3 -m venv "$DEST/venv" >/dev/null 2>&1 || true
    "$DEST/venv/bin/pip" install -q --upgrade pip >/dev/null 2>&1 || true
    "$DEST/venv/bin/pip" install -q segno >/dev/null 2>&1 || true
    "$DEST/venv/bin/python" "$DEST/awg_stats.py" init 2>/dev/null || \
        python3 "$DEST/awg_stats.py" init 2>/dev/null || true
}

# ── Telegram-бот ─────────────────────────────────────────────────────────────
_deploy_bot() {  # _deploy_bot <токен> <админы>
    local token="$1" admins="$2"
    log "Установка бота…"
    mkdir -p "$DEST/bot"
    cp "$REPO_DIR/bot/awg_bot.py" "$DEST/bot/"
    [ -d "$DEST/venv" ] || python3 -m venv "$DEST/venv"
    "$DEST/venv/bin/pip" install -q -r "$REPO_DIR/bot/requirements.txt"
    # Токен — это пароль от сервера, а юниты в /etc/systemd/system читаются
    # всеми. Поэтому переменные бота лежат в отдельном файле с правами 600.
    umask 077
    {
        echo "# Создано install.sh $(date -u +%FT%TZ). Права 600: здесь токен."
        sed -e "s#PASTE_TOKEN_HERE#${token}#" \
            -e "s#^AWG_BOT_ADMINS=.*#AWG_BOT_ADMINS=${admins}#" \
            "$REPO_DIR/bot/bot.env.template" | grep -v '^#'
        echo "AWG_INSTALL_SH_URL=https://raw.githubusercontent.com/blindtechnique/awg3/${REPO_BRANCH}/install.sh"
    } > "$DEST/bot.env"
    chmod 600 "$DEST/bot.env"
    cp "$REPO_DIR/systemd/awg-bot.service" /etc/systemd/system/awg-bot.service
    systemctl daemon-reload
    systemctl enable --now awg-bot
    if [ -f "$STATE" ]; then
        sed -i "s#^AWG_BOT_INSTALL=.*#AWG_BOT_INSTALL='1'#" "$STATE" 2>/dev/null \
            || echo "AWG_BOT_INSTALL='1'" >> "$STATE"
    fi
    log "Бот запущен. Напиши ему /start"
}

install_bot_only() {
    installed || { err "сначала установка: bash install.sh"; exit 1; }
    local t="$CLI_BOT_TOKEN" a="$CLI_BOT_ADMINS"
    [ -n "$t" ] || ask_str t "Токен бота (от @BotFather): " ""
    [ -n "$a" ] || ask_str a "Твой chat_id (узнать: @userinfobot): " ""
    [ -n "$t" ] && [ -n "$a" ] || { err "нужны и токен, и chat_id"; exit 2; }
    _deploy_bot "$t" "$a"
}

remove_bot_only() {
    systemctl disable --now awg-bot 2>/dev/null || true
    rm -f /etc/systemd/system/awg-bot.service "$DEST/bot.env"
    rm -rf "$DEST/bot"
    systemctl daemon-reload
    if [ -f "$STATE" ]; then sed -i "s#^AWG_BOT_INSTALL=.*#AWG_BOT_INSTALL='0'#" "$STATE" 2>/dev/null || true; fi
    log "Бот удалён. Сервер и клиенты не тронуты."
}

ask_bot() {
    [ "$NO_BOT" = 1 ] && return 0
    BOT_INSTALL=0; BOT_TOKEN=""; BOT_ADMINS=""
    has_tty || return 0
    echo > /dev/tty
    echo "Telegram-бот управляет клиентами, показывает статистику и делает" > /dev/tty
    echo "бэкапы прямо из чата. Можно поставить позже: install.sh --install-bot" > /dev/tty
    ask_yn "Поставить Telegram-бота?" n || return 0
    ask_str BOT_TOKEN "Токен бота (от @BotFather): " ""
    ask_str BOT_ADMINS "Твой chat_id (узнать: @userinfobot): " ""
    [ -n "$BOT_TOKEN" ] && [ -n "$BOT_ADMINS" ] && BOT_INSTALL=1 || \
        log "Токен или chat_id пуст — бот пропущен"
}

# ── опрос параметров ─────────────────────────────────────────────────────────
ask_params() {
    if [ -f "$STATE" ] && [ "$RECONFIGURE" != 1 ]; then
        # shellcheck disable=SC1090
        . "$STATE"
        log "Использую сохранённые ответы (обфускация ${AWG_PRESET:-medium}/${AWG_TEMPLATE:-default}). Сброс: --reconfigure"
        return 0
    fi
    local VER_CHOICE PRESET=medium TEMPLATE="" FP=chrome
    AWG_VER="${CLI_VER:-}"
    if [ -z "$AWG_VER" ] && has_tty; then
        echo "═══════════════════════════════════════════════════════════════" > /dev/tty
        echo "  Какую версию AmneziaWG поднять?" > /dev/tty
        echo > /dev/tty
        echo "   1) 2.0        — kernel-модуль. Работает с любыми клиентами" > /dev/tty
        echo "                   AmneziaWG, включая старые сборки." > /dev/tty
        echo "   2) 3.0        — header protection, content padding, рандомные" > /dev/tty
        echo "                   тайминги. Датапас userspace (amneziawg-go)." > /dev/tty
        echo "                   Нужны свежие клиентские приложения." > /dev/tty
        echo "   3) обе сразу  — два независимых слоя [по умолчанию]." > /dev/tty
        echo "                   Клиент заводится в нужный одной командой." > /dev/tty
        ask_pick VER_CHOICE 3 "1 2 3"
        case "$VER_CHOICE" in 1) AWG_VER=2 ;; 2) AWG_VER=3 ;; *) AWG_VER=both ;; esac
    fi
    [ -n "$AWG_VER" ] || AWG_VER=both
    case "$AWG_VER" in 2|3|both) ;; *) log "неизвестное --awg '$AWG_VER', беру both"; AWG_VER=both ;; esac

    if [ -n "$CLI_PRESET" ]; then
        PRESET="$CLI_PRESET"; TEMPLATE="$CLI_TEMPLATE"; FP="${CLI_FP:-chrome}"
    elif has_tty; then
        echo > /dev/tty
        echo "═══════════════════════════════════════════════════════════════" > /dev/tty
        echo "  Обфускация — сколько «шума» добавлять" > /dev/tty
        echo > /dev/tty
        echo "   1) router    — минимум. Слабые роутеры-клиенты, мобильный интернет" > /dev/tty
        echo "   2) low       — лёгкая. Провайдер почти не мешает" > /dev/tty
        echo "   3) medium    — сбалансированно [по умолчанию]" > /dev/tty
        echo "   4) high      — агрессивный провайдер режет WireGuard" > /dev/tty
        echo "   5) paranoid  — жёсткие блокировки, максимум маскировки" > /dev/tty
        ask_pick P 3 "1 2 3 4 5"
        case "$P" in 1) PRESET=router ;; 2) PRESET=low ;; 4) PRESET=high ;; 5) PRESET=paranoid ;; *) PRESET=medium ;; esac
        echo > /dev/tty
        echo "  Под какой протокол маскировать пакеты:" > /dev/tty
        echo "   0) авто [по умолчанию]  1) quic  2) tls  3) web  4) voip  5) dns  6) mixed" > /dev/tty
        ask_pick T 0 "0 1 2 3 4 5 6"
        case "$T" in 1) TEMPLATE=quic ;; 2) TEMPLATE=tls ;; 3) TEMPLATE=web ;; 4) TEMPLATE=voip ;; 5) TEMPLATE=dns ;; 6) TEMPLATE=mixed ;; *) TEMPLATE="" ;; esac
    fi

    resolve_endpoint
    ask_bot

    umask 077
    mkdir -p "$DEST"
    {
        echo "AWG_VER='$AWG_VER'"
        echo "AWG_PRESET='$PRESET'"
        echo "AWG_TEMPLATE='$TEMPLATE'"
        echo "AWG_FP='$FP'"
        echo "AWG_ENDPOINT='$ENDPOINT'"
        echo "AWG_BOT_INSTALL='${BOT_INSTALL:-0}'"
        echo "AWG_BOT_TOKEN='${BOT_TOKEN:-}'"
        echo "AWG_BOT_ADMINS='${BOT_ADMINS:-}'"
    } > "$STATE"
    chmod 600 "$STATE"
}

# ── удаление ─────────────────────────────────────────────────────────────────
uninstall_all() {
    installed || log "Похоже, ничего не установлено — почищу остатки"
    # shellcheck disable=SC1090
    [ -f "$SERVICES" ] && . "$SERVICES" 2>/dev/null || true
    echo
    log "Будет удалено:"
    log "  • сервисы awg-quick@${IFACE2:-awg2}, awg3@${IFACE3:-awg3}, бот, таймеры"
    log "  • интерфейсы и правила NAT"
    log "  • ВСЕ клиентские конфиги и ключи сервера ($AWG_DIR, $CLIENT_DIR)"
    log "  • статистика, бэкап-состояние, $DEST"
    log "  • бинарники amneziawg-go и amneziawg-tools, исходники в $SRC"
    echo
    if ! ask_yn "Удалить всё это безвозвратно?" n; then log "Отменено"; exit 0; fi

    for i in "${IFACE2:-awg2}"; do
        systemctl disable --now "awg-quick@$i" 2>/dev/null || true
        ip link del "$i" 2>/dev/null || true
    done
    for i in "${IFACE3:-awg3}"; do
        systemctl disable --now "awg3@$i" 2>/dev/null || true
        ip link del "$i" 2>/dev/null || true
    done
    systemctl disable --now awg-bot awg-stats.timer awg-expire.timer 2>/dev/null || true
    rm -f /etc/systemd/system/awg3@.service /etc/systemd/system/awg-bot.service \
          /etc/systemd/system/awg-stats.* /etc/systemd/system/awg-expire.*
    systemctl daemon-reload

    # правила NAT, которые могли остаться от невыгруженного интерфейса
    for s in "${SUBNET2:-}" "${SUBNET3:-}"; do
        [ -n "$s" ] || continue
        while iptables -w -t nat -C POSTROUTING -s "${s}.0/24" -o "${WAN:-eth0}" -j MASQUERADE 2>/dev/null; do
            iptables -w -t nat -D POSTROUTING -s "${s}.0/24" -o "${WAN:-eth0}" -j MASQUERADE
        done
    done

    rm -f /usr/local/bin/awg3 /usr/local/bin/awg-client /usr/local/bin/awg-obfuscation \
          /usr/local/bin/awg-backup /usr/local/bin/awg-doctor
    rm -rf "$DEST" "$AWG_DIR" "$SRC/amneziawg-go" "$SRC/amneziawg-tools" \
           "$SRC/amneziawg-linux-kernel-module"
    # родительские каталоги убираем, только если они опустели: там может лежать
    # чужое (например другой продукт Amnezia)
    rmdir "$(dirname "$AWG_DIR")" "$SRC" 2>/dev/null || true
    rm -f /usr/local/bin/amneziawg-go
    # утилиты ставились через make install в /usr/bin
    rm -f /usr/bin/awg /usr/bin/awg-quick /usr/share/bash-completion/completions/awg \
          /usr/share/bash-completion/completions/awg-quick 2>/dev/null || true
    rm -f /usr/share/man/man8/awg.8* /usr/share/man/man8/awg-quick.8* 2>/dev/null || true
    modprobe -r amneziawg 2>/dev/null || true
    rm -rf /root/.cache/go-build /root/go 2>/dev/null || true
    log "✅ Удалено. Go и системные пакеты (git, make, gcc) остались — они общего назначения."
}

do_update() {
    installed || { err "нечего обновлять — сначала установка"; exit 1; }
    log "Обновление кода (обфускация, порты и клиенты НЕ трогаются)…"
    # shellcheck disable=SC1090
    . "$SERVICES"
    deploy_files
    setup_stats
    if [ -f /etc/systemd/system/awg-bot.service ]; then
        mkdir -p "$DEST/bot"; cp "$REPO_DIR/bot/awg_bot.py" "$DEST/bot/"
        [ -d "$DEST/venv" ] && "$DEST/venv/bin/pip" install -q -r "$REPO_DIR/bot/requirements.txt" 2>/dev/null || true
        systemctl restart awg-bot 2>/dev/null || true
        log "Бот обновлён и перезапущен"
    fi
    [ "${LAYER3:-0}" = 1 ] && install_awg_go
    log "✅ Готово. Выданные клиенты работают как раньше."
}

# ── меню при запуске без флагов на установленном сервере ─────────────────────
menu_installed() {
    echo "═══════════════════════════════════════════════════════════════"
    echo "  AmneziaWG уже установлен. Что делаем?"
    echo
    echo "   1) Обновить код (клиенты и обфускация не меняются) [по умолчанию]"
    echo "   2) Новый профиль обфускации (клиентам нужны новые конфиги)"
    echo "   3) Поставить/обновить Telegram-бота"
    echo "   4) Удалить Telegram-бота"
    echo "   5) Полностью удалить AmneziaWG"
    echo "   6) Выйти"
    local c; ask_pick c 1 "1 2 3 4 5 6"
    case "$c" in
        1) UPDATE=1 ;;
        2) RECONFIGURE=1 ;;
        3) INSTALL_BOT=1 ;;
        4) REMOVE_BOT=1 ;;
        5) UNINSTALL=1 ;;
        *) exit 0 ;;
    esac
}

# ── main ─────────────────────────────────────────────────────────────────────
main() {
    if [ "$UNINSTALL" = 1 ]; then uninstall_all; exit 0; fi
    if [ "$REMOVE_BOT" = 1 ]; then remove_bot_only; exit 0; fi
    if [ "$INSTALL_BOT" = 1 ]; then install_bot_only; exit 0; fi
    if [ "$UPDATE" = 1 ]; then do_update; exit 0; fi

    if installed && [ "$RECONFIGURE" != 1 ] && has_tty; then
        menu_installed
        if [ "$UNINSTALL" = 1 ]; then uninstall_all; exit 0; fi
        if [ "$REMOVE_BOT" = 1 ]; then remove_bot_only; exit 0; fi
        if [ "$INSTALL_BOT" = 1 ]; then install_bot_only; exit 0; fi
        if [ "$UPDATE" = 1 ]; then do_update; exit 0; fi
    fi

    install_base_deps
    ask_params
    # shellcheck disable=SC1090
    . "$STATE"
    case "$AWG_VER" in
        2)    LAYER2=1; LAYER3=0 ;;
        3)    LAYER2=0; LAYER3=1 ;;
        *)    LAYER2=1; LAYER3=1 ;;
    esac

    install_tools
    [ "$LAYER2" = 1 ] && { install_kmod || { err "слой 2.0 отключён: модуль не собрался"; LAYER2=0; }; }
    [ "$LAYER3" = 1 ] && install_awg_go
    [ "$LAYER2" = 0 ] && [ "$LAYER3" = 0 ] && { err "ни один слой не поднялся"; exit 1; }

    ENDPOINT="${AWG_ENDPOINT:-$ENDPOINT}"
    plan_services
    deploy_files
    write_services
    build_interfaces
    gen_obfuscation
    setup_stats
    enable_units
    "$DEST/awg-client.sh" regen-all 2>/dev/null || true

    if [ "${AWG_BOT_INSTALL:-0}" = 1 ] && [ -n "${AWG_BOT_TOKEN:-}" ]; then
        _deploy_bot "$AWG_BOT_TOKEN" "$AWG_BOT_ADMINS"
    fi

    echo
    log "✅ Готово. Адрес сервера: $ENDPOINT"
    [ "$LAYER2" = 1 ] && log "   слой 2.0: $IFACE2, порт $PORT2, подсеть ${SUBNET2}.0/24"
    [ "$LAYER3" = 1 ] && log "   слой 3.0: $IFACE3, порт $PORT3, подсеть ${SUBNET3}.0/24"
    echo
    log "Дальше — команда  awg3  (меню управления из-под root)."
    [ "$LAYER2" = 1 ] && log "  awg-client add myphone awg2   # клиент 2.0"
    [ "$LAYER3" = 1 ] && log "  awg-client add laptop  awg3   # клиент 3.0"
    log "  awg-doctor                    # проверка связности"
    return 0
}
main
