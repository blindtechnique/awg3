#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Три ловушки bash, на которых установщик ломался молча.
#
# Все три — про «set -euo pipefail» и про то, что ненулевой код возврата
# приезжает не оттуда, откуда его ждут:
#   1) pipefail + SIGPIPE: `echo "$длинный" | grep -q` отдаёт 141, когда
#      совпадение нашлось в начале, — и занятый порт объявлялся свободным;
#   2) set -u: ${A:-$B} вычисляет B, и необъявленная B роняет прогон;
#   3) pipefail: grep без совпадения в присваивании убивал скрипт вместо
#      того, чтобы отдать пустую строку в заготовленную ветку.
#
# Куски вырезаются из НАСТОЯЩЕГО install.sh и исполняются как есть: копия
# разошлась бы с кодом, и набор перестал бы что-либо значить.
#
#   bash tests/test_bash_traps.sh
fail=0
ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
cd "$ROOT" || exit 1

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

ok()  { printf '  ✔ %s\n' "$1"; }
bad() { printf '  ✘ %s\n' "$1"; [ $# -gt 1 ] && printf '     %s\n' "$2"; fail=1; }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# ═══════════════════════════════════════════════════════════════════════════
head_ "1. Занятый порт не выдаётся как свободный"

# busy_ports — ОДНОСТРОЧНАЯ функция, и диапазон sed на ней не закрывается:
# «}» стоит не в начале строки, поэтому range тянулся бы до следующей функции
# и вырезал бы лишнее вперемешку. Берём её строку отдельно, а многострочную
# pick_random_port — диапазоном до строки, состоящей ровно из «}».
FNS="$(grep '^busy_ports()' install.sh; sed -n '/^pick_random_port()/,/^}$/p' install.sh)"
if [ -z "$FNS" ]; then
    bad "не нашли busy_ports/pick_random_port" "мерить нечего"
else
    # Подставной ss объявляет занятым ВЕСЬ диапазон, из которого выбирает
    # pick_random_port. Правильный ответ тогда один: перебрать все попытки и
    # уйти в запасное значение. Старый код на первой же попытке ловил SIGPIPE
    # (список в 40000 строк не влезает в буфер трубы), читал 141 как «не
    # найдено» и отдавал занятый порт.
    # Колонки — как у настоящего `ss -lunH`: при фильтре по одному протоколу
    # колонка Netid не печатается, и адрес с портом оказывается ЧЕТВЁРТЫМ:
    #   UNCONN 0      0      127.0.0.54:53  0.0.0.0:*
    # Стенд, выдумавший лишнюю колонку, проверял бы не то поле и молча
    # соглашался бы с любой ошибкой в awk.
    STUB="$WORK/stub"; mkdir -p "$STUB"
    {
        echo '#!/bin/bash'
        echo 'for p in $(seq 20000 59999); do printf "UNCONN 0      0      0.0.0.0:%s 0.0.0.0:*\n" "$p"; done'
    } > "$STUB/ss"
    chmod +x "$STUB/ss"

    out="$(PATH="$STUB:$PATH" bash -c "set -euo pipefail; $FNS
        pick_random_port" 2>&1)" || out="ОТКАЗ:$?"
    if [ "$out" = 51820 ]; then
        ok "весь диапазон занят → уходит в запасное значение, а не врёт"
    else
        bad "выдан порт из занятого диапазона" "вернулось «$out»"
    fi

    # Прямая проверка колонки. Она же и объясняет предыдущий пункт: если awk
    # возьмёт не то поле, список занятых окажется пустым, и «свободным» будет
    # объявлен любой порт. В родственном репозитории ровно так и вышло.
    PATH="$STUB:$PATH" bash -c "set -euo pipefail; $FNS
        busy_ports" > "$WORK/busy.txt" 2>&1 || true
    if grep -qx 20000 "$WORK/busy.txt" && grep -qx 59999 "$WORK/busy.txt"; then
        ok "busy_ports читает колонку с адресом и портом"
    else
        bad "busy_ports не увидел занятых портов" \
            "первые строки: $(head -3 "$WORK/busy.txt" | tr '\n' ' ')"
    fi

    # И обратное: когда занятых нет вовсе, порт обязан найтись с первой попытки.
    {
        echo '#!/bin/bash'
        echo 'exit 0'
    } > "$STUB/ss"
    out="$(PATH="$STUB:$PATH" bash -c "set -euo pipefail; $FNS
        pick_random_port" 2>&1)" || out="ОТКАЗ:$?"
    case "$out" in
        [0-9]*) [ "$out" -ge 20000 ] && [ "$out" -le 59999 ] \
                    && ok "пустой список занятых не роняет выбор порта" \
                    || bad "порт вне диапазона" "вернулось «$out»" ;;
        *) bad "без UDP-слушателей выбор порта отказал" "вернулось «$out»" ;;
    esac

    # Резервные 22/53/80/443 обязаны пережить пустой busy_ports: они
    # дописываются в той же подстановке, и её обрыв уносил бы их с собой.
    out="$(PATH="$STUB:$PATH" bash -c "set -euo pipefail; $FNS
        busy=\"\$(busy_ports; echo 22; echo 53; echo 80; echo 443)\"
        printf '%s\n' \"\$busy\" | tr '\n' ' '" 2>&1)" || out="ОТКАЗ:$?"
    case "$out" in
        *22*53*80*443*) ok "резервные порты не теряются на пустом списке" ;;
        *) bad "резервные порты потерялись" "вышло «$out»" ;;
    esac
fi

# ═══════════════════════════════════════════════════════════════════════════
head_ "2. Пустой AWG_ENDPOINT не роняет прогон"

EP="$(sed -n '/^    ENDPOINT="${AWG_ENDPOINT:-/,+2p' install.sh)"
if [ -z "$EP" ]; then
    bad "не нашли разбор ENDPOINT в main()" "мерить нечего"
else
    # Так выглядит сервер, поставленный без tty и без внешнего адреса:
    # в state лежит AWG_ENDPOINT='', а ENDPOINT в этом прогоне не объявлен —
    # ask_params вышла ранним return и до resolve_endpoint не дошла.
    out="$(bash -c "set -euo pipefail
        detect_public_ip() { echo 203.0.113.7; }
        err() { printf 'ERR %s\n' \"\$*\" >&2; }
        AWG_ENDPOINT=''
$EP
        echo \"ENDPOINT=\$ENDPOINT\"" 2>&1)" || out="ОТКАЗ:$out"
    case "$out" in
        *"unbound variable"*) bad "прогон падает на unbound variable" "$out" ;;
        *"ENDPOINT=203.0.113.7"*) ok "пустой AWG_ENDPOINT → адрес определяется сам" ;;
        *) bad "неожиданный исход" "$out" ;;
    esac

    # А если адрес не определяется вовсе — отказ с объяснением, а не падение
    # на подстановке: конфиги без Endpoint всё равно нерабочие.
    out="$(bash -c "set -euo pipefail
        detect_public_ip() { echo ''; }
        err() { printf 'ERR %s\n' \"\$*\" >&2; }
        AWG_ENDPOINT=''
$EP
        echo 'дошли дальше'" 2>&1)" || true
    case "$out" in
        *"unbound variable"*) bad "падает на unbound variable вместо отказа" "$out" ;;
        *"адрес сервера неизвестен"*) ok "без адреса — понятный отказ" ;;
        *) bad "нет внятного отказа" "$out" ;;
    esac
fi

# ═══════════════════════════════════════════════════════════════════════════
head_ "3. Конфиг без PrivateKey не убивает прогон"

PRIV="$(grep -F "priv=\"\$(grep '^PrivateKey'" install.sh | head -1)"
if [ -z "$PRIV" ]; then
    bad "не нашли чтение PrivateKey в build_iface" "мерить нечего"
else
    conf="$WORK/iface.conf"
    printf '[Interface]\nListenPort = 51820\n' > "$conf"
    out="$(bash -c "set -euo pipefail
        conf='$conf'
$PRIV
        if [ -z \"\$priv\" ]; then echo 'ветка «ключа нет» достижима'; fi" 2>&1)" \
        || out="ОТКАЗ: скрипт умер на присваивании"
    case "$out" in
        *"ветка «ключа нет» достижима"*) ok "пустой ключ доезжает до ветки генерации" ;;
        *) bad "прогон обрывается на конфиге без PrivateKey" "$out" ;;
    esac
    # И ключ, который ЕСТЬ, обязан читаться по-прежнему
    printf '[Interface]\nPrivateKey = aGVsbG8=\n' > "$conf"
    out="$(bash -c "set -euo pipefail
        conf='$conf'
$PRIV
        echo \"[\$priv]\"" 2>&1)" || out="ОТКАЗ"
    [ "$out" = "[aGVsbG8=]" ] && ok "существующий ключ читается как раньше" \
        || bad "чтение существующего ключа сломано" "вышло «$out»"
fi

# ═══════════════════════════════════════════════════════════════════════════
head_ "4. Заплаты на месте"
if sed -n '/^busy_ports()/,/^}/p' install.sh | grep -q '|| true'; then
    ok "busy_ports не роняет подстановку на пустом выводе"
else
    bad "в busy_ports нет «|| true»"
fi
# Комментарии отбрасываем: в них труба упомянута нарочно, как объяснение,
# почему её здесь быть не должно.
if sed -n '/^pick_random_port()/,/^}$/p' install.sh | grep -v '^[[:space:]]*#' | grep -q 'grep -qx'; then
    bad "в pick_random_port вернулась труба с grep -q" "она отдаёт 141 на длинном списке"
else
    ok "проверка занятости порта обходится без трубы"
fi

printf '\n'
[ "$fail" = 0 ] && echo "═══ ВСЁ ЗЕЛЁНОЕ ═══" || echo "═══ ЕСТЬ ПАДЕНИЯ ═══"
exit $fail
