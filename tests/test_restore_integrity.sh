#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Что архив на самом деле содержит и что восстановление на самом деле сообщает.
#
# Здесь путь к каталогу слоя везде один (/opt/awg3) — в az-awg2 он разошёлся, и
# бэкап годами молча уходил без клиентских приватных ключей. Раздел 1 сторожит
# именно это согласие, чтобы расхождение не повторилось и тут.
#
# Вторая находка общая для обоих репозиториев: do_restore не мог вернуть
# ненулевой код. Оба systemctl были закрыты `|| true` без даже сообщения, а
# последней строкой стоял литеральный `return 0`. Бот печатает
# «✅ Восстановлено.» ровно по rc = 0 — галочка приходила всегда, в том числе
# когда не перезапускалось вообще ничего.
#
# Статическая часть работает везде; настоящий прогон — под пространством имён.
#
#   bash tests/test_restore_integrity.sh
fail=0
ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
cd "$ROOT" || exit 1

ok()  { printf '  ✔ %s\n' "$1"; }
bad() { printf '  ✘ %s\n' "$1"; [ $# -gt 1 ] && printf '     %s\n' "$2"; fail=1; }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }
warn_() { printf '  · %s\n' "$1"; }

BK=bin/awg-backup.sh
DOC=bin/awg-doctor.sh

# ═══════════════════════════════════════════════════════════════════════════
head_ "1. Каталог слоя назван одинаково во всём репозитории"
declare -A seen=()
for f in install.sh bin/awg-backup.sh bin/awg-client.sh bin/awg-doctor.sh \
         bin/awg-menu.sh bin/awg-upstream-check.sh; do
    d="$(sed -n 's/^DEST=["'"'"']\?\([^"'"'"' ]*\).*/\1/p' "$f" 2>/dev/null | head -1)"
    [ -n "$d" ] && seen["$d"]="${seen[$d]:-} $f"
done
if [ "${#seen[@]}" = 1 ]; then
    ok "DEST один и тот же везде: ${!seen[*]}"
else
    for d in "${!seen[@]}"; do printf '     %-20s %s\n' "$d" "${seen[$d]}"; done
    bad "DEST разошёлся между файлами" "бэкап читал бы не тот каталог, в котором лежат данные"
fi

# ═══════════════════════════════════════════════════════════════════════════
head_ "2. Код возврата восстановления больше не константа"
body="$(sed -n '/^do_restore()/,/^}$/p' "$BK")"
if [ -z "$body" ]; then
    bad "не нашли do_restore" "мерить нечего"
else
    printf '%s\n' "$body" | grep -q 'return "\$rc"' \
        && ok "do_restore возвращает накопленный код" \
        || bad "do_restore не возвращает накопленный код" "отказ снова не доедет до бота"
    n="$(printf '%s\n' "$body" | grep -c 'systemctl restart.*2>/dev/null' || true)"
    [ "$n" = 0 ] && ok "причина отказа systemctl больше не уходит в /dev/null" \
        || bad "$n перезапусков всё ещё глушат stderr" "бот показывает stderr только при ненулевом коде"
    printf '%s\n' "$body" | grep -q 'RESTORE_MARK' \
        && ok "метка незавершённого восстановления ставится" \
        || bad "метки нет" "прерывание останется незамеченным"
fi
grep -q 'check_marks' "$DOC" && ok "доктор проверяет метку" || bad "доктор про метку не знает"
m_line="$(grep -n '^check_marks$' "$DOC" | head -1 | cut -d: -f1)"
s_line="$(grep -n '^\[ -f "\$SERVICES" \]' "$DOC" | head -1 | cut -d: -f1)"
if [ -n "$m_line" ] && [ -n "$s_line" ] && [ "$m_line" -lt "$s_line" ]; then
    ok "и проверяет раньше, чем требует services.env"
else
    bad "метка проверяется после требования services.env ($m_line / $s_line)" \
        "самый тяжёлый случай прерывания не покажется никогда"
fi


# ═══════════════════════════════════════════════════════════════════════════
head_ "3. Замок на состояние слоя объявлен там, где он работает"
# /tmp исключён жёстко: у бота в юните PrivateTmp=true, его /tmp отдельный —
# замок там не сериализовал бы ничего, при этом выглядя рабочим.
lockdecl="$(grep -h '^AWG_LOCK=' bin/awg-backup.sh bin/awg-client.sh 2>/dev/null | head -1)"
case "$lockdecl" in
    *'/run/'*) lp="${lockdecl#*:-}"; ok "замок в /run: ${lp%%\}*}" ;;
    *'/tmp/'*) bad "замок в /tmp" "PrivateTmp=true у бота — стороны увидят РАЗНЫЕ /tmp" ;;
    '')        bad "замка нет вовсе" "восстановление разойдётся с таймерами" ;;
    *)         bad "замок вне /run: $lockdecl" "каталог слоя переписывает само восстановление" ;;
esac
grep -q 'PrivateTmp=true' systemd/awg-bot.service 2>/dev/null \
    && ok "и причина всё ещё в силе: PrivateTmp=true у юнита бота" \
    || warn_ "PrivateTmp у бота больше нет — обоснование места замка стоит перечитать"

for pair in "bin/awg-backup.sh:бэкап и восстановление" "bin/awg-client.sh:правка клиентов и проверка сроков" "bin/awg_stats.py:поллер статистики"; do
    f="${pair%%:*}"; what="${pair#*:}"
    if grep -q 'lock_wait\|lock_try\|state_lock' "$f" 2>/dev/null; then
        ok "$what берёт замок"
    else
        bad "$what замок не берёт" "дыра в блокировке хуже её отсутствия — выглядит защищённым"
    fi
done

# Замок обязан быть отпущен до перезапуска сервисов: в AZ doall.sh через
# ванильный custom-up.sh запускает awg-reintegrate.sh ФОНОМ, и фоновый
# потомок унаследовал бы дескриптор, держа замок всю свою жизнь.
d_line="$(grep -n 'lock_drop' bin/awg-backup.sh | tail -1 | cut -d: -f1)"
s_line="$(grep -n 'Перезапуск сервисов' bin/awg-backup.sh | head -1 | cut -d: -f1)"
if [ -n "$d_line" ] && [ -n "$s_line" ] && [ "$d_line" -lt "$s_line" ]; then
    ok "и отпускается до перезапуска сервисов"
else
    bad "замок держится на время перезапуска ($d_line / $s_line)" \
        "фоновый потомок унаследует дескриптор и не отпустит его никогда"
fi

# ═══════════════════════════════════════════════════════════════════════════
head_ "4. stats.db не копируется простым cp"
if grep -q 'cp "\$DEST/stats\.db"' bin/awg-backup.sh; then
    bad "stats.db копируется через cp" \
        "в режиме WAL это даёт базу без схемы — «no such table»"
else
    ok "простого cp для stats.db больше нет"
fi
grep -q 'src.backup(dst)' bin/awg-backup.sh \
    && ok "снимок берётся через backup API sqlite" \
    || bad "нет снимка через backup API" "горячая копия WAL-базы некорректна"
grep -q 'rm -f "\$DEST/stats.db-wal"' bin/awg-backup.sh \
    && ok "восстановление сносит осиротевшие журналы базы" \
    || bad "старый -wal остаётся после восстановления" \
           "sqlite проиграет его поверх и отдаст данные ПРЕЖНЕЙ установки"

# ═══════════════════════════════════════════════════════════════════════════
if ! unshare -Urm --map-root-user true 2>/dev/null; then
    printf '\n  · пространства имён недоступны — остальное пропущено\n\n'
    [ -n "${GITHUB_ACTIONS:-}" ] && printf '::notice title=%s::%s\n' \
        "test_restore_integrity" \
        "пропущено: unshare -Urm недоступен, настоящий прогон backup/restore не проверялся"
    exit $fail
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
# /run тоже: без записываемого /run стенд мерил бы деградацию замка, а не сам замок
for d in /etc /root /opt /usr/local /run; do
    mount -t tmpfs none "$d" 2>/dev/null || { echo "  · не смонтировать tmpfs на $d"; exit 0; }
done
cp -a "$W/etc-orig/." /etc/ 2>/dev/null || true

AWG=/etc/amnezia/amneziawg
DEST=/opt/awg3
mkdir -p "$AWG" "$DEST/clients/awg2"

cat > "$AWG/services.env" <<EOS
LAYER2=1
LAYER3=0
KMOD3=0
IFACE2=awg2
PORT2=41234
SUBNET2=10.29.79
WAN=eth0
ENDPOINT=vpn.example.org
EOS
printf "AWG_Jc='4'\n" > "$AWG/obfuscation.env"
printf '[Interface]\nPrivateKey = SRV_KEY\nListenPort = 41234\n' > "$AWG/awg2.conf"
for i in 1 2 3; do
    printf '[Interface]\nPrivateKey = CLIENT_%s\n' "$i" > "$DEST/clients/awg2/awg2-c$i-am.conf"
done
: > "$DEST/stats.db"; printf 'c1\t2030-01-01\n' > "$DEST/expiry.tsv"
printf "AWG_BOT_TOKEN='x'\nAWG_BOT_ADMINS='999'\nAWG_ENDPOINT='vpn.example.org'\n" > "$DEST/install-state.env"

S="$W/stub"; mkdir -p "$S"
for c in ip awg awg-quick; do printf '#!/bin/sh\nexit 0\n' > "$S/$c"; done
{
    echo '#!/bin/sh'
    echo '[ "${SYSTEMCTL_FAIL:-0}" = 1 ] && { echo "Job failed. See journalctl." >&2; exit 1; }'
    echo 'exit 0'
} > "$S/systemctl"
# chmod внутри do_restore зовётся ровно один раз — сразу после ВСЕХ копирований
# и до блока перезапуска. Убийство на нём и есть искомая граница:
# «файлы новые, сервисы старые».
{
    echo '#!/bin/bash'
    echo '[ "${CHMOD_KILL:-0}" = 1 ] && { kill -9 "$PPID"; sleep 5; }'
    echo 'exec /bin/chmod "$@"'
} > "$S/chmod"
chmod +x "$S"/*
export PATH="$S:$PATH"

BK="$STAND_REPO/bin/awg-backup.sh"
DOC="$STAND_REPO/bin/awg-doctor.sh"
MARK="$AWG/.restore-in-progress"
CL="$STAND_REPO/bin/awg-client.sh"
AWG_MAIN_CONF="$AWG/awg2.conf"

# ═══════════════════════════════════════════════════════════════════════════
head_ "3. Архив содержит клиентские приватные ключи"
bash "$BK" backup "$W/bk.tar.gz" >"$W/bk.log" 2>&1; rc=$?
[ "$rc" = 0 ] && ok "бэкап отработал успешно" || bad "бэкап отказал (код $rc)" "$(tail -2 "$W/bk.log")"
mkdir -p "$W/unpack" && tar -xzf "$W/bk.tar.gz" -C "$W/unpack" 2>/dev/null
n="$(grep -rl 'PrivateKey = CLIENT_' "$W/unpack" 2>/dev/null | wc -l)"
[ "$n" = 3 ] && ok "все 3 клиентских конфига с приватными ключами внутри архива" \
    || bad "в архиве $n клиентских конфигов из 3" \
           "переиздать их нечем — в серверном конфиге одни публичные"
[ -f "$W/unpack/state/stats.db" ] && ok "stats.db в архиве" || bad "stats.db не попал в архив"
[ -f "$W/unpack/state/expiry.tsv" ] && ok "expiry.tsv в архиве" \
    || bad "expiry.tsv не попал в архив" "сроки временных клиентов не наступят"

# ═══════════════════════════════════════════════════════════════════════════
head_ "4. Смерть между копированием файлов и перезапуском сервисов"
printf '[Interface]\nPrivateKey = ЖИВОЙ\n' > "$AWG/awg2.conf"
rm -f "$DEST/clients/awg2/awg2-c1-am.conf"
{ CHMOD_KILL=1 bash "$BK" restore "$W/bk.tar.gz" >"$W/r1.log" 2>&1; rc=$?; } 2>/dev/null
grep -q 'SRV_KEY' "$AWG/awg2.conf" && ok "файлы уже подменены восстановленными" \
    || bad "файлы не подменены" "прерывание слишком раннее"
[ -f "$MARK" ] && ok "метка осталась — операция не доведена до конца" \
    || bad "метки нет" "прерывание в этом окне снова невидимо"
mark_arch="$(sed -n 's/^MARK_ARCHIVE=//p' "$MARK" 2>/dev/null)"
[ "$mark_arch" = "$W/bk.tar.gz" ] && ok "в метке лежит путь архива — есть чем повторить" \
    || bad "в метке нет пути архива" "[$mark_arch]"
docout="$(bash "$DOC" 2>&1 || true)"
case "$docout" in
    *"восстановление не доведено до конца"*) ok "доктор говорит об этом вслух" ;;
    *) bad "доктор молчит о незавершённом восстановлении" \
           "владелец, не читавший вывод прогона, ничего не узнает" ;;
esac

# ═══════════════════════════════════════════════════════════════════════════
head_ "5. Сервисы не поднялись — это отказ, а не успех"
SYSTEMCTL_FAIL=1 bash "$BK" restore "$W/bk.tar.gz" >"$W/r2.log" 2>&1; rc=$?
[ "$rc" != 0 ] && ok "код возврата ненулевой ($rc) — бот покажет ❌, а не галочку" \
    || bad "код возврата 0 при неподнявшемся тоннеле" "это и есть зелень поверх мёртвого сервера"
grep -q 'не перезапущено' "$W/r2.log" && ok "сказано, что именно не встало" \
    || bad "отказ перезапуска не назван" "$(tail -3 "$W/r2.log")"
grep -q 'journalctl' "$W/r2.log" && ok "и куда смотреть" || bad "нет подсказки, где искать причину"
grep -q 'Job failed' "$W/r2.log" && ok "причина от systemd доехала до вывода" \
    || bad "stderr systemd по-прежнему проглочен" "снятие 2>/dev/null не сработало"
[ -f "$MARK" ] && ok "метка оставлена: файлы новые, сервисы старые" \
    || bad "метка снята при неподнявшихся сервисах" "ровно тот случай, ради которого она есть"

# ═══════════════════════════════════════════════════════════════════════════
head_ "6. Успешное восстановление снимает метку и возвращает ноль"
bash "$BK" restore "$W/bk.tar.gz" >"$W/r3.log" 2>&1; rc=$?
[ "$rc" = 0 ] && ok "код возврата 0" || bad "успешный прогон отдал $rc" "$(tail -3 "$W/r3.log")"
[ -f "$MARK" ] && bad "метка осталась после успешного прогона" "доктор будет пугать зря" \
    || ok "метка снята"
n="$(find "$DEST/clients" -name '*-am.conf' | wc -l)"
[ "$n" = 3 ] && ok "все 3 клиентских конфига вернулись на место" \
    || bad "восстановлено $n клиентских конфигов из 3"
grep -q 'CLIENT_1' "$DEST/clients/awg2/awg2-c1-am.conf" 2>/dev/null \
    && ok "и приватный ключ удалённого клиента вернулся" \
    || bad "приватный ключ не восстановлен"

# ═══════════════════════════════════════════════════════════════════════════
head_ "7. Архив без клиентских ключей — молчать о нём нельзя"
mkdir -p "$W/old/amneziawg" "$W/old/clients" "$W/old/state"
printf '[Interface]\nPrivateKey = SRV_KEY\n' > "$W/old/amneziawg/awg2.conf"
cp "$AWG/services.env" "$W/old/amneziawg/"
echo old > "$W/old/MANIFEST"
( cd "$W/old" && tar -czf "$W/old.tar.gz" . )
bash "$BK" restore "$W/old.tar.gz" >"$W/r4.log" 2>&1; rc=$?
grep -q 'нет клиентских конфигов' "$W/r4.log" \
    && ok "прогон сказал, что клиентских конфигов в архиве нет" \
    || bad "про пустой архив ничего не сказано" "$(tail -3 "$W/r4.log")"
[ "$rc" != 0 ] && ok "и вернул ненулевой код ($rc)" \
    || bad "код 0 на архиве без клиентских ключей" "владелец узнает об этом в худший день"


# ═══════════════════════════════════════════════════════════════════════════
head_ "8. Занятый замок: таймеры пропускают тик, а не портят состояние"
LK="$W/state.lock"
exec 8>"$LK"
flock -n 8 || { bad "стенд не смог взять замок сам" "мерить нечего"; }

AWG_LOCK="$LK" bash "$CL" expire-check >"$W/exp.log" 2>&1; rc=$?
[ "$rc" = 0 ] && ok "expire-check вышел с нулём — пропуск тика это не отказ" \
    || bad "expire-check отдал $rc при занятом замке" "$(tail -2 "$W/exp.log")"
grep -q 'пропускаю тик' "$W/exp.log" && ok "и сказал, что именно сделал" \
    || bad "expire-check промолчал о пропуске" "$(tail -2 "$W/exp.log")"

if [ -f "$STAND_REPO/bin/awg_stats.py" ]; then
    AWG_LOCK="$LK" AWG_STATS_DB="$DEST/stats.db" \
        python3 "$STAND_REPO/bin/awg_stats.py" poll >"$W/poll.log" 2>&1; rc=$?
    [ "$rc" = 0 ] && ok "poll вышел с нулём" \
        || bad "poll отдал $rc при занятом замке" "$(tail -2 "$W/poll.log")"
    grep -q 'пропускаю тик' "$W/poll.log" && ok "и тоже сказал об этом" \
        || bad "poll промолчал о пропуске" "$(tail -2 "$W/poll.log")"
fi

# Восстановление под занятым замком не должно НАЧАТЬСЯ: ни метки, ни правок.
rm -f "$MARK"
# Часовой: без него проверка проходит и тогда, когда конфиг УЖЕ совпадает с
# архивным, — то есть подтверждает исключение там, где его нет.
printf '[Interface]
PrivateKey = ЧАСОВОЙ
' > "$AWG_MAIN_CONF"
before="$(cat "$AWG_MAIN_CONF" 2>/dev/null || true)"
AWG_LOCK="$LK" timeout 5 bash "$BK" restore "$W/bk.tar.gz" >"$W/blk.log" 2>&1
[ -f "$MARK" ] && bad "восстановление поставило метку при занятом замке" \
                      "значит оно уже начало писать" \
    || ok "восстановление не поставило метку — оно ещё не начиналось"
[ "$(cat "$AWG_MAIN_CONF" 2>/dev/null || true)" = "$before" ] \
    && ok "и ни один файл не тронут" \
    || bad "конфиг изменился при занятом замке" "взаимного исключения нет"
exec 8>&-

# ═══════════════════════════════════════════════════════════════════════════
head_ "9. Живая база в режиме WAL переживает бэкап и восстановление"
python3 - "$DEST/stats.db" <<'PYMK'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("PRAGMA journal_mode=WAL")
c.execute("CREATE TABLE IF NOT EXISTS t(k INTEGER PRIMARY KEY, v TEXT)")
for i in range(200):
    c.execute("INSERT INTO t(v) VALUES (?)", ("изархива%d" % i,))
c.commit()
# соединение НЕ закрываем штатно — оставляем непустой -wal, как живой поллер
import os
os._exit(0)
PYMK
wal="$(stat -c%s "$DEST/stats.db-wal" 2>/dev/null || echo 0)"
[ "$wal" != 0 ] && ok "стенд воспроизвёл живую базу: -wal $wal байт" \
    || bad "не удалось получить непустой -wal" "мерить нечего"

bash "$BK" backup "$W/wal.tar.gz" >"$W/walbk.log" 2>&1
rm -rf "$W/walun"; mkdir -p "$W/walun"; tar -xzf "$W/wal.tar.gz" -C "$W/walun" 2>/dev/null
got="$(python3 - "$W/walun/state/stats.db" <<'PYRD'
import sqlite3, sys
try:
    print(sqlite3.connect(sys.argv[1]).execute("SELECT count(*) FROM t").fetchone()[0])
except Exception as e:
    print("ОШИБКА: %s" % e)
PYRD
)"
[ "$got" = 200 ] && ok "в архиве все 200 записей" \
    || bad "в архиве: $got" "простой cp WAL-базы даёт «no such table» — потеряна вся схема"

# Подкладываем ЧУЖУЮ живую базу с непустым -wal и восстанавливаем поверх.
python3 - "$DEST/stats.db" <<'PYSRV'
import os, sqlite3, sys
p = sys.argv[1]
for s in ("", "-wal", "-shm"):
    try: os.unlink(p + s)
    except OSError: pass
c = sqlite3.connect(p)
c.execute("PRAGMA journal_mode=WAL")
c.execute("CREATE TABLE t(k INTEGER PRIMARY KEY, v TEXT)")
for i in range(500):
    c.execute("INSERT INTO t(v) VALUES (?)", ("прежний%d" % i,))
c.commit()
os._exit(0)
PYSRV
bash "$BK" restore "$W/wal.tar.gz" >"$W/walrs.log" 2>&1
got="$(python3 - "$DEST/stats.db" <<'PYRD2'
import sqlite3, sys
try:
    c = sqlite3.connect(sys.argv[1])
    n = c.execute("SELECT count(*) FROM t").fetchone()[0]
    v = c.execute("SELECT v FROM t LIMIT 1").fetchone()[0]
    print("%s %s" % (n, v))
except Exception as e:
    print("ОШИБКА: %s" % e)
PYRD2
)"
case "$got" in
    "200 изархива"*) ok "после восстановления читается архивная база ($got)" ;;
    *прежний*) bad "читается база ПРЕЖНЕЙ установки: $got" \
                   "осиротевший -wal проигран поверх восстановленного файла" ;;
    *) bad "неожиданное состояние базы: $got" ;;
esac
[ -f "$DEST/stats.db-wal" ] && bad "осиротевший -wal остался на месте" \
    || ok "и журналы прежней базы убраны"


# ═══════════════════════════════════════════════════════════════════════════
head_ "11. Адрес новой машины не отменяется адресом из архива"
# Порядок «сначала install.sh, потом restore» предписан README, то есть свежий
# адрес всегда записывается ПЕРЕД восстановлением. Раньше архив молча возвращал
# адрес прежней машины, и на мёртвый адрес уезжали не только восстановленные
# конфиги, но и все НОВЫЕ: awg-client берёт хост только отсюда.
ep_now() { sed -n "s/^ENDPOINT=//p" "$AWG/services.env" | tr -d "'\"" | head -1; }
arch_ep="$(ep_now)"
sed -i "s|^ENDPOINT=.*|ENDPOINT='new.example.org'|" "$AWG/services.env"
bash "$BK" restore "$W/bk.tar.gz" >"$W/ep1.log" 2>&1
got="$(ep_now)"
[ "$got" = new.example.org ] \
    && ok "адрес этой машины сохранён ($got), а не заменён архивным ($arch_ep)" \
    || bad "адрес заменён архивным: $got" "все НОВЫЕ клиенты уедут на мёртвый адрес"
grep -q "в архиве был $arch_ep" "$W/ep1.log" \
    && ok "и сказано, какой адрес был в архиве" \
    || bad "про архивный адрес не сказано" "$(tail -3 "$W/ep1.log")"
grep -q -- "--reconfigure --host $arch_ep" "$W/ep1.log" \
    && ok "и напечатана команда, если переезда не было" \
    || bad "нет команды возврата" "владельцу неоткуда узнать, что делать"
grep -q "раздать заново" "$W/ep1.log" \
    && ok "и сказано, что восстановленные конфиги надо раздать заново" \
    || bad "про выданные конфиги не сказано" "они указывают на архивный адрес"

head_ "12. Откат на той же машине — про адрес ни слова"
# Подавляющее большинство восстановлений именно такие, и лишняя строка тут
# приучила бы пролистывать вывод мимо той, что появится при настоящем переезде.
sed -i "s|^ENDPOINT=.*|ENDPOINT='$arch_ep'|" "$AWG/services.env"
bash "$BK" restore "$W/bk.tar.gz" >"$W/ep2.log" 2>&1
grep -q "адрес сервера оставлен" "$W/ep2.log" \
    && bad "разговор про адрес там, где он не менялся" "$(grep 'адрес' "$W/ep2.log" | head -2)" \
    || ok "ни одной лишней строки"
[ "$(ep_now)" = "$arch_ep" ] && ok "и адрес на месте" || bad "адрес испорчен: $(ep_now)"

# ═══════════════════════════════════════════════════════════════════════════
head_ "13. Вторая копия адреса — в install-state.env"
# services.env чинится разделом 11, но тот же адрес лежит в архиве ещё раз, и
# установщик читает ИМЕННО ЕГО первым (endpoint_final). Пока эта копия архивная,
# любое следующее обновление возвращает адрес мёртвой машины, отменяя починку.
st_ep() { sed -n "s/^AWG_ENDPOINT=//p" "$DEST/install-state.env" | tr -d "'\"" | head -1; }
sed -i "s|^ENDPOINT=.*|ENDPOINT='third.example.org'|" "$AWG/services.env"
bash "$BK" restore "$W/bk.tar.gz" >"$W/ep3.log" 2>&1
[ "$(st_ep)" = third.example.org ] \
    && ok "в state адрес этой машины ($(st_ep))" \
    || bad "в state архивный адрес: $(st_ep)" "следующий install.sh вернёт его в services.env"
[ "$(ep_now)" = third.example.org ] \
    && ok "и services.env с ним согласен" \
    || bad "копии разошлись: services.env=$(ep_now), state=$(st_ep)"
grep -q "AWG_BOT_TOKEN" "$DEST/install-state.env" \
    && ok "остальные ответы владельца в state не тронуты" \
    || bad "правка адреса снесла соседние ключи" "$(cat "$DEST/install-state.env")"

# ═══════════════════════════════════════════════════════════════════════════
head_ "14. Токен бота не откатывается вместе с архивом"
# install-state.env приезжает из архива целиком, а живой bot.env в архив не
# попадает. Само по себе расхождение молчит, но следующий обычный прогон
# install.sh сорсит state и переписывает им bot.env: отозванный токен убьёт
# бота, а удалённый ранее chat_id вернёт человеку доступ к кнопке «Бэкап»,
# которая отдаёт в чат архив со всеми приватными ключами клиентов.
printf 'AWG_BOT_TOKEN=ЖИВОЙ-ТОКЕН\nAWG_BOT_ADMINS=111\n' > "$DEST/bot.env"
bash "$BK" restore "$W/bk.tar.gz" >"$W/bot.log" 2>&1
st_tok="$(sed -n "s/^AWG_BOT_TOKEN=//p" "$DEST/install-state.env" | tr -d "'\"" | head -1)"
[ "$st_tok" = "ЖИВОЙ-ТОКЕН" ] \
    && ok "в state остался токен работающего бота" \
    || bad "в state архивный токен «$st_tok»" \
           "следующий install.sh перепишет им bot.env и убьёт бота"
st_adm="$(sed -n "s/^AWG_BOT_ADMINS=//p" "$DEST/install-state.env" | tr -d "'\"" | head -1)"
[ "$st_adm" = "111" ] \
    && ok "и список админов тоже" \
    || bad "в state архивный список админов «$st_adm»" \
           "удалённый ранее chat_id вернёт себе доступ к меню и к бэкапу"
grep -q "AWG_BOT_TOKEN" "$W/bot.log" \
    && ok "и об этом сказано вслух" \
    || bad "подмена сделана молча" "владелец не узнает, что архив расходился с живым ботом"

# Обратная сторона: если бота на машине нет, спорить не с чем — архивное
# значение обязано доехать, иначе переезд на новый сервер терял бы токен.
rm -f "$DEST/bot.env"
bash "$BK" restore "$W/bk.tar.gz" >"$W/bot2.log" 2>&1
st_tok="$(sed -n "s/^AWG_BOT_TOKEN=//p" "$DEST/install-state.env" | tr -d "'\"" | head -1)"
[ "$st_tok" = "x" ] \
    && ok "без bot.env архивный токен доезжает" \
    || bad "архивный токен потерян: «$st_tok»" "переезд на новую машину лишится бота"

# ═══════════════════════════════════════════════════════════════════════════
head_ "15. Архив без stats.db не убивает живую базу"
# Архив без базы — штатный путь: при отказе снимка do_backup говорит об этом и
# намеренно не роняет код. Безусловный `rm -f stats.db-wal` в этом случае сносит
# журналы ЖИВОЙ базы, а сам stats.db — четырёхкилобайтный заголовок: вся схема
# живёт в -wal. Дальше sqlite отвечает «no such table» на всё, то есть операция,
# запущенная ради спасения данных, уничтожает их целиком.
rm -f "$DEST/stats.db" "$DEST/stats.db-wal" "$DEST/stats.db-shm"
bash "$BK" backup "$W/nodb.tar.gz" >"$W/nodb.log" 2>&1
if tar -tzf "$W/nodb.tar.gz" 2>/dev/null | grep -q 'state/stats.db$'; then
    bad "в архиве есть stats.db" "стенд не воспроизвёл нужный случай"
else
    ok "архив снят без базы — как при отказе снимка"
    python3 - "$DEST/stats.db" <<'PYLIVE'
import sqlite3, sys, os
c = sqlite3.connect(sys.argv[1])
c.execute("PRAGMA journal_mode=WAL")
c.execute("CREATE TABLE t(k INTEGER PRIMARY KEY, v TEXT)")
for i in range(300):
    c.execute("INSERT INTO t(v) VALUES (?)", ("живой%d" % i,))
c.commit()
os._exit(0)
PYLIVE
    wal="$(stat -c%s "$DEST/stats.db-wal" 2>/dev/null || echo 0)"
    [ "$wal" != 0 ] && ok "стенд воспроизвёл живую базу: -wal $wal байт" \
        || bad "не удалось получить непустой -wal" "мерить нечего"
    bash "$BK" restore "$W/nodb.tar.gz" >"$W/nodbrs.log" 2>&1
    got="$(python3 - "$DEST/stats.db" <<'PYRD'
import sqlite3, sys
try:
    print(sqlite3.connect(sys.argv[1]).execute("select count(*) from t").fetchone()[0])
except Exception as e:
    print("ОШИБКА: %s" % e)
PYRD
)"
    [ "$got" = 300 ] \
        && ok "живая база пережила восстановление ($got записей)" \
        || bad "живая база уничтожена: $got" \
               "восстановление снесло журналы, в которых была вся схема"
fi

printf '\n'
[ "$fail" = 0 ] && echo "═══ ВСЁ ЗЕЛЁНОЕ ═══" || echo "═══ ЕСТЬ ПАДЕНИЯ ═══"
exit $fail
INNER
rc=$?
[ "$rc" = 0 ] || fail=1
exit $fail
