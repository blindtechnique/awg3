#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Прерывание посреди многошаговой операции.
#
# Вопрос здесь не «падает ли команда», а другой:
#
#     если операция умерла между двумя необратимыми действиями,
#     приведёт ли ПОВТОРНЫЙ запуск систему в согласованное состояние?
#
# Это следующий класс после «команда упала»: система остаётся в промежуточном
# состоянии, и повторный запуск либо доделывает работу, либо коротит на
# признаке, который первый прогон успел записать, — и тогда работа не будет
# доделана никогда.
#
# Прерывание воспроизводится детерминированно: внешняя команда, которую
# операция зовёт по разу на шаг, подменяется заглушкой, выходящей с ошибкой на
# N-м вызове. Под set -e это и есть смерть посреди цикла.
#
#   bash tests/test_interrupt.sh
fail=0
ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
cd "$ROOT" || exit 1

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

ok()  { printf '  ✔ %s\n' "$1"; }
bad() { printf '  ✘ %s\n' "$1"; [ $# -gt 1 ] && printf '     %s\n' "$2"; fail=1; }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# ── стенд: сервер с выданными клиентами ─────────────────────────────────────
mk_stand() {  # mk_stand <каталог> <клиентов>
    local d="$1" n="$2" i
    mkdir -p "$d/etc" "$d/dest/clients/awg2" "$d/bin"
    {
        echo "LAYER2='1'"; echo "LAYER3='0'"
        echo "IFACE2='awg2'"; echo "IFACE3='awg3'"
        echo "SUBNET2='10.29.79'"; echo "SUBNET3='10.29.80'"
        echo "PORT2='51820'"; echo "PORT3='51821'"
        echo "MTU2='1420'"; echo "MTU3='1380'"
        echo "DNS='1.1.1.1'"; echo "ENDPOINT='vpn.example.org'"
        echo "WAN='eth0'"; echo "CLIENT_DIR='$d/dest/clients'"; echo "KMOD3='0'"
    } > "$d/etc/services.env"
    # профиль А — тот, с которым конфиги были выданы
    printf "AWG_Jc='4'\nAWG_S1='80'\n" > "$d/etc/obfuscation.env"
    printf '[Interface]\nPrivateKey = SRV\nListenPort = 51820\n' > "$d/etc/awg2.conf"
    for i in $(seq 1 "$n"); do
        printf '[Interface]\nPrivateKey = K%s\nAddress = 10.29.79.%s/32\nJc = 4\nS1 = 80\n\n[Peer]\nPublicKey = SRVPUB\nAllowedIPs = 0.0.0.0/0\n' \
            "$i" "$((i + 1))" > "$d/dest/clients/awg2/awg2-c$i-am.conf"
    done
}

# копия скрипта с путями на стенд
client_sh() {  # client_sh <каталог> → путь
    local d="$1" f="$1/bin/awg-client.sh"
    [ -f "$f" ] && { echo "$f"; return; }
    cp bin/awg-client.sh "$f"
    sed -i "s#^AWG_DIR=.*#AWG_DIR=\"$d/etc\"#" "$f"
    sed -i "s#^DEST=.*#DEST=\"$d/dest\"#" "$f"
    sed -i "s#^CLIENT_DIR=.*#CLIENT_DIR=\"$d/dest/clients\"#" "$f"
    chmod +x "$f"
    echo "$f"
}

profiles() {  # profiles <каталог> → сколько конфигов с каким Jc
    grep -h '^Jc' "$1"/dest/clients/awg2/*-am.conf 2>/dev/null | sort | uniq -c | tr -d ' ' | tr '\n' ' '
}

# ═══════════════════════════════════════════════════════════════════════════
head_ "1. regen-all: смерть посреди списка клиентов"

D="$WORK/regen"; mk_stand "$D" 6
SH="$(client_sh "$D")"

# профиль сменился: конфиги обязаны переехать с Jc=4 на Jc=9
printf "AWG_Jc='9'\nAWG_S1='81'\n" > "$D/etc/obfuscation.env"

# Заглушка md5sum: операция зовёт её по разу на клиента в начале итерации,
# поэтому «умереть на третьем вызове» = «умереть на третьем клиенте».
STUB="$WORK/stub"; mkdir -p "$STUB"
cat > "$STUB/md5sum" <<'EOS'
#!/bin/bash
c="${STUB_COUNT:-/tmp/awgcnt}"
n=$(( $(cat "$c" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$c"
[ "$n" -ge "${STUB_DIE_AT:-3}" ] && exit 1
exec /usr/bin/md5sum "$@"
EOS
chmod +x "$STUB/md5sum"

echo 0 > "$WORK/cnt"
PATH="$STUB:$PATH" STUB_COUNT="$WORK/cnt" STUB_DIE_AT=3 \
    bash "$SH" regen-all >/dev/null 2>&1 && rc=0 || rc=$?
[ "$rc" != 0 ] && ok "прогон прерван (код $rc)" \
    || bad "прогон не прервался" "заглушка не сработала — дальше мерить нечего"

mixed="$(profiles "$D")"
case "$mixed" in
    *"Jc=4"*|*"Jc = 4"*)
        case "$mixed" in
            *"Jc=9"*|*"Jc = 9"*) ok "состояние действительно смешанное: $mixed" ;;
            *) bad "ни один конфиг не успел обновиться" "$mixed — прерывание слишком раннее, тест ничего не мерит" ;;
        esac ;;
    *) bad "все конфиги уже обновлены" "$mixed — прерывание слишком позднее" ;;
esac

# ── повторный запуск, уже без заглушки ─────────────────────────────────────
bash "$SH" regen-all >/dev/null 2>&1 && rc=0 || rc=$?
after="$(profiles "$D")"
[ "$rc" = 0 ] && ok "повторный запуск отработал успешно" \
    || bad "повторный запуск отказал (код $rc)" "после прерывания система не чинится сама"
case "$after" in
    *"Jc = 4"*) bad "часть конфигов осталась со старым профилем" "$after" ;;
    *) ok "все конфиги приведены к одному профилю: $after" ;;
esac

# И ключи клиентов при этом обязаны остаться прежними: перевыпуск ключа
# означал бы, что клиент уже не подключится вообще.
keys="$(grep -h '^PrivateKey' "$D"/dest/clients/awg2/*-am.conf | sort | tr '\n' ' ')"
case "$keys" in
    *K1*K2*K3*K4*K5*K6*) ok "ключи клиентов не тронуты" ;;
    *) bad "ключи клиентов изменились" "$keys" ;;
esac

# ═══════════════════════════════════════════════════════════════════════════
head_ "2. regen-all повторяем: второй прогон подряд ничего не меняет"
# Идемпотентность — то, на чём держится вывод «конфиги переиздавать не нужно».
sum1="$(cat "$D"/dest/clients/awg2/*-am.conf | md5sum)"
bash "$SH" regen-all >/dev/null 2>&1 || true
sum2="$(cat "$D"/dest/clients/awg2/*-am.conf | md5sum)"
[ "$sum1" = "$sum2" ] && ok "повторный прогон не изменил ни байта" \
    || bad "прогон меняет конфиги каждый раз" "владелец будет думать, что клиентам пора раздавать новые"

# ═══════════════════════════════════════════════════════════════════════════
head_ "3. Восстановление, убитое между копированием ключей и клиентов"
# Все cp внутри do_restore идут с `|| true`, поэтому отказом команды операцию
# не прервать — она просто поехала бы дальше. Изображаем настоящее убийство:
# заглушка cp делает kill -9 родителю на N-м вызове. Так выглядят оборванный
# ssh, OOM и ребут, и заодно видно, что бывает, когда trap уже не выполнится.
DR="$(sed -n '/^_restore_part()/,/^}$/p;/^do_restore()/,/^}$/p' bin/awg-backup.sh)"
if [ -z "$DR" ]; then
    bad "не нашли do_restore" "мерить нечего"
else
    R="$WORK/restore"
    mkdir -p "$R/stage/amneziawg" "$R/stage/clients" "$R/stage/state" \
             "$R/etc" "$R/dest/clients"
    echo backup > "$R/stage/MANIFEST"
    printf 'PrivateKey = ИЗ_БЭКАПА\n' > "$R/stage/amneziawg/awg2.conf"
    printf 'PrivateKey = КЛИЕНТ_ИЗ_БЭКАПА\n' > "$R/stage/clients/c1-am.conf"
    # Настоящий архив всегда несёт services.env, а восстановление теперь вслух
    # жалуется на его отсутствие. Стенд мерит прерывание, а не полноту архива.
    printf 'LAYER2=1\nIFACE2=awg2\n' > "$R/stage/amneziawg/services.env"
    ( cd "$R/stage" && tar -czf "$R/bk.tar.gz" . )

    # живое состояние делаем заведомо ДРУГИМ, чтобы отличать восстановленное
    printf 'PrivateKey = ЖИВОЙ\n' > "$R/etc/awg2.conf"
    printf 'PrivateKey = ЖИВОЙ_КЛИЕНТ\n' > "$R/dest/clients/c1-am.conf"

    CPSTUB="$WORK/cpstub"; mkdir -p "$CPSTUB"
    {
        echo '#!/bin/bash'
        echo 'n=$(( $(cat "$CP_COUNT" 2>/dev/null || echo 0) + 1 ))'
        echo 'echo "$n" > "$CP_COUNT"'
        echo '[ "$n" -ge "$CP_DIE_AT" ] && { kill -9 "$PPID"; sleep 5; }'
        echo 'exec /usr/bin/cp "$@"'
    } > "$CPSTUB/cp"
    chmod +x "$CPSTUB/cp"

    run_restore() {  # run_restore <умереть на N-м cp | 0 = не умирать>
        local pfx=""
        [ "$1" != 0 ] && pfx="$CPSTUB:"
        echo 0 > "$WORK/cpcnt"
        # RESTORE_MARK объявлен на уровне файла, а вырезается только тело
        # функции — без этой строки кусок падает под set -u на первой же записи.
        PATH="${pfx}$PATH" CP_COUNT="$WORK/cpcnt" CP_DIE_AT="$1" \
        bash -c "set -euo pipefail
            AWG_DIR=$R/etc; DEST=$R/dest; AZ=$R/az
            RESTORE_MARK=$R/etc/.restore-in-progress
            # Замок объявлен на уровне файла, а вырезается только тело функции.
            # Здесь он не при чём: стенд мерит прерывание, а не блокировку —
            # её проверяет tests/test_restore_integrity.sh на настоящем скрипте.
            lock_wait() { :; }; lock_drop() { :; }
            log() { :; }; err() { :; }; systemctl() { :; }
            $DR
            do_restore $R/bk.tar.gz" >/dev/null 2>&1
    }

    # Сообщение оболочки о сигнале глушим здесь: оно от родителя, а не
    # от самой операции, и в отчёте только мешает.
    { run_restore 2 || true; } 2>/dev/null
    k="$(cat "$R/etc/awg2.conf" 2>/dev/null || true)"
    c="$(cat "$R/dest/clients/c1-am.conf" 2>/dev/null || true)"
    case "$k" in
        *ИЗ_БЭКАПА*)
            case "$c" in
                *ЖИВОЙ*) ok "состояние рассогласовано, как и задумано: ключи из бэкапа, клиенты прежние" ;;
                *) bad "клиенты успели восстановиться" "прерывание слишком позднее" ;;
            esac ;;
        *) bad "ключи не восстановились" "прерывание слишком раннее: [$k]" ;;
    esac

    run_restore 0 && rc=0 || rc=$?
    k="$(cat "$R/etc/awg2.conf" 2>/dev/null || true)"
    c="$(cat "$R/dest/clients/c1-am.conf" 2>/dev/null || true)"
    [ "$rc" = 0 ] && ok "повторное восстановление отработало успешно" \
        || bad "повторное восстановление отказало (код $rc)"
    case "$k$c" in
        *ЖИВОЙ*) bad "после повторного запуска остались куски прежнего состояния" "[$k] [$c]" ;;
        *) ok "повторный запуск довёл восстановление до конца" ;;
    esac
fi


head_ "6. Серверный конфиг переписывается атомарно"
# Единственная копия списка пиров на время записи живёт в переменной, прочитанной
# несколькими строками выше. Обрыв в окне усекающего редиректа оставлял конфиг
# без единого [Peer] — и молча: у ключа сервера ветка восстановления есть, он
# перевыпускается вслух, у пиров её нет. Живое ядро переставало быть копией на
# ближайшем перезапуске интерфейса, после чего доступ выданных клиентов
# пропадал безвозвратно.
trunc=""; noatomic=""
for _f in install.sh bin/awg-obfuscation.sh; do
    [ -f "$_f" ] || continue
    grep -q '} > "$conf"$' "$_f" && trunc="$trunc $_f"
    grep -q 'mv -f "$conf.new" "$conf"' "$_f" || noatomic="$noatomic $_f"
done
[ -z "$trunc" ] \
    && ok "усекающих редиректов в серверный конфиг не осталось" \
    || bad "конфиг переписывается усечением:$trunc" \
           "обрыв в этом окне сотрёт список пиров безвозвратно"
[ -z "$noatomic" ] \
    && ok "и подстановка идёт через временный файл" \
    || bad "нет подстановки через mv:$noatomic" "третье состояние конфига возможно"

# Права должны закрепляться на ВРЕМЕННОМ файле: mv их сохраняет, а chmod после
# подстановки оставил бы окно, в котором конфиг с приватным ключом открыт.
d="$WORK/atom"; rm -rf "$d"; mkdir -p "$d"
conf="$d/i.conf"; printf 'старое\n' > "$conf"
( umask 022; printf 'новое\n' > "$conf.new"; chmod 600 "$conf.new"; mv -f "$conf.new" "$conf" )
m="$(stat -c '%a' "$conf" 2>/dev/null || echo '?')"
[ "$m" = 600 ] && ok "и режим 600 переживает подстановку" \
    || bad "после mv режим $m" "конфиг с приватным ключом сервера остался открытым"
[ -e "$conf.new" ] && bad "временный файл остался рядом" "в нём приватный ключ" \
    || ok "и временный файл не остаётся"


printf '\n'
[ "$fail" = 0 ] && echo "═══ ВСЁ ЗЕЛЁНОЕ ═══" || echo "═══ ЕСТЬ ПАДЕНИЯ ═══"
exit $fail
