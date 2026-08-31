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

# Разбор адреса живёт в endpoint_final (вынесен туда, чтобы `--reconfigure
# --host` перестал молча не работать), а в main() остались три строки вокруг
# вызова. Берём и то и другое: без функции кусок не самодостаточен.
EPFN="$(sed -n '/^endpoint_final()/,/^}$/p' install.sh)"
# Первое вхождение и ровно три строки: та же строка есть и в блоке
# «намерение сильнее сохранённого», а диапазон ,+2p подхватывал оба.
EP="$(sed -n '/^    ENDPOINT="\$(endpoint_final)"/{N;N;p;q}' install.sh)"
EP="$EPFN
$EP"
if [ -z "$EPFN" ] || [ -z "$(sed -n '/^    ENDPOINT="\$(endpoint_final)"/p' install.sh)" ]; then
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

# ═══════════════════════════════════════════════════════════════════════════
head_ "5. Загруженный модуль виден всегда, а не через раз"
# `lsmod | grep -q` под pipefail отдаёт 141: grep выходит по первому совпадению,
# lsmod продолжает писать и получает SIGPIPE. Условие if от 141 ЛОЖНО, и блок
# выгрузки старого модуля молча пропускается — ровно на том сервере, ради
# которого он написан. Итог: новый .ko на диске, старый модуль в памяти,
# утилиты уже пересобраны, awg виснет.
# Комментарии отбрасываем: в них труба упомянута нарочно, как объяснение.
if grep -v '^[[:space:]]*#' install.sh | grep -qE 'lsmod[^|]*\|[[:space:]]*grep'; then
    bad "вернулся «lsmod | grep»" "под pipefail SIGPIPE даёт 141, и блок пропускается"
else
    ok "проверка загруженного модуля обходится без трубы"
fi
# Берём только УСЛОВИЕ: со словами `if` и `; then` кусок не исполнить.
COND="$(grep -F "grep -q '^amneziawg " install.sh | head -1         | sed 's/^[[:space:]]*if //; s/; then$//')"
if [ -z "$COND" ]; then
    bad "не нашли проверку загруженного модуля" "мерить нечего"
else
    mods="$WORK/modules"
    {
        printf 'amneziawg 249856 0 - Live 0xffffffffc0a00000\n'
        for i in $(seq 1 250); do
            printf 'filler_%s 16384 0 - Live 0xffffffffc0%03x000\n' "$i" "$i"
        done
    } > "$mods"                       # ≈11 КБ: заведомо больше одного блока
    run="$(printf '%s' "$COND" | sed "s#/proc/modules#$mods#")"
    c=0
    for i in $(seq 1 50); do
        bash -c "set -euo pipefail; $run" >/dev/null 2>&1 || c=$((c+1))
    done
    [ "$c" = 0 ] && ok "загруженный модуль виден все 50 раз" \
        || bad "проверка рвётся" "провалов: $c из 50"
fi

# ═══════════════════════════════════════════════════════════════════════════
head_ "6. Чужой services.env не уничтожается и не роняет прогон"
# installed() — это просто [ -f "$SERVICES" ]. По тому же пути свой файл держит
# другой продукт, и свой же может остаться обрезанным от убитого прогона.
# Без проверки всё умирало под set -u в write_services — уже ПОСЛЕ того, как
# редирект обрезал файл: восстановить нечего, а installed() по-прежнему true.
GUARD="$(sed -n '/^plan_services()/,/^}$/p' install.sh)"
WS="$(sed -n '/^write_services()/,/^}$/p' install.sh)"
if [ -z "$GUARD" ] || [ -z "$WS" ]; then
    bad "не нашли plan_services/write_services" "мерить нечего"
else
    foreign="$WORK/foreign.env"
    printf "WAN='eth0'\nENDPOINT='1.2.3.4'\nIFACES='wg0'\n" > "$foreign"
    before="$(md5sum "$foreign" | cut -d" " -f1)"
    out="$(bash -c "set -euo pipefail
        SERVICES='$foreign'; AWG_DIR='$WORK'; CLI_PORTS=''; CLI_MTU=''; CLI_DNS=''
        LAYER2=1; LAYER3=1; ENDPOINT=''; CLIENT_DIR='$WORK/clients'; PLAN=0
        installed() { [ -f \"\$SERVICES\" ]; }
        log() { :; }; err() { printf 'ERR %s\n' \"\$*\"; }
        $GUARD
        $WS
        plan_services && write_services
        echo 'ДОШЛИ'" 2>&1)" || true
    after="$(md5sum "$foreign" | cut -d" " -f1)"
    case "$out" in
        *"это не план awg3"*) ok "чужой файл распознан и назван" ;;
        *) bad "чужой файл не распознан" "вышло «$(printf '%s' "$out" | head -2 | tr '\n' ' ')»" ;;
    esac
    [ "$before" = "$after" ] && ok "и не уничтожен" \
        || bad "чужой services.env перезаписан" "восстановить его неоткуда"
    case "$out" in
        *ДОШЛИ*) bad "прогон продолжился на чужом файле" ;;
        *) ok "прогон остановлен, а не продолжен вслепую" ;;
    esac

    # Старая установка без новых ключей обязана обновляться, а не получать отказ:
    # MTU/DNS/WAN восстановимы, порт и подсеть — нет.
    old="$WORK/old.env"
    printf "IFACE2='awg2'\nIFACE3='awg3'\nSUBNET2='10.29.79'\nSUBNET3='10.29.80'\nPORT2='51820'\nPORT3='51821'\n" > "$old"
    out="$(bash -c "set -euo pipefail
        SERVICES='$old'; AWG_DIR='$WORK'; CLI_PORTS=''; CLI_MTU=''; CLI_DNS=''
        LAYER2=1; LAYER3=1; ENDPOINT='vpn.example.org'; CLIENT_DIR='$WORK/clients'; PLAN=0
        installed() { [ -f \"\$SERVICES\" ]; }
        log() { :; }; err() { printf 'ERR %s\n' \"\$*\"; }
        $GUARD
        $WS
        plan_services && write_services
        echo 'ДОШЛИ'" 2>&1)" || true
    case "$out" in
        *ДОШЛИ*) ok "старый файл без MTU/DNS/WAN доезжает до записи" ;;
        *) bad "старая установка получила отказ" "вышло «$(printf '%s' "$out" | head -2 | tr '\n' ' ')»" ;;
    esac
    grep -q "PORT2='51820'" "$old" && ok "порт при этом не выдуман заново" \
        || bad "порт изменился" "выданные конфиги перестанут подключаться"
fi

# ═══════════════════════════════════════════════════════════════════════════
head_ "7. Восстановление из .enc не оставляет ключи в /tmp"
DR="$(sed -n '/^_restore_part()/,/^}$/p;/^do_restore()/,/^}$/p' bin/awg-backup.sh)"
if [ -z "$DR" ]; then
    bad "не нашли do_restore" "мерить нечего"
elif ! command -v openssl >/dev/null 2>&1; then
    printf '  · openssl нет — раздел пропущен\n'
else
    mkdir -p "$WORK/stage/amneziawg" "$WORK/stage/clients" "$WORK/stage/state"
    echo "awg3" > "$WORK/stage/MANIFEST"
    echo "PrivateKey = SECRET" > "$WORK/stage/amneziawg/awg2.conf"
    # Настоящий архив всегда несёт services.env и клиентские конфиги, а
    # восстановление теперь вслух жалуется на их отсутствие. Раздел мерит
    # гигиену /tmp, а не полноту архива, — обставляем стенд как настоящий.
    printf 'LAYER2=1\nIFACE2=awg2\n' > "$WORK/stage/amneziawg/services.env"
    mkdir -p "$WORK/stage/clients/awg2"
    printf 'PrivateKey = CL1\n' > "$WORK/stage/clients/awg2/awg2-c1-am.conf"
    tar -czf "$WORK/bk.tar.gz" -C "$WORK/stage" .
    PW=hunter2 openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt \
        -in "$WORK/bk.tar.gz" -out "$WORK/bk.tar.gz.enc" -pass env:PW 2>/dev/null
    rm -f /tmp/awg-restore.*          # mktemp в do_restore жёстко в /tmp
    bash -c "set -euo pipefail
        AWG_DIR='$WORK/etc'; DEST='$WORK/dest'; export BACKUP_PASS=hunter2
        RESTORE_MARK='$WORK/etc/.restore-in-progress'
        # Замок объявлен на уровне файла, а вырезается только тело функции.
        # Здесь он не при чём: стенд мерит прерывание, а не блокировку —
        # её проверяет tests/test_restore_integrity.sh на настоящем скрипте.
        lock_wait() { :; }; lock_drop() { :; }
        log() { :; }; err() { printf '%s\n' \"\$*\" >&2; }
        systemctl() { :; }
        $DR
        do_restore '$WORK/bk.tar.gz.enc'" >/dev/null 2>&1
    rc=$?
    [ "$rc" = 0 ] && ok "успешное восстановление отдаёт 0" \
        || bad "успешное восстановление отдаёт $rc" "обёртки прочтут это как отказ"
    left="$(find /tmp -maxdepth 1 -name 'awg-restore.*' 2>/dev/null | wc -l)"
    [ "$left" = 0 ] && ok "расшифрованный архив убран из /tmp" \
        || bad "в /tmp остались приватные ключи" "файлов: $left"
    rm -f /tmp/awg-restore.*
    # openssl читает пароль из ОКРУЖЕНИЯ. read создаёт обычную переменную
    # оболочки, поэтому без export введённый с клавиатуры верный пароль давал
    # «неверный пароль или битый архив» — интерактивное восстановление
    # зашифрованного архива не работало никогда.
    if sed -n '/read -rsp "Пароль архива/,+12p' bin/awg-backup.sh | grep -q 'export BACKUP_PASS'; then
        ok "введённый с клавиатуры пароль уезжает в окружение"
    else
        bad "пароль из read не экспортируется" "openssl его не увидит"
    fi
    grep -q 'PrivateKey = SECRET' "$WORK/etc/awg2.conf" 2>/dev/null \
        && ok "и данные при этом действительно восстановлены" \
        || bad "восстановление не разложило файлы"
fi

# ═══════════════════════════════════════════════════════════════════════════
head_ "8. Проверка MTU стоит на вводе, а не на сохранённом значении"
# Разница принципиальная. На ввод человека проверка обязана быть: `--mtu 60`
# опускал потолок джанка ниже Jmin. А на значение из services.env её ставить
# НЕЛЬЗЯ — оно приезжает в awg-obfuscation.sh на каждом прогоне, включая
# --reapply: отказ сломал бы --update работающему серверу, а тихая подмена
# поменяла бы ему MTU и MTU в клиентских конфигах.
if grep -q '576' install.sh && grep -q '1500' install.sh; then
    ok "установщик проверяет диапазон введённого MTU"
else
    bad "в установщике нет диапазона MTU" "--mtu 60 снова доедет до генератора"
fi
if grep -q 'CLI_MTU' install.sh && grep -q 'нужно целое от 576 до 1500' install.sh; then
    ok "и отказывает, а не подставляет своё"
else
    bad "нет внятного отказа на битый --mtu"
fi

# Проверка статическая: убеждаемся, что рубежа с диапазоном там НЕТ.
f=bin/awg-obfuscation.sh
if grep -v '^[[:space:]]*#' "$f" | grep -q '\-ge 576'; then
    bad "$f режет сохранённый MTU" "это сломает --update там, где значение уже записано"
else
    ok "$f пропускает сохранённый MTU как есть"
fi


# ═══════════════════════════════════════════════════════════════════════════
head_ "9. Занятый IP не выдаётся второму клиенту"
# Честно про охват: в /24 занятых адресов не больше 253, список влезает в буфер
# трубы, и SIGPIPE тут не случается. То есть поведенчески этот раздел не может
# покраснеть от возврата к `echo | grep -q` — за ту ловушку отвечает сам вид
# кода. Здесь проверяется, что логика подсчёта считает правильно, а два клиента
# с одним адресом — это уже выданные конфиги, и один из них перестанет
# работать, как только следующий `awg set` заберёт cryptokey-маршрут.
NEXT="$(sed -n '/^next_ip()/,/^}$/p' bin/awg-client.sh)"
if [ -z "$NEXT" ]; then
    bad "не нашли next_ip" "мерить нечего"
else
    nip() {  # nip <файл серверного конфига> → выданный адрес или ОТКАЗ
        bash -c "set -euo pipefail
            SUBNET=10.29.79; SERVER_CONF='$1'
            die() { printf 'DIE %s\n' \"\$*\"; exit 1; }
            $NEXT
            next_ip" 2>&1 || true
    }

    conf="$WORK/srv.conf"; : > "$conf"
    for i in $(seq 2 200); do echo "AllowedIPs = 10.29.79.$i/32" >> "$conf"; done
    out="$(nip "$conf")"
    [ "$out" = "10.29.79.201" ] && ok "выдан первый действительно свободный адрес" \
        || bad "выдан занятый или неверный адрес" "вернулось «$out»"

    : > "$conf"
    out="$(nip "$conf")"
    [ "$out" = "10.29.79.2" ] && ok "на пустом конфиге выдаётся первый адрес" \
        || bad "на пустом конфиге выдан «$out»"

    { echo "AllowedIPs = 10.29.80.2/32"; echo "AllowedIPs = 10.29.80.3/32"; } > "$conf"
    out="$(nip "$conf")"
    [ "$out" = "10.29.79.2" ] && ok "адреса чужой подсети не считаются занятыми" \
        || bad "чужая подсеть повлияла на выбор" "вернулось «$out»"

    # Экранирование точек в ${SUBNET//./\.} различается ТОЛЬКО таким входом:
    # без него точка в регулярке совпадает с любым символом. Соседняя подсеть
    # для этого не годится — «10.29.79.» и без экранирования не совпадёт с
    # «10.29.80.», потому что 79 и 80 отличаются буквально. Вход нарочно
    # вырожденный: он здесь не как реалистичный, а как единственный, который
    # краснеет, если экранирование убрать.
    printf 'AllowedIPs = 10x29x79.2/32\n' > "$conf"
    out="$(nip "$conf")"
    [ "$out" = "10.29.79.2" ] && ok "точки в подсети экранированы — 10x29x79 не считается своим" \
        || bad "точка в регулярке совпала с любым символом" "вернулось «$out»"

    : > "$conf"
    for i in $(seq 2 254); do echo "AllowedIPs = 10.29.79.$i/32" >> "$conf"; done
    out="$(nip "$conf")"
    case "$out" in
        DIE*закончились*) ok "исчерпание диапазона — отказ с объяснением" ;;
        *) bad "исчерпание не названо" "вернулось «$out»" ;;
    esac
fi


# ═══════════════════════════════════════════════════════════════════════════
head_ "10. Обрезанный services.env отвергается, а не принимается за исправный"
# `${!k+x}` истинно и для `PORT2=''` — файл, обрезанный ровно на знаке
# равенства, проходил страж, а дальше `PORT="${PORT2:-0}"` выписывал клиенту
# `Endpoint host:0`. Спрашиваем непустоту только у включённого слоя: на сервере
# с одним слоем 2.0 значения 3.0 могут быть пустыми законно.
PSF="$(sed -n '/^plan_services()/,/^}$/p' install.sh)"
if [ -z "$PSF" ]; then
    bad "не нашли plan_services" "мерить нечего"
else
    guard() {  # guard <содержимое services.env> → вывод
        local d; d="$(mktemp -d)"
        printf '%s\n' "$1" > "$d/services.env"
        ( set -uo pipefail
          # shellcheck disable=SC2034
          export SERVICES="$d/services.env" CLI_PORTS="" CLI_VER="" CLI_DNS=""
          log() { :; }
          err() { printf 'ERR %s\n' "$*"; }
          installed() { [ -f "$SERVICES" ]; }
          busy_ports() { :; }; pick_random_port() { echo 40000; }
          eval "$PSF"
          plan_services
          printf 'PASS PORT2=[%s]\n' "${PORT2:-}" ) 2>&1
        rm -rf "$d"
    }

    FULL="LAYER2=1
LAYER3=0
IFACE2=awg2
IFACE3=awg3
SUBNET2=10.29.79
SUBNET3=10.29.80
PORT2=51820
PORT3=51821"

    out="$(guard "$FULL")"
    case "$out" in
        *PASS*) ok "полный файл проходит" ;;
        *) bad "исправный файл отвергнут" "$out" ;;
    esac

    out="$(guard "${FULL%%PORT2=*}PORT2=
PORT3=")"
    case "$out" in
        *"ERR"*"обрезан"*PORT2*) ok "обрезанный отвергнут, и назван ключ" ;;
        *PASS*) bad "обрезанный файл прошёл насквозь" "клиенту уедет Endpoint host:0" ;;
        *) bad "неожиданный исход" "$out" ;;
    esac
    case "$out" in
        *"restore"*) ok "и сказано, чем чинить" ;;
        *) bad "нет подсказки" "$out" ;;
    esac

    # Слой 3.0 выключен — его пустые значения законны и отказа не вызывают.
    out="$(guard "LAYER2=1
LAYER3=0
IFACE2=awg2
IFACE3=
SUBNET2=10.29.79
SUBNET3=
PORT2=51820
PORT3=")"
    case "$out" in
        *PASS*) ok "пустые значения выключенного слоя не мешают" ;;
        *) bad "отказ из-за выключенного слоя" "исправному серверу отказали в обновлении: $out" ;;
    esac
fi

printf '\n'
[ "$fail" = 0 ] && echo "═══ ВСЁ ЗЕЛЁНОЕ ═══" || echo "═══ ЕСТЬ ПАДЕНИЯ ═══"
exit $fail
