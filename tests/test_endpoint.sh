#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Адрес сервера: где его сверять можно, а где проверка обязана молчать.
#
# Три измерения разной доказуемости, и мешать их нельзя:
#
#   M1  в Endpoint вообще есть разбираемый хост — доказывается ОДНИМ файлом,
#       ложных срабатываний нет вовсе, поэтому bad;
#   M2  хост у клиентов совпадает с объявленным — доказывается ДВУМЯ файлами
#       на диске, законные расхождения бывают (после --reconfigure --host), и
#       причина неизвестна, поэтому warn;
#   M3  объявленный адрес совпадает с настоящим внешним адресом машины —
#       за NAT недоказуемо В ПРИНЦИПЕ, поэтому там проверка молчит.
#
# Главное, что здесь меряется: доктор НЕ ворчит на исправном сервере. Жёлтая
# строка, которая горит всегда, перестаёт читаться вместе с той, что появится
# при настоящем переезде.
#
#   bash tests/test_endpoint.sh
fail=0
ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
cd "$ROOT" || exit 1

ok()  { printf '  ✔ %s\n' "$1"; }
bad() { printf '  ✘ %s\n' "$1"; [ $# -gt 1 ] && printf '     %s\n' "$2"; fail=1; }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

DOC=bin/awg-doctor.sh
HOSTFN="$(sed -n '/^ep_host()/,/^}$/p;/^norm_host()/p;/^check_client_hosts()/,/^}$/p' "$DOC")"
EPFN="$(sed -n '/^check_endpoint()/,/^}$/p' "$DOC")"
[ -n "$HOSTFN" ] || { bad "не нашли check_client_hosts в $DOC" "мерить нечего"; echo; exit 1; }
[ -n "$EPFN" ]   || { bad "не нашли check_endpoint в $DOC" "мерить нечего"; echo; exit 1; }

# ── стенд для M1/M2: каталог клиентов с заданными Endpoint ─────────────────
mk() {  # mk <каталог> <хост1> [хост2 …] — по конфигу на хост
    local d="$1"; shift
    rm -rf "$d"; mkdir -p "$d"
    local i=0 h
    for h in "$@"; do
        i=$((i + 1))
        printf '[Interface]\nPrivateKey = K%s\n\n[Peer]\nEndpoint = %s\n' "$i" "$h" \
            > "$d/awg2-c$i-am.conf"
    done
}

hosts() {  # hosts <объявленный> <каталог> → вывод проверки
    ( ok()   { printf 'OK %s\n' "$*"; }
      bad()  { printf 'BAD %s\n' "$*"; }
      warn() { printf 'WARN %s\n' "$*"; }
      eval "$HOSTFN"
      check_client_hosts "$1" "$2" awg2 )
}

# ═══════════════════════════════════════════════════════════════════════════
head_ "1. Все конфиги на объявленном адресе — ни одной жалобы"
mk "$WORK/a" vpn.example.org:51820 vpn.example.org:51820 vpn.example.org:51820
out="$(hosts vpn.example.org "$WORK/a")"
case "$out" in
    *BAD*|*WARN*) bad "исправное состояние названо расхождением" "$out" ;;
    *) ok "проверка молчит по существу" ;;
esac
case "$out" in
    *"у всех 3 конфигов Endpoint на vpn.example.org"*) ok "и сказано, сколько проверено" ;;
    *) bad "число проверенных не названо" "$out" ;;
esac

# ═══════════════════════════════════════════════════════════════════════════
head_ "2. Часть конфигов выдана на другой адрес"
mk "$WORK/b" vpn.example.org:51820 1.2.3.4:51820 vpn.example.org:51820 1.2.3.4:51820
out="$(hosts vpn.example.org "$WORK/b")"
case "$out" in
    *"2 из 4 конфигов выданы на другой адрес"*) ok "посчитаны только несовпавшие" ;;
    *) bad "расхождение не посчитано" "$out" ;;
esac
case "$out" in *"1.2.3.4"*) ok "и показан образец" ;; *) bad "образец не показан" "$out" ;; esac
case "$out" in
    *"regen-all адрес не меняет"*) ok "и сказано, что regen-all тут не поможет" ;;
    *) bad "подсказка неверная или её нет" "regen-all правит только обфускацию" ;;
esac
case "$out" in
    *BAD*) bad "расхождение названо поломкой" \
               "после законного --reconfigure --host это норма, красное здесь не заслужено" ;;
    *) ok "это замечание, а не поломка" ;;
esac

# ═══════════════════════════════════════════════════════════════════════════
head_ "3. Endpoint без адреса — вот это поломка"
mk "$WORK/c" vpn.example.org:51820 :51820
out="$(hosts vpn.example.org "$WORK/c")"
case "$out" in
    *"BAD"*"нет адреса сервера"*) ok "конфиг без хоста назван поломкой" ;;
    *) bad "битый Endpoint пропущен" "$out" ;;
esac

# ═══════════════════════════════════════════════════════════════════════════
head_ "4. Объявленного адреса нет — сравнивать не с чем, и это не повод ворчать"
mk "$WORK/d" 1.2.3.4:51820 5.6.7.8:51820
out="$(hosts "" "$WORK/d")"
case "$out" in
    *WARN*|*BAD*) bad "жалоба при отсутствии объявленного адреса" "$out" ;;
    *) ok "проверка молчит" ;;
esac

# ═══════════════════════════════════════════════════════════════════════════
head_ "5. Регистр и завершающая точка FQDN — не расхождение"
mk "$WORK/e" VPN.Example.ORG:51820 vpn.example.org.:51820
out="$(hosts vpn.example.org "$WORK/e")"
case "$out" in
    *WARN*) bad "регистр или точка приняты за другой адрес" "$out" ;;
    *) ok "нормализация работает" ;;
esac

# ═══════════════════════════════════════════════════════════════════════════
head_ "6. Хост берётся до ПОСЛЕДНЕГО двоеточия, а не до первого"
mk "$WORK/f" '[2001:db8::1]:51820'
out="$(hosts '[2001:db8::1]' "$WORK/f")"
case "$out" in
    *WARN*|*BAD*) bad "адрес в скобках разобран неверно" "$out" ;;
    *) ok "IPv6 в скобках разбирается целиком" ;;
esac

# ═══════════════════════════════════════════════════════════════════════════
# M3: сверка с настоящим адресом машины. Здесь важно не что она находит, а
# где она МОЛЧИТ.
S="$WORK/stub"; mkdir -p "$S"
mkstub() {  # mkstub <src для ip route get> <A-записи через пробел> <адреса на интерфейсах>
    { echo '#!/bin/bash'
      echo 'case "$*" in'
      echo "  *\"route get\"*) [ -n \"$1\" ] && echo \"1.1.1.1 via 10.0.0.1 dev eth0 src $1\" ;;"
      echo "  *\"addr show\"*) for a in $3; do echo \"1: eth0    inet \$a/24 scope global eth0\"; done ;;"
      echo 'esac'
      echo 'exit 0'
    } > "$S/ip"
    { echo '#!/bin/bash'
      echo "for a in $2; do echo \"\$a STREAM \$2\"; done"
      echo "[ -z \"$2\" ] && exit 2"
      echo 'exit 0'
    } > "$S/getent"
    chmod +x "$S/ip" "$S/getent"
}
ep() {  # ep <ENDPOINT> → вывод проверки
    ( PATH="$S:$PATH"
      ok()   { printf 'OK %s\n' "$*"; }
      bad()  { printf 'BAD %s\n' "$*"; }
      warn() { printf 'WARN %s\n' "$*"; }
      # shellcheck disable=SC2034  # читает вырезанная из доктора функция
      ENDPOINT="$1"
      eval "$EPFN"
      check_endpoint )
}

head_ "7. Сервер за NAT: приватный src — сверять не с чем, значит молчим"
# Ровно тот случай, из-за которого доктора перестают читать: на облаках с
# приватным NIC (AWS, GCP, Oracle, CGNAT) домен НИКОГДА не равен src, и
# жёлтая строка горела бы на каждом запуске исправного сервера.
mkstub 10.0.0.5 "203.0.113.7" "10.0.0.5"
out="$(ep vpn.example.org)"
case "$out" in
    *WARN*|*BAD*) bad "ворчит на исправном сервере за NAT" "$out" ;;
    *) ok "ни одной жалобы" ;;
esac
case "$out" in
    *"за NAT"*) ok "и сказано, почему сверка не делалась" ;;
    *) bad "молчание без объяснения" "ok выглядит как пройденная проверка, которой не было" ;;
esac

head_ "8. Домен указывает на адрес этой машины"
mkstub 203.0.113.7 "203.0.113.7" "203.0.113.7"
out="$(ep vpn.example.org)"
case "$out" in
    *WARN*|*BAD*) bad "исправный домен назван расхождением" "$out" ;;
    *) ok "проверка довольна" ;;
esac

head_ "9. Несколько A-записей: совпала любая — этого достаточно"
# Порядок в ответе round-robin ротируется. Сверка с ПЕРВОЙ записью ходила бы
# между ok и warn от запуска к запуску на одном и том же исправном сервере.
mkstub 203.0.113.7 "198.51.100.9 203.0.113.7 192.0.2.1" "203.0.113.7"
out="$(ep vpn.example.org)"
case "$out" in
    *WARN*|*BAD*) bad "round-robin принят за расхождение" "$out" ;;
    *) ok "совпадения с любой записью хватает" ;;
esac

head_ "10. Домен указывает мимо — вот теперь замечание"
mkstub 203.0.113.7 "198.51.100.9" "203.0.113.7"
out="$(ep vpn.example.org)"
case "$out" in
    *WARN*) ok "сказано, что домен смотрит не сюда" ;;
    *) bad "настоящее расхождение пропущено" "$out" ;;
esac
case "$out" in
    *BAD*) bad "названо поломкой" "плавающий адрес выглядит так же — красное не заслужено" ;;
    *) ok "и это замечание, а не поломка" ;;
esac

head_ "11. Голый IP не сверяется с адресом машины — сознательно"
# За NAT и с плавающим адресом такая сверка — безусловная ложная тревога, а
# объявленное владельцем значение мы не оспариваем.
mkstub 10.0.0.5 "" ""
out="$(ep 203.0.113.7)"
case "$out" in
    *WARN*|*BAD*) bad "голый IP оспорен" "$out" ;;
    *) ok "объявленное значение принято как есть" ;;
esac


# ═══════════════════════════════════════════════════════════════════════════
head_ "12. Ответ владельца старше журнала: --reconfigure --host"
# `--reconfigure --host НОВЫЙ` молча не работал: resolve_endpoint ставила новый
# адрес, а следующая строка возвращала старый из install-state.env (на
# установленном сервере он непуст всегда). write_services писала старый, и
# «Готово. Адрес сервера:» печатало затёртое значение. Сухой прогон при этом
# смену ОБЕЩАЛ — план и прогон расходились.
EPF="$(sed -n '/^endpoint_final()/,/^}$/p' install.sh)"
if [ -z "$EPF" ]; then
    bad "не нашли endpoint_final в install.sh" "мерить нечего"
else
    epf() {  # epf <CLI_HOST> <RECONFIGURE> <AWG_ENDPOINT> <ENDPOINT>
        # shellcheck disable=SC2034  # читает вырезанная из install.sh функция
        ( CLI_HOST="$1" RECONFIGURE="$2" AWG_ENDPOINT="$3" ENDPOINT="$4"
          eval "$EPF"; endpoint_final )
    }
    got="$(epf new.example.org 1 old.example.org из-опроса)"
    [ "$got" = new.example.org ] \
        && ok "--reconfigure --host побеждает журнал ($got)" \
        || bad "--host отброшен, взят [$got]" "именно эта команда напечатана как лекарство при восстановлении"
    got="$(epf new.example.org 0 old.example.org из-опроса)"
    [ "$got" = old.example.org ] \
        && ok "без --reconfigure адрес не меняется — как и обещает план" \
        || bad "--host применён без --reconfigure ($got)" "план в этом случае пишет его в «проигнорировано»"
    got="$(epf "" 0 old.example.org из-опроса)"
    [ "$got" = old.example.org ] && ok "без --host берётся сохранённый" \
        || bad "сохранённый адрес потерян ($got)"
    got="$(epf "" 0 "" из-опроса)"
    [ "$got" = из-опроса ] && ok "на первой установке — ответ из опроса" \
        || bad "ответ опроса потерян ($got)"
fi

# План и прогон обязаны решать по одному условию, иначе сухой прогон снова
# начнёт обещать не то. Сверяем, что оба смотрят на CLI_HOST и RECONFIGURE.
plan_cond="$(grep -c 'CLI_HOST" \] && \[ "\$RECONFIGURE" = 1' install.sh || true)"
run_cond="$(sed -n '/^endpoint_final()/,/^}$/p' install.sh \
            | grep -c 'CLI_HOST:-}" \] && \[ "\${RECONFIGURE:-0}" = 1' || true)"
if [ "$plan_cond" -ge 1 ] && [ "$run_cond" -ge 1 ]; then
    ok "план и прогон решают по одному условию (--host + --reconfigure)"
else
    bad "условия плана и прогона разошлись (план=$plan_cond, прогон=$run_cond)" \
        "сухой прогон снова начнёт обещать то, чего не будет"
fi


# ═══════════════════════════════════════════════════════════════════════════
head_ "13. Порядок в main(): plan_services не отменяет ответ владельца"
# Раздел 12 проверяет саму endpoint_final — и был зелёным, пока
# `--reconfigure --host` молча не работал: plan_services сорсит services.env в
# ОБЩУЮ область видимости (local ENDPOINT в файле нет ни разу) и возвращает
# переменную к прошлому значению. Функция верна, порядок — нет. Поэтому здесь
# воспроизводится та же последовательность, что в main():
#   ENDPOINT=$(endpoint_final) → plan_services → блок «намерение сильнее»
PS="$(sed -n '/^plan_services()/,/^}$/p' install.sh)"
INTENT="$(sed -n '/^    case "\$AWG_VER" in$/,/^    ENDPOINT="\$(endpoint_final)"$/p' install.sh)"
# Без конечной строки sed дотягивает срез до конца файла — тогда eval
# получил бы весь установщик. Требуем и признак, и разумный размер.
n_intent="$(printf '%s\n' "$INTENT" | wc -l)"
# Без конечной строки sed дотягивает срез до конца файла, и eval получил бы
# весь установщик. Требуем и признак, и разумный размер — иначе откат
# краснел бы, но по неверной причине.
intent_ok=1
[ -n "$PS" ] || intent_ok=0
[ -n "$INTENT" ] || intent_ok=0
[ "$n_intent" -le 30 ] || intent_ok=0
printf '%s' "$INTENT" | grep -q endpoint_final || intent_ok=0
if [ "$intent_ok" = 0 ]; then
    bad "блок намерения вырезан не целиком ($n_intent строк)" "в нём должен быть вызов endpoint_final — без него порядок не проверить"
else
    order() {  # order <CLI_HOST> <RECONFIGURE> <ENDPOINT в services.env>
        local d; d="$(mktemp -d)"
        {
            echo "LAYER2=1"; echo "LAYER3=0"; echo "KMOD3=0"
            echo "IFACE2=awg2"; echo "IFACE3=awg3"
            echo "PORT2=51820"; echo "PORT3=51821"
            echo "SUBNET2=10.29.79"; echo "SUBNET3=10.29.80"
            echo "MTU2=1420"; echo "MTU3=1380"; echo "WAN=eth0"
            echo "ENDPOINT='$3'"
        } > "$d/services.env"
        ( set -uo pipefail
          # export, а не голое присваивание: всё это читают вырезанные из
          # install.sh куски, и статически такую связь не увидеть.
          export SERVICES="$d/services.env" CLI_HOST="$1" RECONFIGURE="$2"
          export AWG_ENDPOINT="$1" AWG_VER=2 CLI_PORTS="" CLI_VER="" CLI_DNS=""
          log() { :; }; err() { :; }; warn() { :; }
          installed() { [ -f "$SERVICES" ]; }
          busy_ports() { :; }; pick_random_port() { echo 40000; }
          eval "$EPF"; eval "$PS"
          ENDPOINT="$(endpoint_final)"
          plan_services >/dev/null 2>&1
          eval "$INTENT"
          printf '%s' "$ENDPOINT" )
        rm -rf "$d"
    }

    got="$(order new.example.org 1 old.example.org)"
    [ "$got" = new.example.org ] \
        && ok "адрес владельца дожил до записи ($got)" \
        || bad "plan_services отменил ответ владельца: [$got]" \
               "именно так --reconfigure --host молча не работал, пока раздел 12 был зелёным"

    got="$(order "" 0 old.example.org)"
    [ "$got" = old.example.org ] \
        && ok "без --host сохранённый адрес на месте" \
        || bad "сохранённый адрес потерян: [$got]"
fi

printf '\n'
[ "$fail" = 0 ] && echo "═══ ВСЁ ЗЕЛЁНОЕ ═══" || echo "═══ ЕСТЬ ПАДЕНИЯ ═══"
exit $fail
