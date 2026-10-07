#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Порт: его спрашивают при установке и его можно сменить потом.
#
# До этих правок порт выбирался молча случайным, а сменить его было нельзя
# нигде. Беда не в неудобстве: порт — ровно то, что блокируют, и владелец
# оставался с номером, который узнал уже после установки.
#
# Сменить порт руками тоже не выход. Он живёт в четырёх местах — services.env,
# <iface>.env, ListenPort серверного конфига и Endpoint КАЖДОГО выданного
# клиента, — а regen-all Endpoint не правит вовсе. Правка «только сервера»
# оставляет все выданные конфиги указывать на прежний порт: клиенты молча
# перестают соединяться, и это неотличимо от блокировки UDP.
#
# Отсюда два свойства, которые здесь и меряются:
#
#   диалог    — пустой ответ сохраняет прежнее поведение (случайный свободный),
#               введённое значение проверяется, чужой порт отвергается;
#   порядок   — сначала сервер, потом клиенты. Если перезапуск не удался,
#               клиентские конфиги обязаны остаться НЕТРОНУТЫМИ: иначе у
#               клиентов новый порт там, где сервер слушает старый, и никакая
#               проверка этого от блокировки не отличит. Обратная половина —
#               повтор команды дочищает отставшие конфиги.
#
#   bash tests/test_port_change.sh

fail=0
ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
cd "$ROOT" || exit 1

ok()  { printf '  ✔ %s\n' "$1"; }
bad() { printf '  ✘ %s\n' "$1"; [ $# -gt 1 ] && printf '     %s\n' "$2"; fail=1; }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ════════════════════════════════════════════════════════════════════════════
# ЧАСТЬ ПЕРВАЯ: диалог установщика
# ════════════════════════════════════════════════════════════════════════════
# Настоящего tty в тесте нет, поэтому обращения к нему разворачиваем на
# stdin/stderr — тем же приёмом, что в test_install_askyn.sh.
ASKP="$(sed -n '/^ask_port()/,/^}$/p' install.sh \
        | sed -e 's#has_tty || return 0##' \
              -e 's#< /dev/tty##g' \
              -e 's#> /dev/tty#>\&2#g')"

askport() {  # askport <ввод> <исключить> → выбранное значение
    printf '%s\n' "$1" | ( set -uo pipefail
        valid_port() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }
        port_busy() { return 1; }
        ask_yn() { return 1; }
        eval "$ASKP"
        ask_port ANS "слоя 3.0" "${2:-}" 2>/dev/null
        printf '%s' "$ANS" )
}

head_ "0. Диалог найден в настоящем установщике"
if [ -z "$ASKP" ]; then
    bad "не нашли ask_port в install.sh" "портов по-прежнему не спрашивают — прерываю"
    printf '\n'; exit 1
fi
ok "ask_port вырезан из install.sh"

head_ "1. Пустой ответ оставляет прежнее поведение"
OUT="$(askport "" "")"
[ -z "$OUT" ] && ok "Enter → пусто, то есть случайный свободный порт" \
    || bad "Enter дал значение «$OUT»" "случайный выбор перестал быть умолчанием"

head_ "2. Введённый порт принимается"
OUT="$(askport "41820" "")"
[ "$OUT" = 41820 ] && ok "41820 принят" || bad "введённый порт потерян" "получено «$OUT»"

head_ "3. Мусор не принимается, вопрос повторяется"
OUT="$(askport "абв
70000
41821" "")"
[ "$OUT" = 41821 ] && ok "нечисло и 70000 отвергнуты, принят 41821" \
    || bad "проверка ввода не работает" "получено «$OUT»"

head_ "4. Порт другого слоя отвергается"
OUT="$(askport "41820
41822" "41820")"
[ "$OUT" = 41822 ] && ok "совпадение с другим слоем отвергнуто" \
    || bad "один порт достался бы двум слоям" "получено «$OUT»"

head_ "4б. Ответ диалога доезжает до портов, а не повисает в воздухе"
# Разделы выше проверяют саму функцию. Этого мало: если вызов ask_port из
# plan_services убрать, они останутся зелёными, а порты снова станут молча
# случайными. Поэтому гоняем настоящий plan_services и смотрим, что в PORT2 и
# PORT3 легло именно то, что «ответил человек».
PLANF="$(sed -n '/^plan_services()/,/^}$/p' install.sh)"
wire() {  # wire <AWG_VER> <ответ 2.0> <ответ 3.0> → "PORT2 PORT3"
    # shellcheck disable=SC2034  # переменные ниже читает вырезанный plan_services
    ( set -uo pipefail
      PLAN=0; CLI_PORTS=""; CLI_MTU=""; CLI_DNS=""
      AWG_VER="$1"; A2="$2"; A3="$3"
      SERVICES=/dev/null
      installed() { return 1; }
      has_tty() { return 0; }
      log() { :; }
      err() { :; }
      pick_random_port() { echo РАНДОМ; }
      # Подставной диалог: отвечает заранее заданным, как будто это ввод.
      ask_port() { if [ "$2" = "слоя 2.0" ]; then printf -v "$1" '%s' "$A2"
                   else printf -v "$1" '%s' "$A3"; fi; }
      eval "$PLANF"
      plan_services >/dev/null 2>&1 || true
      printf '%s %s' "${PORT2:-?}" "${PORT3:-?}" )
}
if [ -z "$PLANF" ]; then
    bad "не нашли plan_services в install.sh" "проводку мерить нечем"
else
    OUT="$(wire both 41001 41002)"
    [ "$OUT" = "41001 41002" ] && ok "оба ответа легли в PORT2 и PORT3" \
        || bad "ответы диалога потеряны" "получено «$OUT», ждали «41001 41002»"
    OUT="$(wire both "" 41003)"
    case "$OUT" in
        "РАНДОМ 41003") ok "пустой ответ на один слой оставляет ему случайный порт" ;;
        *) bad "пустой ответ сломал выбор" "получено «$OUT»" ;;
    esac
    # Слой, который не ставят, спрашивать незачем — но порт ему всё равно
    # считается, иначе write_services положит в services.env пустое значение.
    OUT="$(wire 3 НЕСПРОШЕНО 41004)"
    case "$OUT" in
        "РАНДОМ 41004") ok "при --awg 3 спрашивают только про слой 3.0" ;;
        *) bad "спросили не про тот слой" "получено «$OUT»" ;;
    esac
fi

# ════════════════════════════════════════════════════════════════════════════
# ЧАСТЬ ВТОРАЯ: смена порта
# ════════════════════════════════════════════════════════════════════════════
D="$WORK/stand"
BIN="$D/bin"; STUB="$D/stub"
mkdir -p "$BIN" "$STUB"

cp bin/awg-port.sh "$BIN/"
sed -i "s#^AWG_DIR=/etc/amnezia/amneziawg\$#AWG_DIR=$D/etc#" "$BIN/awg-port.sh"
sed -i "s#^DEST=/opt/awg3\$#DEST=$D/opt#" "$BIN/awg-port.sh"

head_ "5. Стенд подменил пути, а не сделал вид"
miss=""
grep -q "^AWG_DIR=$D/etc\$" "$BIN/awg-port.sh" || miss="$miss AWG_DIR"
grep -q "^DEST=$D/opt\$" "$BIN/awg-port.sh"    || miss="$miss DEST"
if [ -n "$miss" ]; then
    bad "не подменены:$miss" "набор пошёл бы по боевым путям — прерываю"
    printf '\n'; exit 1
fi
ok "оба пути ведут в каталог стенда"

# ── подставные ss и systemctl ───────────────────────────────────────────────
# «Слушается» хранится в файле: так systemctl restart может его изменить, и
# проверка «порт слушается после перезапуска» меряет настоящую связь между
# перезапуском и ядром, а не сама себя.
cat > "$STUB/ss" <<'SSEOF'
#!/bin/bash
while read -r p; do printf '  UNCONN 0 0 0.0.0.0:%s 0.0.0.0:*\n' "$p"; done < "${STUB_LISTEN:?}"
SSEOF
chmod +x "$STUB/ss"
cat > "$STUB/systemctl" <<'SCEOF'
#!/bin/bash
case "${1:-}" in
    cat)     [ "${STUB_UNIT_PRESENT:-1}" = 1 ] && exit 0 || exit 1 ;;
    restart) [ "${STUB_RESTART_OK:-1}" = 1 ] || exit 1
             # «перезапустился» — значит слушает то, что в конфиге
             sed -n 's/^ListenPort *= *//p' "${STUB_CONF:?}" | head -1 > "${STUB_LISTEN:?}"
             exit 0 ;;
esac
exit 0
SCEOF
chmod +x "$STUB/systemctl"

mk_stand() {  # mk_stand <порт 3.0> <порт 2.0>
    local p3="$1" p2="$2"
    rm -rf "${D:?}/etc" "${D:?}/opt"
    mkdir -p "$D/etc" "$D/opt/clients/awg3"
    cat > "$D/etc/services.env" <<EOF
LAYER2='1'
LAYER3='1'
IFACE2='awg2'
IFACE3='awg3'
SUBNET2='10.29.79'
SUBNET3='10.29.80'
PORT2='$p2'
PORT3='$p3'
MTU2='1420'
MTU3='1380'
EOF
    printf '[Interface]\nPrivateKey = KEY\nAddress = 10.29.80.1/24\nListenPort = %s\nMTU = 1380\n' \
        "$p3" > "$D/etc/awg3.conf"
    printf 'SUBNET=10.29.80.0/24\nPORT=%s\nNAT=1\nMTU=1380\nWAN=eth0\n' "$p3" > "$D/etc/awg3.env"
    local n
    for n in alice bob; do
        printf '[Interface]\nPrivateKey = K-%s\nAddress = 10.29.80.%s/32\n\n[Peer]\nPublicKey = SRV\nEndpoint = vpn.example.com:%s\nAllowedIPs = 0.0.0.0/0\n' \
            "$n" "2" "$p3" > "$D/opt/clients/awg3/awg3-$n-am.conf"
    done
    # Подставной экспортёр: отмечает, что его позвали, и кладёт QR рядом.
    cat > "$D/opt/awg-export.py" <<'EXEOF'
import sys, os
conf = sys.argv[1]
name, outdir = "", "."
for i, a in enumerate(sys.argv):
    if a == "--name": name = sys.argv[i + 1]
    if a == "--outdir": outdir = sys.argv[i + 1]
open(os.path.join(outdir, name + ".png"), "w").write("png")
open(os.path.join(outdir, name + ".vpn"), "w").write("vpn://x")
open(os.path.join(os.path.dirname(conf), ".export-calls"), "a").write(name + "\n")
EXEOF
    printf '%s\n' "$p3" > "$D/listen"
}

awgport() {  # awgport <аргументы> → вывод; код возврата свой
    PATH="$STUB:$PATH" \
    STUB_LISTEN="$D/listen" STUB_CONF="$D/etc/awg3.conf" \
    STUB_RESTART_OK="${RESTART_OK:-1}" STUB_UNIT_PRESENT=1 \
    AWG_LOCK="$D/lock" \
        bash "$BIN/awg-port.sh" "$@" 2>&1
}
ep_of() { sed -n 's/^Endpoint *= *//p' "$D/opt/clients/awg3/awg3-$1-am.conf" | head -1; }

# ═══════════════════════════════════════════════════════════════════════════
head_ "6. Смена порта меняет все четыре места и сохраняет хост"
mk_stand 25936 36196
OUT="$(awgport set awg3 41999)"; rc=$?
[ "$rc" = 0 ] && ok "команда отработала" || bad "команда вернула $rc" "$OUT"
grep -q "^PORT3='41999'\$" "$D/etc/services.env" && ok "services.env: PORT3" \
    || bad "services.env не изменён" "$(grep PORT3 "$D/etc/services.env")"
grep -q '^PORT=41999$' "$D/etc/awg3.env" && ok "awg3.env: PORT" \
    || bad "<iface>.env не изменён" "$(grep '^PORT=' "$D/etc/awg3.env")"
grep -q '^ListenPort = 41999$' "$D/etc/awg3.conf" && ok "серверный конфиг: ListenPort" \
    || bad "ListenPort не изменён" "$(grep ListenPort "$D/etc/awg3.conf")"
[ "$(ep_of alice)" = "vpn.example.com:41999" ] && ok "Endpoint у alice переписан, домен сохранён" \
    || bad "Endpoint неверен" "получено «$(ep_of alice)»"
[ "$(ep_of bob)" = "vpn.example.com:41999" ] && ok "и у bob тоже" || bad "bob отстал" "«$(ep_of bob)»"
grep -q '^PORT2=.36196.$' "$D/etc/services.env" && ok "порт другого слоя не тронут" \
    || bad "задет порт слоя 2.0" "$(grep PORT2 "$D/etc/services.env")"
[ -f "$D/opt/clients/awg3/awg3-alice.png" ] && ok "QR и vpn:// пересобраны" \
    || bad "QR не пересобран" "человек получил бы картинку со старым портом"
case "$OUT" in
    *"заново скачать"*) ok "и сказано, что клиентам нужен переимпорт" ;;
    *) bad "про переимпорт не сказано" "$OUT" ;;
esac

# ═══════════════════════════════════════════════════════════════════════════
head_ "7. Перезапуск не удался — клиентские конфиги НЕ тронуты"
# Это и есть смысл порядка «сначала сервер». При обратном клиенты уехали бы на
# порт, которого сервер не слушает, — и отличить это от блокировки нечем.
mk_stand 25936 36196
# Присваивание ТОЛЬКО внутри подстановки: `VAR=0 OUT=...` — это два
# присваивания текущей оболочке, и RESTART_OK дотянулась бы до следующих
# разделов, где перезапуск обязан удаваться.
OUT="$(RESTART_OK=0 awgport set awg3 42001)"; rc=$?
[ "$rc" != 0 ] && ok "команда завершилась отказом (код $rc)" \
    || bad "отчиталась об успехе при упавшем перезапуске" "$OUT"
[ "$(ep_of alice)" = "vpn.example.com:25936" ] && ok "Endpoint остался прежним" \
    || bad "клиентские конфиги переписаны при неудаче" "«$(ep_of alice)» — сервер слушает другое"
case "$OUT" in
    *"повтори эту же команду"*) ok "и сказано, как починить" ;;
    *) bad "совета нет" "$OUT" ;;
esac

# ═══════════════════════════════════════════════════════════════════════════
head_ "8. Повтор дочищает отставший конфиг"
# Идемпотентность — вторая половина того же решения: оборванную смену лечит
# повтор, а не разбор руками.
mk_stand 25936 36196
awgport set awg3 42002 >/dev/null
# роняем один конфиг назад, как будто его не успели переписать
sed -i 's/^Endpoint = .*/Endpoint = vpn.example.com:25936/' "$D/opt/clients/awg3/awg3-bob-am.conf"
OUT="$(awgport set awg3 42002)"; rc=$?
[ "$rc" = 0 ] && ok "повтор с тем же портом не отказ" || bad "повтор вернул $rc" "$OUT"
[ "$(ep_of bob)" = "vpn.example.com:42002" ] && ok "отставший конфиг дочищен" \
    || bad "повтор не исправил отставший конфиг" "«$(ep_of bob)»"

# ═══════════════════════════════════════════════════════════════════════════
head_ "9. Занятый и чужой порт"
mk_stand 25936 36196
printf '25936\n50505\n' > "$D/listen"
OUT="$(awgport set awg3 50505)"; rc=$?
[ "$rc" != 0 ] && ok "занятый порт без --force отвергнут" || bad "занятый порт принят" "$OUT"
OUT="$(awgport set awg3 50505 --force)"; rc=$?
[ "$rc" = 0 ] && ok "и принят с --force" || bad "--force не помог" "$OUT"

mk_stand 25936 36196
OUT="$(awgport set awg3 36196)"; rc=$?
[ "$rc" != 0 ] && ok "порт слоя 2.0 отвергнут" || bad "один порт достался двум слоям" "$OUT"

# ═══════════════════════════════════════════════════════════════════════════
head_ "10. Шаблон не совпал — громкий отказ, а не тихий успех"
# Правка, не нашедшая строки, оставила бы файл прежним. Ровно так порт и
# разъезжался с Endpoint в прошлый раз, поэтому результат сверяется всегда.
mk_stand 25936 36196
grep -v '^ListenPort' "$D/etc/awg3.conf" > "$D/etc/awg3.conf.x" && mv "$D/etc/awg3.conf.x" "$D/etc/awg3.conf"
OUT="$(awgport set awg3 42003)"; rc=$?
[ "$rc" != 0 ] && ok "отказ (код $rc)" || bad "конфиг без ListenPort принят за переписанный" "$OUT"
case "$OUT" in
    *"не изменилось"*) ok "и названо, что именно не изменилось" ;;
    *) bad "молчание вместо объяснения" "$OUT" ;;
esac

# ═══════════════════════════════════════════════════════════════════════════
head_ "11. show ничего не меняет"
mk_stand 25936 36196
BEFORE="$(md5sum "$D/etc/services.env" "$D/etc/awg3.conf" | md5sum)"
OUT="$(awgport show)"; rc=$?
[ "$rc" = 0 ] && ok "show отработал" || bad "show вернул $rc" "$OUT"
[ "$BEFORE" = "$(md5sum "$D/etc/services.env" "$D/etc/awg3.conf" | md5sum)" ] \
    && ok "и файлы не тронул" || bad "show изменил файлы"
case "$OUT" in
    *25936*) ok "и назвал текущий порт" ;;
    *) bad "порт не показан" "$OUT" ;;
esac

printf '\n'
[ "$fail" = 0 ] && echo "═══ ВСЁ ЗЕЛЁНОЕ ═══" || echo "═══ ЕСТЬ ПАДЕНИЯ ═══"
exit $fail
