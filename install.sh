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
# Почему 3.0 не на модуле: параметры 3.0 kernel-модуль уже знает — апстрим влил
# их в master 30.07.2026 (PR #192). Но переезд отложен: на модуле 3.1 открыты
# регрессии #215 и amnezia-client #3043 — «хендшейк проходит, трафика нет»,
# причём и на ядре, и на userspace одинаково. Чистого тега модуля сейчас нет:
# в v3.0.20260805 use-after-free в send.c, а фикс попал только внутрь v3.1.
# Поэтому датапас 3.0 по-прежнему запускается явно через amneziawg-go.
#
# Флаги:
#   --awg 2|3|both    какие версии поднять (по умолчанию спросит)
#   --host HOST       домен или IP для Endpoint клиентских конфигов
#   --preset X --template Y --fp Z --mtu N   обфускация без вопросов
#   --preset3 X --template3 Y   обфускация ОТДЕЛЬНО для слоя 3.0. Пусто —
#                     как у 2.0. Пресеты router и low объявлены без header
#                     protection: на них слой 3.0 вырождается в 2.0.
#   --ports A,B       зафиксировать UDP-порты (2.0,3.0), иначе рандомные
#   --dns "1.1.1.1, 8.8.8.8"   DNS, который получат клиенты
#   --no-bot          не спрашивать про Telegram-бота
#   --install-bot [токен chat_id]   доустановить бота после установки
#   --bot-token X / --bot-admins X  то же без интерактива
#   --remove-bot      удалить только бота
#   --update          обновить код и бинарники БЕЗ смены обфускации и клиентов
#   --reconfigure     новый профиль обфускации (клиентам нужны новые конфиги)
#   --plan            показать, что сделает эта же команда, и выйти, ничего
#                     не изменив: --plan --update, --plan --reconfigure,
#                     --plan --reconfigure --awg 3. Без --reconfigure флаги
#                     --awg/--preset/--host не применяются ни в плане, ни в
#                     прогоне: параметры берутся из install-state.env.
#                     С --uninstall, --install-bot и --remove-bot НЕ сочетается —
#                     у этих операций отчёта нет, код возврата 2.
#                     По curl репозиторий всё равно клонируется во временный
#                     каталог: без исходников показывать нечего.
#   --uninstall       удалить всё, что поставил этот скрипт
#   --yes             не переспрашивать (для автоматизации)
#   --kmod3 / --no-kmod3   ОТКЛЮЧЕНЫ, выходят с кодом 2. Ветка feat/awg3
#                     удалена апстримом, а переезд слоя 3.0 в ядро отложен
#                     до закрытия регрессий (см. выше).
#
# Переменные окружения: AWG_GO_REF, AWG_TOOLS_REF, AWG_KMOD_SRC_REF, AWG_KMOD_REF
# переопределяют версии апстрима. AWG_KMOD_REF пуст по умолчанию: собранный
# kernel-модуль не трогается, пересборка только по явному указанию ревизии.
#
# ВНИМАНИЕ: через --update доезжает ТОЛЬКО AWG_GO_REF — do_update пересобирает
# один датапас и не вызывает ни install_tools, ни install_kmod. Утилиты и модуль
# меняются полным прогоном установщика (обфускация и клиенты при этом не
# трогаются, если не передан --reconfigure).
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
#
# amneziawg-go: v3.0.20260805 — последний тег серии 3.0. Относительно v3.0.2 это
# пять коммитов, из датапаса тронуты receive.go (1 строка) и send.go (10), там же
# фикс «keepalives are ignored». На 3.1 сознательно НЕ идём: kmod issue #215 и
# amnezia-client issue #3043 — обе «хендшейк проходит, трафика нет», обе открыты
# без ответа мейнтейнеров, и #3043 прямо сообщает, что userspace 3.1 и
# kernel-модуль 3.1 ведут себя одинаково.
AWG_GO_REF="${AWG_GO_REF:-v3.0.20260805}"
# Утилиты обязаны совпадать с модулем не версией, а КОДИРОВКОЙ атрибутов.
# Модуль v3.0.20260805 объявляет WG_GENL_VERSION 3 и держит H1..H4 в политике
# как NLA_U64 (netlink.c: policy и nla_get_u64). Утилиты v1.0.20260618-2 при
# genl-версии >= 2 клали H1..H4 СТРОКОЙ (макрос PUT_MAGIC_HEADER), то есть
# слали строку туда, где ждут u64. Утилиты 3.0 различают три случая: < 2 → u32,
# < 3 → строка, иначе u64 — против версии 3 это ровно то, что в политике.
#
# Для модулей версий 0..2 обе версии утилит шлют байт в байт одно и то же,
# поэтому серверы со старым модулем из PPA правка не задевает. Пересборка
# происходит только на ПОЛНОМ прогоне: --update утилит не касается (см. выше).
#
# Побочно эта версия умеет читать 3.x-ключи прямо из .conf (config.c: разбор
# HeaderProtectionKey и ContentPaddingAddition). Костыль с отдельным файлом
# .v3 через UAPI мы пока НЕ снимаем: он рабочий, а замена требует проверки на
# живом сервере.
AWG_TOOLS_REF="${AWG_TOOLS_REF:-v3.0.20260805}"
GO_VER="${GO_VER:-1.24.4}"
SRC=/opt/src
# Kernel-модуль: две РАЗНЫЕ переменные, и путать их нельзя.
#
# AWG_KMOD_SRC_REF — что клонировать, когда собирать всё-таки надо (чистая
# установка, обновление ядра). Пин обязателен: раньше клонировали без --branch,
# то есть master, а master с 30.07.2026 — это 3.1 с открытой регрессией #215
# («хендшейк проходит, трафика нет»), которая задевает и слой 2.0.
# Берём последний тег серии 3.0. Честно про цену: в нём есть use-after-free в
# send.c (is_keepalive читается после передачи буфера в UDP-стек, коммит
# ce16310), исправленный только внутри v3.1.20260812 — то есть чистого тега у
# апстрима сейчас нет вообще, и мы выбираем узкую гонку вместо гарантированной
# остановки трафика.
#
# AWG_KMOD_REF — принудительная пересборка на указанную ревизию. ПУСТО по
# умолчанию: уже собранный модуль не трогаем, даже если пин изменился. Так
# обновление кода установщика не утаскивает за собой датапас слоя 2.0.
AWG_KMOD_SRC_REF="${AWG_KMOD_SRC_REF:-v3.0.20260805}"
AWG_KMOD_REF="${AWG_KMOD_REF:-}"
KMOD_STAMP="$SRC/.amneziawg-kmod.ref"
KMOD3=0

NO_BOT=0; RECONFIGURE=0; UPDATE=0; UNINSTALL=0; PLAN=0
# Взводится, если конфиги клиентов пересоздать не удалось. Прогон при этом
# доводится до конца — сервер уже настроен, — но код возврата обязан быть
# ненулевым: «не подключится никто» с нулём автоматика читает как успех.
_regen_failed=0
INSTALL_BOT=0; REMOVE_BOT=0; ASSUME_YES=0
CLI_VER=""; CLI_PRESET=""; CLI_TEMPLATE=""; CLI_FP=""; CLI_MTU=""; CLI_HOST=""
# Слой 3.0 настраивается отдельно. Пусто = «взять как у 2.0» — так вели себя
# все установки, сделанные до появления раздельных пресетов.
CLI_PRESET3=""; CLI_TEMPLATE3=""
CLI_PORTS=""; CLI_DNS=""; CLI_BOT_TOKEN=""; CLI_BOT_ADMINS=""

# ── самозагрузка (curl | bash): клонируем репозиторий и перезапускаемся ──────
# Разбор флагов идёт ниже, а самозагрузка — выше него: при запуске по curl
# сухой прогон успевал поставить пакет и изменить машину раньше, чем что-то
# показать. Смотрим аргументы дёшево, до всякой работы.
PLAN_EARLY=0
for _a in "$@"; do [ "$_a" = --plan ] && PLAN_EARLY=1; done

SELF="${BASH_SOURCE[0]:-$0}"
SELF_DIR="$(cd "$(dirname "$SELF")" 2>/dev/null && pwd || echo /nonexistent)"
if [ ! -f "$SELF_DIR/bin/awg-client.sh" ]; then
    if [ -n "${AWG_NO_BOOTSTRAP:-}" ]; then
        echo "[bootstrap] неполная структура репозитория" >&2; exit 1
    fi
    echo "[bootstrap] загружаю репозиторий…"
    if [ "$PLAN_EARLY" = 1 ] && ! command -v git >/dev/null 2>&1; then
        echo "[bootstrap] --plan по curl требует git: ставить пакет ради отчёта" >&2
        echo "            значило бы изменить систему раньше, чем что-то показать." >&2
        echo "            apt-get install -y git — и повтори команду." >&2
        exit 2
    fi
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
        --preset3)    CLI_PRESET3="$2"; shift 2 ;;
        --template3)  CLI_TEMPLATE3="$2"; shift 2 ;;
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
        --plan)       PLAN=1; shift ;;
        --uninstall)  UNINSTALL=1; shift ;;
        --yes|-y)     ASSUME_YES=1; shift ;;
        # Режим отключён намеренно. Ветка feat/awg3 удалена апстримом после
        # мержа PR #192, и --kmod3 не просто падал на клонировании: сначала
        # срабатывал безпиновый фолбэк в install_tools и ставились утилиты из
        # master (сегодня это 3.1), затем гасились интерфейсы и делался rmmod,
        # и только потом всё обрывалось. На выходе — новые утилиты против
        # старого модуля, тот самый рассинхрон, ради которого ниже написано
        # предупреждение про зависание в D-состоянии.
        # echo, а не err(): цикл разбора аргументов выполняется ДО определения
        # log/err ниже по файлу — ровно поэтому и ветка «неизвестный флаг»
        # написана через echo.
        --kmod3|--no-kmod3)
            echo "$1 отключён: ветка feat/awg3 удалена апстримом (влита в master, PR #192)." >&2
            echo "Перевод слоя 3.0 в ядро отложен — kernel-модуль issue #215 и" >&2
            echo "amnezia-client issue #3043: хендшейк проходит, трафика нет." >&2
            exit 2 ;;
        -h|--help)    grep '^#' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) echo "Неизвестный флаг: $1" >&2; exit 2 ;;
    esac
done

log() { printf '\033[1;35m[install]\033[0m %s\n' "$*" >&2; }
err() { printf '\033[1;31m[install]\033[0m %s\n' "$*" >&2; }
installed() { [ -f "$SERVICES" ]; }

# Имя юнита слоя 3.0: в обычном режиме это userspace-датапас, в режиме --kmod3
# интерфейс поднимает тот же awg-quick, что и слой 2.0.
unit3() {
    if [ "${KMOD3:-0}" = 1 ]; then echo "awg-quick@${IFACE3:-awg3}"
    else echo "awg3@${IFACE3:-awg3}"; fi
}

[ "$(id -u)" = 0 ] || { err "нужны права root"; exit 1; }

# MTU проверяем ЗДЕСЬ и только здесь — на значении, которое набрал человек.
# Ниже по коду MTU приезжает из services.env на каждом прогоне, включая
# повторное применение профиля: отказ там сломал бы --update работающему
# серверу, а тихая подмена поменяла бы ему MTU. Уже записанное не трогаем.
#
# Почему вообще проверяем: раньше сверялось только «это число», и `--mtu 60`
# доезжал до генератора обфускации. Там потолок джанка (mtu-40) опускался ниже
# Jmin, и наружу уходила пара Jmin > Jmax. Не отвергает её никто — ни утилиты,
# ни ядро, — а модуль берёт размер джанка как get_random_u32_inclusive(jmin,
# jmax), требующий floor <= ceil. Инвариант генератор теперь держит сам, но
# принимать заведомо нерабочее значение всё равно незачем: 576 — классический
# минимум сборки IPv4, ниже туннель не поднимется ни у одного клиента; 1500 —
# несущий интерфейс, выше только гарантированная фрагментация.
if [ -n "$CLI_MTU" ] && ! { [[ "$CLI_MTU" =~ ^[0-9]+$ ]] \
        && [ "$CLI_MTU" -ge 576 ] && [ "$CLI_MTU" -le 1500 ]; }; then
    err "--mtu $CLI_MTU: нужно целое от 576 до 1500"
    exit 2
fi

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
# Спрашивают её двое: plan_services перед выбором портов и plan_report перед
# тем, как назвать их в отчёте. Второй вызов и есть смысл выделения: без него
# план хвалил «случайные свободные» там, где прогон откажет с кодом 2.
check_cli_ports() {  # 0, если --ports пуст или корректен
    [ -n "$CLI_PORTS" ] || return 0
    local p2="${CLI_PORTS%%,*}" p3="${CLI_PORTS##*,}"
    valid_port "$p2" && valid_port "$p3" && [ "$p2" != "$p3" ]
}

# Поле берём с конца, а не по номеру: `ss -lunH` печатает колонку Netid не
# на всех версиях iproute2 (при фильтре по одному протоколу она опускается),
# и жёсткий $4/$5 угадывает лишь на одной из раскладок. Локальный адрес —
# предпоследнее поле в любой. `|| true` обязателен: когда UDP-слушателей нет
# вовсе, grep не находит ничего и отдаёт 1, а pipefail протаскивает это в
# подстановку, где вызов стоит первым.
busy_ports() { ss -lunH 2>/dev/null | awk '{print $(NF-1)}' | grep -oE '[0-9]+$' | sort -u || true; }
valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }

pick_random_port() {  # pick_random_port <занятые через пробел>
    local extra="${1:-}" busy p i
    busy="$(busy_ports; printf '%s\n' $extra; echo 22; echo 53; echo 80; echo 443)"
    for i in $(seq 1 200); do
        p=$(( 20000 + RANDOM % 40000 ))
        # Без трубы намеренно. `echo "$busy" | grep -qx "$p"` под pipefail
        # отдаёт 141, когда совпадение нашлось в начале длинного списка: grep
        # выходит по первому совпадению, echo получает SIGPIPE. 141 ≠ 0, то
        # есть срабатывала ветка ||, и ЗАНЯТЫЙ порт объявлялся свободным — а на
        # первой установке он закрепляется навсегда и awg-quick падает на bind.
        # Измерено: rc=141 на списке в 100000 строк с совпадением в начале,
        # rc=0 на коротком (влезает в буфер трубы) — то есть на боевой машине
        # это выстреливало бы тем реже, чем труднее было бы поймать.
        case $'\n'"$busy"$'\n' in
            *$'\n'"$p"$'\n'*) ;;              # занят — берём следующий
            *) echo "$p"; return 0 ;;
        esac
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
    local ref="$AWG_TOOLS_REF"

    if command -v awg >/dev/null 2>&1 && command -v awg-quick >/dev/null 2>&1 \
       && [ -d "$SRC/amneziawg-tools" ]; then
        # Одной строки версии мало: собранное из ветки и собранное из тега
        # сообщают ОДНУ И ТУ ЖЕ версию, по `awg --version` их не различить.
        # Поэтому дополнительно спрашиваем у чекаута, из какой ревизии он сделан.
        # Без этой сверки утилиты, однажды собранные из ветки, уже никогда не
        # вернулись бы на пиновый тег — а это тот самый рассинхрон с модулем.
        local cur cur_ref
        # Суффикс «-2» — часть версии (v1.0.20260618-2), в шаблон он включён
        # `|| true` обязателен: под set -o pipefail grep без совпадения возвращает
        # 1, pipefail протаскивает это через пайплайн, и set -e убивает скрипт
        # прямо здесь — без единой строки в выводе. Ветка «${cur:-?}» ниже как
        # раз рассчитана на пустое значение, но без этой заплаты недостижима.
        cur="$(awg --version 2>&1 | grep -oE 'v[0-9][0-9.]*(-[0-9]+)?' | head -1 || true)"
        cur_ref="$(git -C "$SRC/amneziawg-tools" describe --tags --exact-match 2>/dev/null || true)"
        if [ "$cur" = "$AWG_TOOLS_REF" ] && [ "$cur_ref" = "$AWG_TOOLS_REF" ]; then
            log "amneziawg-tools $cur — актуальны"
            return 0
        fi
        if [ "$cur" = "$AWG_TOOLS_REF" ] && [ -n "$cur_ref" ]; then
            log "amneziawg-tools версии $cur, но собраны из $cur_ref → $AWG_TOOLS_REF: пересборка…"
        else
            log "amneziawg-tools ${cur:-?} → $AWG_TOOLS_REF: пересборка…"
        fi
    fi
    log "amneziawg-tools ($ref): сборка из исходников…"
    mkdir -p "$SRC"
    rm -rf "$SRC/amneziawg-tools"
    # Фолбэка «клонировать без --branch» здесь НЕТ намеренно: он обесценивал пин
    # и при недоступности тега тихо ставил master. Сегодня master — это 3.1, а
    # утилиты обязаны быть протокольно совместимы с модулем, иначе awg не
    # ошибается, а виснет намертво. Лучше честный отказ, чем такая подмена.
    git clone --quiet --depth 1 --branch "$ref" \
        https://github.com/amnezia-vpn/amneziawg-tools.git "$SRC/amneziawg-tools" || {
        err "не удалось получить amneziawg-tools @ $ref"; return 1; }
    make -s -C "$SRC/amneziawg-tools/src" -j"$(nproc)" >/dev/null
    make -s -C "$SRC/amneziawg-tools/src" install >/dev/null
    command -v awg >/dev/null || { err "awg не собрался"; return 1; }
    log "amneziawg-tools готовы: $(awg --version 2>&1 | head -1)"
}

# kernel-модуль нужен только слою 2.0
install_kmod() {
    local want="$AWG_KMOD_REF" have=""
    [ -f "$KMOD_STAMP" ] && have="$(cut -f1 "$KMOD_STAMP" 2>/dev/null || true)"

    # «Нужна ли пересборка» решаем по метке ревизии, которую пишем сами. Раньше
    # здесь стоял греп по исходникам на диске: искали WGDEVICE_A_HEADER_PROTECTION_KEY
    # и сравнивали результат с режимом. После влития PR #192 в master атрибут есть
    # ВСЕГДА, поэтому проверка «режим не совпал» стала вечно истинной — модуль
    # пересобирался на каждом запуске, каждый раз с rmmod и выходом «перезагрузи
    # сервер». Метка от исходников не зависит и врать не умеет.
    #
    # Пустой AWG_KMOD_REF означает «не трогать собранный модуль»: чистого тега
    # у апстрима сейчас нет (см. комментарий к AWG_KMOD_REF выше).
    if modinfo amneziawg >/dev/null 2>&1 && { [ -z "$want" ] || [ "$want" = "$have" ]; }; then
        # Сервер со сборкой от прошлых версий установщика метки не имеет, и сама
        # она бы не появилась никогда: этот ранний выход её не писал. Тогда
        # первый же осознанный пин на ТУ ЖЕ ревизию давал have="" != want и вёл
        # к пересборке с гашением интерфейсов на ровном месте. Проставляем задним
        # числом по тому, что реально лежит в исходниках.
        if [ -z "$have" ] && [ -d "$SRC/amneziawg-linux-kernel-module/.git" ]; then
            printf '%s\t%s\t%s\n' \
                "$(git -C "$SRC/amneziawg-linux-kernel-module" describe --tags --exact-match 2>/dev/null || echo 'неизвестно')" \
                "$(git -C "$SRC/amneziawg-linux-kernel-module" rev-parse --short HEAD 2>/dev/null || echo '?')" \
                "$(uname -r)" > "$KMOD_STAMP" 2>/dev/null || true
            have="$(cut -f1 "$KMOD_STAMP" 2>/dev/null || true)"
        fi
        log "kernel-модуль amneziawg уже собран (${have:-ревизия не помечена}) — не трогаю"
        modprobe amneziawg 2>/dev/null || true
        return 0
    fi
    # Сообщение говорило «сборка DKMS», хотя ниже идёт обычный make + make install
    # и dkms о модуле ничего не знает. Из-за этого диагностика советовала смотреть
    # `dkms status`, который всегда пуст. Пакет dkms ставим дальше по инерции —
    # он безвреден и пригодится, если сборку когда-нибудь переведут на него.
    log "kernel-модуль amneziawg${want:+ ($want)}: сборка из исходников…"
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y -qq dkms "linux-headers-$(uname -r)" build-essential >/dev/null 2>&1 || true
    [ -d "/lib/modules/$(uname -r)/build" ] || {
        err "нет заголовков ядра для $(uname -r) — собирать модуль нечем"
        err "apt-get install linux-headers-\$(uname -r)"
        return 1; }
    mkdir -p "$SRC"
    rm -rf "$SRC/amneziawg-linux-kernel-module"
    # --branch задаём ВСЕГДА. При пустом want подстановка ${want:+…} исчезала
    # целиком, и клонировался master — то есть ровно 3.1, которую этот же файл
    # объявляет негодной. Пустой AWG_KMOD_REF означает «не пересобирать», а не
    # «собрать что попало»: если сборка всё же нужна, берём пин AWG_KMOD_SRC_REF.
    local src_ref="${want:-$AWG_KMOD_SRC_REF}"
    git clone --quiet --depth 1 --branch "$src_ref" \
        https://github.com/amnezia-vpn/amneziawg-linux-kernel-module.git \
        "$SRC/amneziawg-linux-kernel-module" || {
        err "не удалось получить kernel-модуль @ $src_ref"; return 1; }

    # КОМПИЛИРУЕМ ДО того, как что-либо гасим. Раньше интерфейсы опускались и
    # делался rmmod ещё до make, и любой отказ сборки (GCC 14, свежее ядро,
    # отсутствие заголовков) оставлял слой 2.0 лежать, а систему — без модуля.
    make -s -C "$SRC/amneziawg-linux-kernel-module/src" >/dev/null || {
        err "модуль не собрался — интерфейсы не трогаю, слой 2.0 продолжает работать"
        return 1
    }

    # Только теперь подменяем: пока модуль загружен, rmmod не сработает при живом
    # интерфейсе, а в памяти останется прежняя версия — и разойдётся с утилитами
    # (разный формат netlink). Тогда awg не просто ошибётся, а зависнет в
    # непрерываемом ожидании (процессы в состоянии D, счётчик ссылок ломается).
    # Читаем /proc/modules напрямую, без трубы. `lsmod | grep -q` под pipefail
    # отдаёт 141: grep выходит по первому совпадению, а lsmod продолжает писать
    # и получает SIGPIPE. Условие if от 141 становится ЛОЖНЫМ, и весь блок ниже
    # — стоп юнитов, ip link del, rmmod — молча пропускается ровно на том
    # сервере, ради которого он написан: модуль загружен, идёт обновление.
    # Итог: новый .ko на диске, старый модуль в памяти, а утилиты уже
    # пересобраны — тот самый рассинхрон, от которого awg виснет намертво.
    # Измерено на производителе, пишущем построчно: 200 провалов из 200.
    # Пробел после имени обязателен: в /proc/modules первое поле — имя модуля.
    if grep -q '^amneziawg ' /proc/modules 2>/dev/null; then
        local i
        for i in "${IFACE2:-awg2}" "${IFACE3:-awg3}"; do
            systemctl stop "awg-quick@$i" "awg3@$i" 2>/dev/null || true
            ip link del "$i" 2>/dev/null || true
        done
        # ip link del освобождает netdev асинхронно — сразу следом rmmod иногда
        # даёт EBUSY на ровном месте. Гнать администратора в reboot из-за гонки
        # в доли секунды дорого, поэтому несколько попыток.
        local rmmod_ok=0
        for _ in 1 2 3 4 5; do
            rmmod amneziawg 2>/dev/null && { rmmod_ok=1; break; }
            sleep 1
        done
        if [ "$rmmod_ok" != 1 ]; then
            # Именно exit, а не return. Функция вызывается как `install_kmod || {…}`,
            # то есть set -e внутри неё подавлен, и return 1 отдал бы управление
            # обработчику, который просто снимает слой 2.0 и идёт дальше. А идти
            # дальше нельзя: интерфейсы уже погашены выше, install_tools уже мог
            # пересобрать утилиты, и в памяти остался прежний модуль — подниматься
            # на такой паре нельзя, awg зависнет в непрерываемом ожидании.
            err "модуль amneziawg не выгружается — что-то держит его."
            err "Интерфейсы ${IFACE2:-awg2}/${IFACE3:-awg3} уже погашены, новый модуль НЕ установлен."
            err "Утилиты могли быть пересобраны — продолжать нельзя."
            err "Перезагрузи сервер и запусти установку снова:  reboot"
            exit 1
        fi
    fi
    make -s -C "$SRC/amneziawg-linux-kernel-module/src" install >/dev/null || {
        err "установка модуля не удалась — слой 2.0 недоступен"
        return 1
    }
    depmod -a || true
    modprobe amneziawg 2>/dev/null || true
    modinfo amneziawg >/dev/null 2>&1 || { err "модуль не загружается"; return 1; }
    # В метку пишем ФАКТ, а не запрошенное: ревизию, из которой собрано, её SHA
    # и ядро, под которое собрано. Раньше сюда уходило пустое $want, и лог всегда
    # печатал «ревизия не помечена» — узнать, из какого кода собран .ko, было негде.
    printf '%s\t%s\t%s\n' "$src_ref" \
        "$(git -C "$SRC/amneziawg-linux-kernel-module" rev-parse --short HEAD 2>/dev/null || echo '?')" \
        "$(uname -r)" > "$KMOD_STAMP"
    log "kernel-модуль amneziawg готов ($src_ref)"
}

# userspace-датапас нужен слою 3.0
install_awg_go() {
    # Раньше здесь стояла просто проверка «бинарник есть — выходим», и из-за
    # неё --update никогда не подтягивал новую версию датапаса: проверка
    # обновлений сообщала о ней, а обновление ничего не делало.
    if command -v amneziawg-go >/dev/null 2>&1; then
        # `|| true` — см. пояснение в install_tools: без него grep без совпадения
        # обрывает установку молча.
        local cur; cur="$(amneziawg-go --version 2>&1 | grep -oE 'v[0-9][0-9.]*' | head -1 || true)"
        if [ "$cur" = "$AWG_GO_REF" ]; then
            log "amneziawg-go $cur — актуален"
            return 0
        fi
        log "amneziawg-go ${cur:-?} → $AWG_GO_REF: пересборка…"
        AWG_GO_REBUILT=1
    fi
    install_go
    log "amneziawg-go ($AWG_GO_REF): сборка из исходников…"
    mkdir -p "$SRC"
    rm -rf "$SRC/amneziawg-go"
    # Как и у tools, фолбэка без пина здесь нет. Для go он вреден вдвойне: без
    # тега git describe в Makefile не срабатывает, и бинарник сообщает
    # закоммиченную const Version — то есть `cur` никогда не совпадёт с
    # AWG_GO_REF, и каждый --update будет пересобирать датапас и дёргать awg3@.
    git clone --quiet --depth 1 --branch "$AWG_GO_REF" \
        https://github.com/amnezia-vpn/amneziawg-go.git "$SRC/amneziawg-go" || {
        err "не удалось получить amneziawg-go @ $AWG_GO_REF"; return 1; }
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
    # Сам установщик тоже кладём рядом: меню awg3 зовёт "$DEST/install.sh" для
    # удаления слоя и установки бота (bin/awg-menu.sh:280,282,320). Без этого
    # файла пункты 3, 4 и 13 всегда уходили в фолбэк, причём третий печатал
    # команду с пустым URL — его он берёт из $DEST/.url, которого тоже не было.
    cp "$REPO_DIR/install.sh" "$DEST/"
    chmod +x "$DEST"/*.sh "$DEST"/*.py
    chmod 700 "$AWG_DIR"

    # Единая точка входа: `awg3` из-под root открывает меню. Имя специально не
    # `awg` — так зовётся утилита из amneziawg-tools, и перекрывать её нельзя.
    ln -sf "$DEST/awg-menu.sh"        /usr/local/bin/awg3
    ln -sf "$DEST/awg-client.sh"      /usr/local/bin/awg-client
    ln -sf "$DEST/awg-obfuscation.sh" /usr/local/bin/awg-obfuscation
    ln -sf "$DEST/awg-backup.sh"      /usr/local/bin/awg-backup
    ln -sf "$DEST/awg-doctor.sh"      /usr/local/bin/awg-doctor
    # README обещает команду awg-upstream-check, и бот зовёт этот скрипт полным
    # путём — а в PATH его не было вовсе.
    ln -sf "$DEST/awg-upstream-check.sh" /usr/local/bin/awg-upstream-check

    cp "$REPO_DIR/systemd/awg3@.service" /etc/systemd/system/
    cp "$REPO_DIR/systemd/awg-stats.service" "$REPO_DIR/systemd/awg-stats.timer" \
       "$REPO_DIR/systemd/awg-expire.service" "$REPO_DIR/systemd/awg-expire.timer" \
       /etc/systemd/system/ 2>/dev/null || true
    systemctl daemon-reload

    # ревизия кода — для проверки обновлений
    ( rev="$(git -C "$REPO_DIR" rev-parse --short=12 HEAD 2>/dev/null)"
      [ -n "$rev" ] && echo "$rev" > "$DEST/.rev" ) 2>/dev/null || true
    echo "$REPO_BRANCH" > "$DEST/.branch"
    # URL, из которого ставились: меню подставляет его в подсказку, когда
    # установщика нет рядом.
    echo "$REPO_URL/raw/$REPO_BRANCH/install.sh" > "$DEST/.url"
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
    # getent отдаёт 2, когда имя не резолвится, — это штатный ответ, а не
    # авария. Без `|| true` присваивание умирало бы раньше строки ниже, и
    # сообщение «домен не резолвится» не печаталось бы никогда. Сейчас всех
    # вызывающих спасает то, что они зовут функцию в условии или через ||,
    # где errexit снят, — но это свойство вызывающего, а не этого кода.
    got="$(getent ahostsv4 "$host" 2>/dev/null | awk '{print $1; exit}' || true)"
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

# Итоговый адрес сервера. Вынесено в функцию, чтобы стенд вырезал её sed-ом.
#
# `--host` — ответ владельца в ЭТОМ прогоне, и он старше журнала: в
# install-state.env лежит адрес ПРОШЛОЙ установки, и на установленном сервере
# он непуст всегда. Без этого условия `--reconfigure --host НОВЫЙ` молча не
# работал: resolve_endpoint ставила новый адрес, следующая же строка возвращала
# старый, write_services писала старый, а «Готово. Адрес сервера:» печатало
# затёртое значение.
#
# Условие дословно то же, что у plan_report (CLI_HOST + RECONFIGURE): сухой
# прогон обещает смену ровно в этом случае, а без --reconfigure честно пишет
# --host в «проигнорировано». План и прогон обязаны говорить одно и то же.
endpoint_final() {
    if [ -n "${CLI_HOST:-}" ] && [ "${RECONFIGURE:-0}" = 1 ]; then
        printf '%s' "$CLI_HOST"
        return 0
    fi
    printf '%s' "${AWG_ENDPOINT:-${ENDPOINT:-}}"
}

# ── план сервисов ────────────────────────────────────────────────────────────
plan_services() {
    # порты закрепляются навсегда: от них зависят все выданные конфиги
    if installed; then
        # shellcheck disable=SC1090
        . "$SERVICES"
        # Режим --kmod3 отключён, поэтому сохранённое KMOD3='1' на сервере, где
        # его когда-то успели включить, здесь принудительно гасится: иначе слой
        # 3.0 остался бы ждать kernel-датапас, которого мы больше не ставим, и
        # install_awg_go не вызвался бы вовсе.
        if [ "${KMOD3:-0}" = 1 ]; then
            log "в $SERVICES остался KMOD3=1 от отключённого режима — возвращаю слой 3.0 на userspace"
        fi
        KMOD3=0
        # Дальше по этому пути имена ниже приезжают ТОЛЬКО из файла: ветка
        # «ещё не установлено» не выполняется, а write_services читает их
        # голыми. installed() — это просто [ -f "$SERVICES" ], поэтому сюда
        # попадает и чужой файл по тому же пути, и свой, обрезанный убитым
        # прогоном. Без проверки всё умирало под set -u уже ПОСЛЕ того, как
        # редирект `> "$SERVICES"` обрезал файл: восстановить нечего,
        # installed() по-прежнему true, и каждый следующий запуск падает там же.
        # Поэтому проверяем ДО первой записи.
        local k miss=""
        for k in IFACE2 IFACE3 SUBNET2 SUBNET3 PORT2 PORT3; do
            [ -n "${!k+x}" ] || miss="$miss $k"
        done
        if [ -n "$miss" ]; then
            err "$SERVICES существует, но это не план awg3: нет ключей$miss"
            err "Похоже, файл оставил другой установщик или прошлый прогон убили."
            err "Убери его с пути и запусти снова:  mv $SERVICES $SERVICES.foreign"
            err "Порты и подсети будут выбраны заново — выданные конфиги перестанут"
            err "подключаться, поэтому сам файл мы не трогаем."
            exit 1
        fi
        # А это дописываем молча: старые установки могли не знать этих ключей,
        # и отказ из-за них был бы отказом в обновлении на ровном месте.
        # Порт и подсеть так восстанавливать НЕЛЬЗЯ — от них зависят конфиги.
        MTU2="${MTU2:-1420}"; MTU3="${MTU3:-1380}"
        DNS="${DNS:-1.1.1.1, 8.8.8.8}"
        WAN="${WAN:-$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}' || true)}"
        log "Параметры из $SERVICES (порты и подсети не меняются)"
        return 0
    fi
    local p2 p3
    if [ -n "$CLI_PORTS" ]; then
        check_cli_ports || { err "--ports: нужно два разных порта через запятую"; exit 2; }
        p2="${CLI_PORTS%%,*}"; p3="${CLI_PORTS##*,}"
    else
        p2="$(pick_random_port)"
        p3="$(pick_random_port "$p2")"
    fi
    IFACE2="${IFACE2:-awg2}"; IFACE3="${IFACE3:-awg3}"
    SUBNET2="${SUBNET2:-10.29.79}"; SUBNET3="${SUBNET3:-10.29.80}"
    PORT2="$p2"; PORT3="$p3"
    MTU2="${CLI_MTU:-1420}"; MTU3="${CLI_MTU:-1380}"
    DNS="${CLI_DNS:-1.1.1.1, 8.8.8.8}"
    # `|| true`: под pipefail статус приезжает от ip, а не от awk. На хосте без
    # маршрута по умолчанию (IPv6-only, контейнер) ip отдаёт 2 и убивал первую
    # установку прямо здесь. Пустой WAN законен — он лишь подсказка для NAT.
    WAN="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}' || true)"
    log "Порты: 2.0 → $PORT2, 3.0 → $PORT3 (закрепляются навсегда)"
}

write_services() {
    # Дойти сюда в режиме --plan можно только по ошибке в коде. Записать молча
    # значило бы соврать: пользователь просил показать, а не сделать.
    if [ "$PLAN" = 1 ]; then
        err "внутренняя ошибка: запись services.env в режиме --plan"
        exit 1
    fi
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
        # KMOD3=1 — слой 3.0 обслуживается kernel-модулем, а не amneziawg-go.
        # От этого зависят имя юнита, способ применения параметров 3.0 и
        # проверки в диагностике, поэтому значение живёт здесь.
        echo "KMOD3='$KMOD3'"
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
        # `|| true` обязателен: под pipefail грep без совпадения отдаёт 1, и
        # присваивание убивало прогон молча. Ветка «ключа нет — генерируем»
        # ниже была недостижима именно тогда, когда она и нужна: конфиг есть,
        # а PrivateKey в нём нет.
        priv="$(grep '^PrivateKey' "$conf" 2>/dev/null | head -1 | cut -d= -f2- | tr -d ' \t' || true)"
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
    if [ "$LAYER3" = 1 ]; then
        build_iface "$IFACE3" "$SUBNET3" "$PORT3" "$MTU3" 3
        # В режиме ядра интерфейс поднимает awg-quick, и NAT некому настроить —
        # прописываем правила в сам конфиг, как для слоя 2.0. В обычном режиме
        # этим занимается awg-datapath.sh при старте демона.
        [ "$KMOD3" = 1 ] && add_nat_rules "$IFACE3" "$SUBNET3"
    fi
    return 0
}

# ── обфускация ───────────────────────────────────────────────────────────────
# Решение «сохранить профиль или выпустить новый» — одно на реальный прогон
# и на --plan. Две копии условия разошлись бы, а отчёт, разошедшийся с делом,
# хуже отсутствующего отчёта: ему верят.
obf_mode() {  # obf_mode <файл профиля> → --apply | --reapply
    if [ "$RECONFIGURE" != 1 ] && [ -s "$1" ]; then echo --reapply; else echo --apply; fi
}

gen_obfuscation() {
    local P="${AWG_PRESET:-medium}" T="${AWG_TEMPLATE:-}" F="${AWG_FP:-chrome}"
    # Пусто — слой 3.0 настраивается как 2.0. Именно так выглядит state всех
    # установок, сделанных до появления раздельных пресетов: в нём только
    # AWG_PRESET, и молча менять им профиль нельзя — это перевыпуск клиентов.
    local P3="${AWG_PRESET3:-$P}" T3="${AWG_TEMPLATE3:-$T}"
    # Новый профиль генерируем ТОЛЬКО по явному --reconfigure. Во всех прочих
    # случаях он уже согласован с выданными клиентами и его достаточно разложить
    # заново.
    #
    # Раньше --reapply включался лишь при MODE_SWITCH=1, то есть только вместе с
    # --kmod3/--no-kmod3. Любой другой неинтерактивный полный прогон — cron,
    # ansible, `ssh host 'bash -s' < install.sh` — уходил в --apply, генерировал
    # новый случайный профиль и убивал все выданные конфиги разом.
    #
    # Файл проверяем ДЛЯ КАЖДОГО СЛОЯ отдельно: профили у них разные
    # (obfuscation.env и obfuscation3.env), и общая проверка по первому
    # перевыпускала клиентов слоя 3.0 на установке, где стоит только он.
    local mode2 mode3
    mode2="$(obf_mode "$AWG_DIR/obfuscation.env")"
    mode3="$(obf_mode "$AWG_DIR/obfuscation3.env")"
    if [ "$LAYER2" = 1 ]; then
        log "Профиль обфускации 2.0: preset=$P template=${T:-default}"
        AWG_CONFS="$AWG_DIR/${IFACE2}.conf" "$DEST/awg-obfuscation.sh" \
            --preset "$P" ${T:+--template "$T"} --fp "$F" --mtu "$MTU2" \
            ${ENDPOINT:+--host "$ENDPOINT"} "$mode2"
    fi
    if [ "$LAYER3" = 1 ]; then
        log "Профиль обфускации 3.0: preset=$P3 template=${T3:-default}"
        AWG_CONFS="$AWG_DIR/${IFACE3}.conf" "$DEST/awg-obfuscation.sh" --v3 \
            --preset "$P3" ${T3:+--template "$T3"} --fp "$F" --mtu "$MTU3" \
            ${ENDPOINT:+--host "$ENDPOINT"} "$mode3"
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
        local u3; u3="$(unit3)"
        # при смене режима второй юнит нужно погасить, иначе два сервиса
        # будут драться за один интерфейс
        systemctl disable --now "awg3@${IFACE3}" 2>/dev/null || true
        [ "$KMOD3" = 1 ] || systemctl disable --now "awg-quick@${IFACE3}" 2>/dev/null || true
        # погашенный юнит может остаться в состоянии failed и мозолить глаза
        # в systemctl status — сбрасываем, он больше не используется
        systemctl reset-failed "awg3@${IFACE3}" "awg-quick@${IFACE3}" 2>/dev/null || true
        systemctl enable "$u3" >/dev/null 2>&1 || true
        systemctl stop "$u3" 2>/dev/null || true
        ip link del "$IFACE3" 2>/dev/null || true
        systemctl start "$u3" || {
            err "слой 3.0 не стартовал. Последние строки журнала:"
            journalctl -u "$u3" -n 12 --no-pager 2>/dev/null | sed 's/^/    /' >&2
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
    if [ "$PLAN" = 1 ]; then
        err "внутренняя ошибка: опрос параметров в режиме --plan"
        exit 1
    fi
    if [ -f "$STATE" ] && [ "$RECONFIGURE" != 1 ]; then
        # shellcheck disable=SC1090
        . "$STATE"
        log "Использую сохранённые ответы (обфускация ${AWG_PRESET:-medium}/${AWG_TEMPLATE:-default}). Сброс: --reconfigure"
        return 0
    fi
    local VER_CHOICE PRESET=medium TEMPLATE="" FP=chrome
    local PRESET3="" TEMPLATE3=""      # пусто = как у слоя 2.0
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
        PRESET3="$CLI_PRESET3"; TEMPLATE3="$CLI_TEMPLATE3"
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
        # У слоя 3.0 «интенсивность» значит другое: router и low объявлены без
        # header protection, паддинга и таймингов, то есть на них 3.0 отдаёт
        # ровно то же, что 2.0, и отдельный слой теряет смысл. Спрашиваем
        # отдельно и говорим об этом прямо — иначе человек ставит слой 3.0,
        # получает профиль без его главных признаков и идёт искать поломку.
        if [ "$AWG_VER" != 2 ]; then
            echo > /dev/tty
            echo "  Обфускация слоя 3.0 — отдельно от слоя 2.0" > /dev/tty
            echo > /dev/tty
            echo "   1) router    2) low    3) medium [по умолчанию]" > /dev/tty
            echo "   4) high      5) paranoid" > /dev/tty
            echo > /dev/tty
            echo "   ⚠️  router и low — БЕЗ header protection, паддинга и" > /dev/tty
            echo "       таймингов: слой 3.0 на них работает как 2.0." > /dev/tty
            echo "       Полный набор 3.0 начинается с medium." > /dev/tty
            ask_pick P3 3 "1 2 3 4 5"
            case "$P3" in 1) PRESET3=router ;; 2) PRESET3=low ;; 4) PRESET3=high ;; 5) PRESET3=paranoid ;; *) PRESET3=medium ;; esac
            case "$PRESET3" in
                router|low) log "Выбран $PRESET3: слой 3.0 будет без header protection" ;;
            esac
            echo > /dev/tty
            echo "  Маскировка слоя 3.0:" > /dev/tty
            echo "   0) как у 2.0 [по умолчанию]  1) quic  2) tls  3) web  4) voip  5) dns  6) mixed" > /dev/tty
            ask_pick T3 0 "0 1 2 3 4 5 6"
            case "$T3" in 1) TEMPLATE3=quic ;; 2) TEMPLATE3=tls ;; 3) TEMPLATE3=web ;; 4) TEMPLATE3=voip ;; 5) TEMPLATE3=dns ;; 6) TEMPLATE3=mixed ;; *) TEMPLATE3="$TEMPLATE" ;; esac
        fi
    fi

    resolve_endpoint
    ask_bot

    umask 077
    mkdir -p "$DEST"
    {
        echo "AWG_VER='$AWG_VER'"
        echo "AWG_PRESET='$PRESET'"
        echo "AWG_TEMPLATE='$TEMPLATE'"
        echo "AWG_PRESET3='$PRESET3'"
        echo "AWG_TEMPLATE3='$TEMPLATE3'"
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

    i="${IFACE2:-awg2}"
    systemctl disable --now "awg-quick@$i" 2>/dev/null || true
    ip link del "$i" 2>/dev/null || true
    # Слой 3.0 обслуживает awg3@, но на сервере, который когда-то жил с
    # KMOD3=1, его поднимал awg-quick@ — гасим оба, иначе удаление оставляет
    # включённый юнит на интерфейс, которого больше нет.
    i="${IFACE3:-awg3}"
    systemctl disable --now "awg3@$i" "awg-quick@$i" 2>/dev/null || true
    ip link del "$i" 2>/dev/null || true
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
          /usr/local/bin/awg-backup /usr/local/bin/awg-doctor /usr/local/bin/awg-upstream-check
    rm -rf "$DEST" "$AWG_DIR" "$SRC/amneziawg-go" "$SRC/amneziawg-tools" \
           "$SRC/amneziawg-linux-kernel-module"
    # Метку ревизии модуля тоже сносим: без неё rmdir "$SRC" ниже упирался в
    # непустой каталог и тихо отваливался, оставляя /opt/src навсегда.
    rm -f "$KMOD_STAMP"
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
    if [ "${LAYER3:-0}" = 1 ]; then
        install_awg_go
        # Пересобранный бинарник не подхватывается сам: демон уже запущен из
        # старого. Перезапускаем — короткий разрыв туннелей 3.0, но иначе
        # обновление датапаса не имело бы смысла.
        if [ "${AWG_GO_REBUILT:-0}" = 1 ]; then
            log "Перезапуск слоя 3.0 на новом датапасе…"
            systemctl restart "awg3@${IFACE3:-awg3}" || \
                err "не удалось перезапустить awg3@${IFACE3:-awg3}"
        fi
    fi
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

# ── сухой прогон ─────────────────────────────────────────────────────────────
# Главный вопрос перед запуском на работающем сервере один: отвалятся ли
# клиенты. Ответ зависит от состояния сервера и набора флагов сразу, и держать
# эту таблицу в голове владелец не обязан.

plan_clients() {  # plan_clients <сервис…> → сколько конфигов выдано
    local svc n=0
    local -a f
    for svc in "$@"; do
        [ -d "$CLIENT_DIR/$svc" ] || continue
        # Без find и без трубы: под pipefail ненулевой код find (подкаталог без
        # прав, файл, удалённый awg-expire прямо во время обхода) оборвал бы
        # весь отчёт между заголовком и первым разделом — и молча, его
        # сообщение уже выброшено в /dev/null.
        f=( "$CLIENT_DIR/$svc"/*-am.conf )
        [ -e "${f[0]}" ] && n=$(( n + ${#f[@]} ))
    done
    echo "$n"
}

# Пересоберётся ли апстрим — не гадаем, а спрашиваем ровно теми же проверками,
# что и сборщики: install_kmod смотрит modinfo и метку ревизии, install_awg_go
# и install_tools сравнивают версию бинарника с пином. Все три вопроса
# read-only, и врать они не умеют.
plan_kmod() {
    modinfo amneziawg >/dev/null 2>&1 || { echo "будет собран (модуля в системе нет)"; return 0; }
    local have=""
    [ -f "$KMOD_STAMP" ] && have="$(cut -f1 "$KMOD_STAMP" 2>/dev/null || true)"
    if [ -z "$AWG_KMOD_REF" ] || [ "$AWG_KMOD_REF" = "$have" ]; then
        echo "не трогается (${have:-ревизия не помечена})"
    else
        echo "ПЕРЕСБОРКА ${have:-?} → $AWG_KMOD_REF, интерфейсы будут погашены"
    fi
}

plan_go() {
    command -v amneziawg-go >/dev/null 2>&1 || { echo "будет собран ($AWG_GO_REF)"; return 0; }
    local cur; cur="$(amneziawg-go --version 2>&1 | grep -oE 'v[0-9][0-9.]*' | head -1 || true)"
    if [ "$cur" = "$AWG_GO_REF" ]; then
        echo "не трогается ($cur)"
    else
        echo "ПЕРЕСБОРКА ${cur:-?} → $AWG_GO_REF"
    fi
}

plan_tools() {
    # Зеркалим install_tools целиком, включая её первое условие: одной версии
    # бинарника мало — собранное из ветки и собранное из тега сообщают одну и
    # ту же строку, поэтому она спрашивает ещё и чекаут. Половинчатая копия
    # выдавала «ПЕРЕСБОРКА X → X», то есть правду в форме бессмыслицы.
    if ! command -v awg >/dev/null 2>&1 || ! command -v awg-quick >/dev/null 2>&1 \
       || [ ! -d "$SRC/amneziawg-tools" ]; then
        echo "сборка из исходников ($AWG_TOOLS_REF)"
        return 0
    fi
    local cur cur_ref
    cur="$(awg --version 2>&1 | grep -oE 'v[0-9][0-9.]*(-[0-9]+)?' | head -1 || true)"
    cur_ref="$(git -C "$SRC/amneziawg-tools" describe --tags --exact-match 2>/dev/null || true)"
    if [ "$cur" = "$AWG_TOOLS_REF" ] && [ "$cur_ref" = "$AWG_TOOLS_REF" ]; then
        echo "не трогаются ($cur)"
    elif [ "$cur" = "$AWG_TOOLS_REF" ] && [ -n "$cur_ref" ]; then
        echo "ПЕРЕСБОРКА: версия $cur, но собраны из $cur_ref"
    else
        echo "ПЕРЕСБОРКА ${cur:-?} → $AWG_TOOLS_REF"
    fi
}

plan_report() {
    local ver pl2 pl3 n2 n3 m2 m3 op

    # shellcheck disable=SC1090
    [ -f "$STATE" ] && . "$STATE"
    # Состав слоёв решает не план, а ask_params: при существующем
    # install-state.env и без --reconfigure она сорсит файл и выходит РАНЬШЕ
    # строки AWG_VER="${CLI_VER:-}", то есть --awg в этом прогоне не
    # применяется вовсе. План обязан повторить это решение буква в букву:
    # отчёт, обещающий отключение слоя там, где прогон ничего не отключит,
    # опаснее отсутствующего отчёта — ему верят.
    if [ -f "$STATE" ] && [ "$RECONFIGURE" != 1 ]; then
        ver="${AWG_VER:-both}"
    else
        ver="${CLI_VER:-${AWG_VER:-both}}"
    fi
    case "$ver" in 2|3|both) ;; *) ver=both ;; esac
    case "$ver" in
        2) pl2=1; pl3=0 ;;
        3) pl2=0; pl3=1 ;;
        *) pl2=1; pl3=1 ;;
    esac

    if ! installed; then
        if [ "$UPDATE" = 1 ]; then
            log "План: ОБНОВЛЯТЬ НЕЧЕГО"
            log "  $SERVICES нет — сервер ещё не установлен."
            log "  Тот же запуск без --plan завершится отказом."
            return 0
        fi
        # Проверку портов делает plan_services, а до неё эта ветка не доходит:
        # без этого `--plan --ports 100,100` отвечал «успех», а тот же запуск
        # без --plan падал с кодом 2. План обязан отказать там же, где прогон.
        if ! check_cli_ports; then
            err "--ports: нужно два разных порта через запятую"
            err "Тот же запуск без --plan откажет с кодом 2 — план его повторяет"
            return 2
        fi
        log "План: ПЕРВАЯ УСТАНОВКА"
        echo
        echo "  Будет создано:"
        echo "    ! пакеты сборки (apt-get) и утилиты amneziawg-tools"
        [ "$pl2" = 1 ] && echo "    ! kernel-модуль amneziawg — сборка из исходников"
        [ "$pl3" = 1 ] && echo "    ! датапас amneziawg-go — сборка из исходников"
        if [ -n "$CLI_PORTS" ]; then
            echo "    ! интерфейсы, UDP-порты ${CLI_PORTS%%,*} и ${CLI_PORTS##*,} (закрепляются навсегда)"
        else
            echo "    ! интерфейсы, случайные свободные UDP-порты (закрепляются навсегда)"
        fi
        echo "    ! ключи сервера и новый профиль обфускации"
        echo "    ! юниты systemd, симлинки в /usr/local/bin, каталог $DEST"
        echo
        log "Выданных клиентов ещё нет — ломать нечего."
        log "Это только план: ничего не изменено. Запусти ту же команду без --plan."
        return 0
    fi

    # Порты и подсети читаются из services.env ровно так же, как их прочтёт
    # настоящий прогон; на установленном сервере plan_services только сорсит
    # файл и ничего не считает заново.
    if ! plan_services >/dev/null 2>&1; then
        log "⚠️ прочитать $SERVICES не удалось — ниже только то, что известно"
    fi

    n2="$(plan_clients awg2)"
    n3="$(plan_clients awg3)"
    m2="$(obf_mode "$AWG_DIR/obfuscation.env")"
    m3="$(obf_mode "$AWG_DIR/obfuscation3.env")"

    # Флаги, которые на установленном сервере не доедут никуда. Молча их
    # проглотить — то же вранье, только тихое: владелец решит, что параметры
    # он уже поменял. ask_params (для первой группы) и plan_services (для
    # второй) выходят раньше, чем эти значения читаются.
    local ignored=""
    if [ "$RECONFIGURE" != 1 ]; then
        [ -n "$CLI_VER" ]       && ignored="$ignored --awg"
        [ -n "$CLI_PRESET" ]    && ignored="$ignored --preset"
        [ -n "$CLI_TEMPLATE" ]  && ignored="$ignored --template"
        [ -n "$CLI_FP" ]        && ignored="$ignored --fp"
        [ -n "$CLI_PRESET3" ]   && ignored="$ignored --preset3"
        [ -n "$CLI_TEMPLATE3" ] && ignored="$ignored --template3"
        [ -n "$CLI_HOST" ]      && ignored="$ignored --host"
    fi
    [ -n "$CLI_PORTS" ] && ignored="$ignored --ports"
    [ -n "$CLI_MTU" ]   && ignored="$ignored --mtu"
    [ -n "$CLI_DNS" ]   && ignored="$ignored --dns"

    # Смена адреса возможна только там, где зовут resolve_endpoint, а зовут её
    # из ask_params — то есть на первой установке и при --reconfigure.
    local ep="${ENDPOINT:-}" ep_new=""
    if [ -n "$CLI_HOST" ] && [ "$RECONFIGURE" = 1 ] && [ "$CLI_HOST" != "$ep" ]; then
        ep_new="$CLI_HOST"
    fi

    # plan_services сообщает о принудительном возврате слоя 3.0 на userspace
    # через log(), а он в отчёте заглушён. Спрашиваем файл сами, ДО того как
    # она затрёт KMOD3 нулём.
    local kmod3_was=""
    kmod3_was="$(grep -o "KMOD3='1'" "$SERVICES" 2>/dev/null || true)"

    if   [ "$UPDATE" = 1 ];      then op="ОБНОВЛЕНИЕ КОДА"
    elif [ "$RECONFIGURE" = 1 ]; then op="НОВЫЙ ПРОФИЛЬ ОБФУСКАЦИИ"
    else                              op="ПОВТОРНЫЙ ПРОГОН"
    fi
    log "План: $op"
    # Честно про предел знания плана: --reconfigure заново проводит опрос, и
    # ответы, которых нет во флагах, пользователь ещё будет вводить руками.
    # Ниже показаны сохранённые — то есть предположение, а не факт.
    if [ "$RECONFIGURE" = 1 ]; then
        log "  --reconfigure переспросит версию, обфускацию и домен (что не задано"
        log "  флагами); ниже — сохранённые ответы"
    fi
    if [ -n "$ignored" ]; then
        log "⚠️ НЕ будут применены:$ignored"
        log "   на установленном сервере параметры берутся из install-state.env и"
        log "   services.env: состав слоёв и профиль меняются только вместе с"
        log "   --reconfigure, а порты, MTU и DNS не меняются уже никогда"
    fi
    echo

    # Слои перечисляем по тому, что будет ПОСЛЕ прогона (pl2/pl3), а не по
    # тому, что записано сейчас: иначе при --awg 3 отчёт показывал бы порт
    # слоя 2.0, которого в services.env после прогона уже не будет.
    local show2="$pl2" show3="$pl3"
    [ "$UPDATE" = 1 ] && { show2="${LAYER2:-0}"; show3="${LAYER3:-0}"; }
    echo "  Не изменится:"
    printf '    ✓ порты          '
    [ "$show2" = 1 ] && printf '2.0 %s   ' "${PORT2:-?}"
    [ "$show3" = 1 ] && printf '3.0 %s' "${PORT3:-?}"
    printf '\n'
    printf '    ✓ подсети        '
    [ "$show2" = 1 ] && printf '%s.0/24  ' "${SUBNET2:-?}"
    [ "$show3" = 1 ] && printf '%s.0/24' "${SUBNET3:-?}"
    printf '\n'
    if [ -n "$ep_new" ]; then
        echo "    ✓ ключи сервера и клиентов"
    elif [ -z "$ep" ]; then
        echo "    ✓ ключи сервера и клиентов"
        echo "    ⚠️ адрес сервера пуст: клиентские конфиги без Endpoint нерабочие"
    else
        echo "    ✓ ключи сервера и клиентов, адрес $ep"
    fi
    if [ "$UPDATE" = 1 ]; then
        [ "${LAYER2:-0}" = 1 ] && echo "    ✓ профиль обфускации 2.0"
        [ "${LAYER3:-0}" = 1 ] && echo "    ✓ профиль обфускации 3.0"
        # Перечисляем только поднятые слои: строка «3.0: 0» на сервере, где
        # слоя 3.0 нет, — тот же сорт вранья, что и умолчание.
        if [ "${LAYER2:-0}" = 1 ] && [ "${LAYER3:-0}" = 1 ]; then
            echo "    ✓ конфиги клиентов 2.0: $n2, 3.0: $n3 — не пересоздаются"
        elif [ "${LAYER2:-0}" = 1 ]; then
            echo "    ✓ конфиги клиентов 2.0: $n2 — не пересоздаются"
        else
            echo "    ✓ конфиги клиентов 3.0: $n3 — не пересоздаются"
        fi
        echo "    ✓ kernel-модуль и утилиты amneziawg-tools"
        [ "${LAYER2:-0}" = 1 ] && echo "    ✓ слой 2.0 не перезапускается"
    else
        [ "$pl2" = 1 ] && [ "$m2" = --reapply ] && \
            echo "    ✓ профиль обфускации 2.0 (применяется существующий)"
        [ "$pl3" = 1 ] && [ "$m3" = --reapply ] && \
            echo "    ✓ профиль обфускации 3.0 (применяется существующий)"
        [ "$pl2" = 1 ] && [ "$m2" = --reapply ] && \
            echo "    ✓ конфиги клиентов 2.0: $n2 — пересоздаются с тем же содержимым"
        [ "$pl3" = 1 ] && [ "$m3" = --reapply ] && \
            echo "    ✓ конфиги клиентов 3.0: $n3 — пересоздаются с тем же содержимым"
    fi
    echo

    echo "  Изменится:"
    echo "    ! код в $DEST, юниты systemd, симлинки, бот"
    # install_base_deps зовётся в main() на КАЖДОМ полном прогоне, и падение
    # apt обрывает прогон раньше всего остального. Владелец с замороженными
    # репозиториями должен узнать это из плана, а не из журнала.
    [ "$UPDATE" = 1 ] || echo "    ! пакеты: apt-get update и доустановка сборочных зависимостей"
    if [ "$UPDATE" = 1 ]; then
        [ "${LAYER3:-0}" = 1 ] && echo "    ! датапас amneziawg-go: $(plan_go)"
        [ "${LAYER3:-0}" = 1 ] && \
            echo "      при пересборке слой 3.0 перезапускается — короткий разрыв туннелей"
    else
        # install_tools в main() вызывается ВСЕГДА, install_kmod — только под
        # слой 2.0, install_awg_go — только под 3.0. Отчёт повторяет это, иначе
        # при --awg 3 он умалчивал бы о пересборке утилит.
        echo "    ! утилиты amneziawg-tools: $(plan_tools)"
        [ "$pl2" = 1 ] && echo "    ! kernel-модуль: $(plan_kmod)"
        [ "$pl3" = 1 ] && echo "    ! датапас amneziawg-go: $(plan_go)"
        # Разрывов на полном прогоне ДВА, и первый делает не install.sh:
        # awg-obfuscation.sh перезапускает юниты и в режиме --reapply тоже,
        # а enable_units гасит интерфейс и поднимает заново даже тогда, когда
        # не изменилось ровно ничего. Обещать «несколько секунд» нельзя:
        # между ними apt, компиляция и rmmod с ретраями.
        echo "    ! интерфейсы гасятся и поднимаются заново — связь прервётся дважды:"
        echo "      сначала это делает awg-obfuscation.sh, затем enable_units;"
        echo "      сколько займёт весь прогон, заранее не известно — между ними"
        echo "      apt-get и сборка из исходников"
        if [ -n "$ep_new" ]; then
            echo "    ! адрес сервера: ${ep:-?} → $ep_new"
            echo "      уже выданные конфиги останутся со СТАРЫМ Endpoint: regen-all"
            echo "      переписывает только обфускацию и [Peer] не трогает —"
            echo "      их придётся выпустить заново через awg-client"
        fi
        if [ -n "$kmod3_was" ] && [ "$pl3" = 1 ]; then
            echo "    ! слой 3.0 возвращается с kernel-датапаса на userspace:"
            echo "      awg-quick@${IFACE3:-awg3} гасится, поднимается awg3@${IFACE3:-awg3},"
            echo "      в services.env ляжет KMOD3=0. Порт, подсеть и ключи прежние —"
            echo "      выданные конфиги 3.0 остаются рабочими"
        fi
        if [ "$pl2" = 1 ] && [ "$m2" = --apply ]; then
            echo "    ! профиль обфускации 2.0 — НОВЫЙ"
            echo "    ! конфиги клиентов 2.0: $n2 — все перестанут подключаться"
        fi
        if [ "$pl3" = 1 ] && [ "$m3" = --apply ]; then
            echo "    ! профиль обфускации 3.0 — НОВЫЙ"
            echo "    ! конфиги клиентов 3.0: $n3 — все перестанут подключаться"
        fi
        [ "$pl2" = 1 ] && [ "$m2" = --reapply ] && [ "$pl3" = 1 ] && [ "$m3" = --apply ] && \
            echo "    (слой 2.0 при этом не затрагивается)"
        [ "$pl3" = 1 ] && [ "${LAYER3:-0}" = 0 ] && \
            echo "    ! слой 3.0 добавляется к существующей установке"
        [ "$pl2" = 1 ] && [ "${LAYER2:-0}" = 0 ] && \
            echo "    ! слой 2.0 добавляется к существующей установке"
        # --awg с одним слоем на сервере, где подняты оба, — тихое отключение
        # второго: write_services запишет LAYER=0, туннель останется поднятым,
        # но awg-client перестанет его обслуживать. Молчать об этом нельзя.
        if [ "$pl2" = 0 ] && [ "${LAYER2:-0}" = 1 ]; then
            echo "    ! слой 2.0 ОТКЛЮЧАЕТСЯ: в services.env ляжет LAYER2=0"
            echo "      туннель останется поднятым, но awg-client перестанет его"
            echo "      обслуживать — конфиги 2.0 ($n2 шт.) больше не выпускаются"
        fi
        if [ "$pl3" = 0 ] && [ "${LAYER3:-0}" = 1 ]; then
            echo "    ! слой 3.0 ОТКЛЮЧАЕТСЯ: в services.env ляжет LAYER3=0"
            echo "      туннель останется поднятым, но awg-client перестанет его"
            echo "      обслуживать — конфиги 3.0 ($n3 шт.) больше не выпускаются"
        fi
    fi
    echo

    echo "  НЕ будет сделано:"
    if [ "$UPDATE" = 1 ]; then
        echo "    ✗ перевыпуск профиля обфускации"
        echo "    ✗ пересоздание конфигов клиентов"
        echo "    ✗ смена портов, подсетей и ключей"
        echo "    ✗ сборка kernel-модуля и утилит"
        echo "    ✗ apt-get: обновление пакеты не трогает вовсе"
    else
        [ "$pl2" = 1 ] && [ "$m2" = --reapply ] && echo "    ✗ перевыпуск профиля обфускации 2.0"
        [ "$pl3" = 1 ] && [ "$m3" = --reapply ] && echo "    ✗ перевыпуск профиля обфускации 3.0"
        echo "    ✗ смена портов, подсетей и ключей"
    fi
    echo

    if [ "$UPDATE" != 1 ] && { { [ "$pl2" = 1 ] && [ "$m2" = --apply ]; } || \
       { [ "$pl3" = 1 ] && [ "$m3" = --apply ]; }; }; then
        log "⚠️ Затронутым клиентам придётся заново скачать и импортировать конфиг."
    else
        log "Переимпортировать конфиги никому не придётся."
    fi
    log "Это только план: ничего не изменено. Запусти ту же команду без --plan."
    return 0
}

# --plan: рассказать, не делая. Отдельная точка входа, потому что main() по
# дороге успевает и уйти в --update/--uninstall, и открыть меню.
plan_entry() {
    local nope=""
    [ "$UNINSTALL" = 1 ]   && nope="--uninstall"
    [ "$INSTALL_BOT" = 1 ] && nope="--install-bot"
    [ "$REMOVE_BOT" = 1 ]  && nope="--remove-bot"
    if [ -n "$nope" ]; then
        # Молча выполнить чужую операцию или молча проглотить флаг — оба исхода
        # плохи одинаково: в первом случае вместо отчёта делается работа, во
        # втором отчёт не о том, что спрашивали.
        err "--plan не умеет показывать $nope: у этой операции нет отчёта"
        err "Запусти её без --plan — или убери $nope, чтобы увидеть план установки"
        return 2
    fi
    plan_report
}

# ── main ─────────────────────────────────────────────────────────────────────
main() {
    # План — раньше всего остального. Ниже уже стоят ветки, которые делают
    # настоящую работу (--update, --uninstall, меню), и план, дошедший до них,
    # сделал бы то, о чём его просили только рассказать.
    if [ "$PLAN" = 1 ]; then
        # Простой вызов под set -e убил бы оболочку прямо здесь, и exit ниже
        # не выполнился бы никогда: сегодня код совпадает случайно, но всё,
        # что допишут между строками, молча пропало бы. В условии errexit снят.
        plan_entry || exit $?
        exit 0
    fi
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
    # ${AWG_ENDPOINT:-$ENDPOINT} под set -u падает «unbound variable», когда в
    # state лежит ПУСТОЙ AWG_ENDPOINT: на этом пути ask_params вышла ранним
    # return, resolve_endpoint не звалась, и ENDPOINT в прогоне не существует
    # вовсе. Так выглядит сервер, поставленный без tty и без внешнего адреса:
    # прогон умирал сразу после apt-get, не сделав ничего полезного.
    ENDPOINT="$(endpoint_final)"
    [ -n "$ENDPOINT" ] || ENDPOINT="$(detect_public_ip)"
    [ -n "$ENDPOINT" ] || { err "адрес сервера неизвестен — задай --host"; exit 1; }
    # plan_services обязан отработать ДО сборки по двум причинам. Во-первых,
    # оттуда приезжают настоящие имена интерфейсов: install_kmod гасит их перед
    # rmmod, и с дефолтными awg2/awg3 на сервере с другими именами он погасил бы
    # не то, а rmmod упёрся бы в живой интерфейс. Во-вторых, раньше он стоял
    # ПОСЛЕ install_kmod и сорсил services.env поверх LAYER2, которую обработчик
    # отказа сборки только что выставил в 0, — решение «слой 2.0 не поднимаем»
    # молча отменялось, и awg-quick@ стартовал против отсутствующего модуля.
    plan_services

    # Намерение сильнее сохранённого состояния: services.env описывает прошлую
    # установку, а AWG_VER — то, что запрошено сейчас. Иначе одна неудачная
    # сборка, записанная в services.env как LAYER2=0, осталась бы там навсегда.
    case "$AWG_VER" in
        2)    LAYER2=1; LAYER3=0 ;;
        3)    LAYER2=0; LAYER3=1 ;;
        *)    LAYER2=1; LAYER3=1 ;;
    esac

    install_tools
    if [ "$LAYER2" = 1 ]; then
        install_kmod || {
            err "модуль не собрался — слой 2.0 в этом прогоне не поднимается"
            LAYER2=0
        }
    fi
    [ "$LAYER3" = 1 ] && install_awg_go
    [ "$LAYER2" = 0 ] && [ "$LAYER3" = 0 ] && { err "ни один слой не поднялся"; exit 1; }

    deploy_files
    write_services
    build_interfaces
    # Код 3 значит «в файлы легло, до туннеля не доехало». При установке это
    # ожидаемо: enable_units поднимает юниты чуть ниже, там профиль и доедет.
    gen_obfuscation || { _orc=$?; [ "$_orc" = 3 ] || exit "$_orc"; }
    setup_stats
    enable_units
    # Отказ здесь НЕ должен ронять прогон: сервер уже переехал на новый профиль,
    # и аварийный выход сделал бы только хуже. Но и молчать нельзя — это самый
    # разрушительный из возможных отказов: сервер на новом профиле, клиенты на
    # старом, то есть не подключается никто. Раньше вывод уходил в /dev/null, а
    # `|| true` съедал код, и прогон допечатывал «Готово».
    if ! "$DEST/awg-client.sh" regen-all; then
        _regen_failed=1
        err "конфиги клиентов НЕ пересозданы, а сервер уже на новом профиле."
        err "Это значит, что сейчас не подключится никто. Запусти вручную:"
        err "    awg-client regen-all"
        err "и раздай клиентам обновлённые конфиги."
    fi

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
    # Ненулевой код в самом конце: всё сказано, подсказки напечатаны, но для
    # автоматики этот прогон обязан считаться неуспешным.
    [ "$_regen_failed" = 0 ] || return 1
    return 0
}
main
