#!/bin/bash
# Приёмка: доктор awg3 судит о слое 3.0 по ПРОФИЛЮ, а не по имени пресета,
# не пугает там, где параметров нет по замыслу, и отличает «ключа нет» от
# «спросить не удалось».
#
# Почему источник истины именно профиль. Имя пресета — ярлык в obfuscation3.meta,
# а клиентские конфиги выписываются по obfuscation3.env. Пока доктор смотрел на
# ярлык, самый разрушительный исход был зелёным: понижение medium → router
# оставляло прежний <iface>.v3 (apply_to_server не удалял его при пустом
# профиле), датапас применял старый header_protection_key, сервер продолжал
# ждать защиту заголовка, клиентские конфиги уже выданы без неё — и доктор
# писал «header protection применена (пресет router)». Не подключался никто.
DOC="${1:?awg-doctor.sh}"
fail=0
chk(){ if [ "$2" = "$3" ]; then echo "  ✔ $1"; else echo "  ✘ $1 — ждали [$3], получили [$2]"; fail=1; fi; }

# Блок кончается вызовом check_v3_stale — именованный конец надёжнее счёта
# закрывающих fi: их число меняется от любой правки внутри.
blk="$(awk '/^    v3_preset=/{on=1} /^    check_v3_stale /{exit} on{print}' "$DOC")"
miss=""
for m in hp3 v3_preset hpk_want; do
    printf '%s' "$blk" | grep -q "$m" || miss="$miss $m"
done
if [ -n "$miss" ]; then
    echo "  ✘ блок проверки 3.0 вырезан не целиком — нет:$miss"; exit 1
fi

# run <профиль> <пресет в meta> <режим UAPI>
#   профиль: hpk    — obfuscation3.env объявляет AWG_HPK_HEX
#            nohpk  — файл есть, ключа в нём нет (так объявлены router и low)
#            none   — файла нет вовсе
#   UAPI:    key    — демон отдал ключ
#            nokey  — демон ответил, но параметров нет
#            dead   — демон не ответил (пустой вывод)
#            nofile — самого awg-uapi.py нет
run() {
    local d; d="$(mktemp -d)"
    mkdir -p "$d/etc" "$d/dest"
    [ -n "$2" ] && printf 'META_PRESET=%s\nMETA_TEMPLATE=web\n' "$2" > "$d/etc/obfuscation3.meta"
    case "$1" in
        hpk)   printf "AWG_HPK_HEX='deadbeef'\n" > "$d/etc/obfuscation3.env" ;;
        nohpk) printf "AWG_Jc='4'\n"             > "$d/etc/obfuscation3.env" ;;
        none)  : ;;
    esac
    case "$3" in
        key)   printf 'print("awg3: активные параметры AmneziaWG 3.0")\nprint("  header_protection_key = abcd(скрыт)")\n' > "$d/dest/awg-uapi.py" ;;
        nokey) printf 'print("awg3: параметры AmneziaWG 3.0 не заданы (работает как 2.0)")\n' > "$d/dest/awg-uapi.py" ;;
        dead)  printf 'import sys\nsys.exit(1)\n' > "$d/dest/awg-uapi.py" ;;
        nofile) : ;;
    esac
    # переменные ниже читает вырезанный из скрипта блок под eval,
    # статически такую связь не увидеть
    # shellcheck disable=SC2034
    ( set -uo pipefail
      AWG_DIR="$d/etc"; DEST="$d/dest"; KMOD3=0; IFACE3=awg3
      # Склейка та же, что в настоящих ok/warn/bad: второй аргумент —
      # объяснение, и приклеивается он через тире, а не пробелом.
      _j(){ local m="$2"; [ $# -gt 2 ] && m="$2 — $3"; echo "$1|$m"; }
      ok(){   _j ok   "$@"; }
      warn(){ _j warn "$@"; }
      bad(){  _j bad  "$@"; }
      eval "$blk" ) 2>/dev/null
    rm -rf "$d"
}

echo "── Профиль объявляет ключ и демон его применил ─────────────────────────"
chk "medium" "$(run hpk medium key)" "ok|header protection применена (пресет medium)"
chk "high"   "$(run hpk high key)"   "ok|header protection применена (пресет high)"

echo
echo "── Профиль ключа не объявляет, и на интерфейсе его нет: НЕ поломка ─────"
chk "router" "$(run nohpk router nokey)" \
    "ok|профиль router — без header protection, так и задумано"
chk "low"    "$(run nohpk low nokey)" \
    "ok|профиль low — без header protection, так и задумано"
echo "  (именно на этом доктор когда-то писал «параметры 3.0 не применены»)"

echo
echo "── Ключ на интерфейсе есть, а профиль его НЕ объявляет ─────────────────"
echo "   (застрявший .v3 от прежнего профиля — не подключается никто)"
o="$(run nohpk router key)"
chk "router с чужим ключом" "$o" \
    "bad|на интерфейсе есть header protection, а профиль router её не объявляет — клиенты выданы без неё и не подключатся: примени профиль заново — awg-obfuscation --v3 --apply"
case "$o" in ok\|*) echo "  ✘ самый разрушительный исход показан зелёным"; fail=1 ;;
             *) echo "  ✔ зелёным это больше не показывается" ;; esac

echo
echo "── Профиль ключ объявляет, а на интерфейсе его нет ─────────────────────"
chk "medium" "$(run hpk medium nokey)" \
    "warn|профиль medium объявляет header protection, но на интерфейсе её нет — починить: awg-obfuscation --v3 --regenerate --apply"
chk "нет obfuscation3.meta" "$(run hpk '' nokey)" \
    "warn|профиль ? объявляет header protection, но на интерфейсе её нет — починить: awg-obfuscation --v3 --regenerate --apply"

echo
echo "── Профиля нет вовсе — обвинять нечем ──────────────────────────────────"
chk "нет obfuscation3.env" "$(run none medium nokey)" \
    "ok|профиль medium — без header protection, так и задумано"

echo
echo "── «Спросить не удалось» ≠ «ключа нет» ─────────────────────────────────"
o="$(run hpk medium dead)"
chk "демон молчит — так и сказано" "$(printf '%s' "$o" | head -1)" \
    "warn|awg3: демон не ответил — состояние 3.0 неизвестно — смотри: journalctl -u awg3@awg3 -n 30 --no-pager"
case "$o" in *"объявляет header protection"*) echo "  ✘ подмешан чужой диагноз"; fail=1 ;;
             *) echo "  ✔ профиль тут ни при чём — про него молчим" ;; esac
o="$(run hpk medium nofile)"
case "$o" in *"нечем спросить демона"*) echo "  ✔ нет awg-uapi.py — сказано прямо" ;;
             *) echo "  ✘ пропажа awg-uapi.py не названа: [$o]"; fail=1 ;; esac
case "$o" in *"объявляет header protection"*) echo "  ✘ и снова чужой диагноз"; fail=1 ;;
             *) echo "  ✔ и без обвинения профиля" ;; esac
echo "  (раньше обе ситуации давали «параметры 3.0 не применены»)"

echo
[ "$fail" = 0 ] && echo "ВСЁ ЗЕЛЁНОЕ" || echo "ЕСТЬ ПАДЕНИЯ"
exit $fail
