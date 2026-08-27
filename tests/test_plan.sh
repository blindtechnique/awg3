#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# --plan: показать, что сделает прогон, и ничего не сделать.
#
# Три свойства, ради которых он и нужен:
#   1) отчёт совпадает с тем, что произойдёт на самом деле — решение о режиме
#      берётся общей функцией obf_mode, а проверки апстрима повторяют условия
#      самих сборщиков;
#   2) сам план не меняет на диске ни байта;
#   3) план стоит РАНЬШЕ веток, которые делают настоящую работу.
#
#   bash tests/test_plan.sh
fail=0
ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
cd "$ROOT" || exit 1

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

ok()  { printf '  ✔ %s\n' "$1"; }
bad() { printf '  ✘ %s\n' "$1"; [ $# -gt 1 ] && printf '     %s\n' "$2"; fail=1; }
inc() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "нет «$3»" ;; esac; }
noinc() { case "$2" in *"$3"*) bad "$1" "лишнее «$3»" ;; *) ok "$1" ;; esac; }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# ── подставной апстрим ──────────────────────────────────────────────────────
# Без него отчёт зависел бы от того, что установлено на машине с тестами, и
# «пересборка» то появлялась бы, то нет.
STUB="$WORK/stub"; mkdir -p "$STUB"
printf '#!/bin/sh\nexit 0\n'                              > "$STUB/modinfo"
printf '#!/bin/sh\necho "amneziawg-go v3.0.20260805"\n'   > "$STUB/amneziawg-go"
printf '#!/bin/sh\necho "awg v1.0.20260618-2"\n'          > "$STUB/awg"
printf '#!/bin/sh\nexit 0\n'                              > "$STUB/awg-quick"
chmod +x "$STUB"/*
export PATH="$STUB:$PATH"

# ── стенд ───────────────────────────────────────────────────────────────────
mk_stand() {  # mk_stand <каталог> <layers: none|2|3|23> <клиентов на слой>
    local d="$1" L="$2" n="${3:-3}" l2=0 l3=0 i
    case "$L" in *2*) l2=1 ;; esac
    case "$L" in *3*) l3=1 ;; esac
    # bin/awg-client.sh обязателен: без него install.sh считает структуру
    # неполной, лезет клонировать репозиторий с GitHub и перезапускает СЕБЯ
    # опубликованной версией — тест мерил бы чужой код.
    mkdir -p "$d/etc" "$d/dest/clients" "$d/bin" "$d/src/amneziawg-tools"
    : > "$d/bin/awg-client.sh"
    if [ "$L" != none ]; then
        {
            echo "LAYER2='$l2'"; echo "LAYER3='$l3'"
            echo "IFACE2='awg2'"; echo "IFACE3='awg3'"
            echo "SUBNET2='10.29.79'"; echo "SUBNET3='10.29.80'"
            echo "PORT2='51820'"; echo "PORT3='51821'"
            echo "MTU2='1420'"; echo "MTU3='1380'"
            echo "DNS='1.1.1.1, 8.8.8.8'"; echo "ENDPOINT='vpn.example.org'"
            echo "WAN='eth0'"; echo "CLIENT_DIR='$d/dest/clients'"; echo "KMOD3='0'"
        } > "$d/etc/services.env"
        # AWG_VER обязан совпадать с составом слоёв: на настоящем сервере
        # install-state.env пишет та же установка, что подняла интерфейсы.
        # Стенд с LAYER3=0 и AWG_VER='both' мерил бы состояние, которого нет.
        local ver=both
        [ "$l3" = 0 ] && ver=2
        [ "$l2" = 0 ] && ver=3
        printf "AWG_PRESET='medium'\nAWG_VER='%s'\n" "$ver" > "$d/dest/install-state.env"
        if [ "$l2" = 1 ]; then
            printf "AWG_Jc='4'\n" > "$d/etc/obfuscation.env"
            mkdir -p "$d/dest/clients/awg2"
            for i in $(seq 1 "$n"); do printf '[Interface]\n' > "$d/dest/clients/awg2/p$i-am.conf"; done
        fi
        if [ "$l3" = 1 ]; then
            printf "AWG_Jc='5'\n" > "$d/etc/obfuscation3.env"
            mkdir -p "$d/dest/clients/awg3"
            for i in $(seq 1 "$n"); do printf '[Interface]\n' > "$d/dest/clients/awg3/l$i-am.conf"; done
        fi
    fi
    return 0
}

# копия установщика с путями, перенаправленными на стенд
inst() {  # inst <каталог> → путь к скрипту
    local d="$1" f="$1/install.sh"
    [ -f "$f" ] && { echo "$f"; return; }
    cp install.sh "$f"
    sed -i "s#^DEST=/opt/awg3#DEST=$d/dest#" "$f"
    sed -i "s#^AWG_DIR=/etc/amnezia/amneziawg#AWG_DIR=$d/etc#" "$f"
    sed -i "s#^SRC=/opt/src#SRC=$d/src#" "$f"
    # Проверку на root снимаем только у копии: стенд под root не гоняется.
    # Что она есть в настоящем скрипте — отдельный пункт ниже, и это важно:
    # без root план читал бы services.env и профили с правами 600 и показал бы
    # «первая установка» на работающем сервере, то есть соврал бы.
    sed -i 's#^\[ "$(id -u)" = 0 \] .*#:#' "$f"
    echo "$f"
}

snapshot() {  # snapshot <каталог> — состав и содержимое, кроме копии скрипта
    ( cd "$1" && find etc dest src bin -type f 2>/dev/null | sort | xargs md5sum 2>/dev/null )
}

plan() {  # plan <каталог> <флаги…> → отчёт
    local d="$1"; shift
    local sh; sh="$(inst "$d")"
    bash "$sh" --plan "$@" 2>&1
}

# ═══════════════════════════════════════════════════════════════════════════
head_ "1. План ничего не меняет на диске"
D="$WORK/ro"; mk_stand "$D" 23 3
before="$(snapshot "$D")"
out="$(plan "$D")"
after="$(snapshot "$D")"
if [ "$before" = "$after" ]; then
    ok "ни один файл не изменился и не появился"
else
    bad "план что-то тронул" "$(diff <(echo "$before") <(echo "$after") | head -5)"
fi
inc "и сам говорит, что это только план" "$out" "Это только план: ничего не изменено"

# ═══════════════════════════════════════════════════════════════════════════
head_ "2. Обычный прогон: профиль сохраняется"
inc "названа операция"              "$out" "ПОВТОРНЫЙ ПРОГОН"
inc "профиль 2.0 в «не изменится»"  "$out" "профиль обфускации 2.0 (применяется существующий)"
inc "профиль 3.0 тоже"              "$out" "профиль обфускации 3.0 (применяется существующий)"
inc "перевыпуска НЕ будет"          "$out" "перевыпуск профиля обфускации 2.0"
inc "переимпорт не понадобится"     "$out" "Переимпортировать конфиги никому не придётся"
inc "порты названы"                 "$out" "51820"
inc "подсети названы"               "$out" "10.29.79.0/24"
inc "число конфигов 2.0"            "$out" "конфиги клиентов 2.0: 3"
inc "число конфигов 3.0"            "$out" "конфиги клиентов 3.0: 3"
inc "сказано про разрыв связи"      "$out" "связь прервётся дважды"
inc "и что срок неизвестен"         "$out" "заранее не известно"
inc "apt назван"                    "$out" "! пакеты: apt-get update"
noinc "и никого не пугает зря"      "$out" "перестанут подключаться"

# ═══════════════════════════════════════════════════════════════════════════
head_ "3. --reconfigure: сказано, скольких это отключит"
out="$(plan "$D" --reconfigure)"
inc "названа операция"          "$out" "НОВЫЙ ПРОФИЛЬ ОБФУСКАЦИИ"
inc "профиль 2.0 — новый"       "$out" "профиль обфускации 2.0 — НОВЫЙ"
inc "и сказано, сколько ломает" "$out" "конфиги клиентов 2.0: 3 — все перестанут подключаться"
inc "профиль 3.0 — тоже новый"  "$out" "профиль обфускации 3.0 — НОВЫЙ"
inc "предупреждение выдано"     "$out" "придётся заново скачать и импортировать"
# План не всеведущ: --reconfigure заново проводит опрос, и ответы, которых нет
# во флагах, ещё будут вводиться руками. Молчать об этом — обещать точность,
# которой нет.
inc "сказано, что параметры переспросят" "$out" "переспросит версию, обфускацию и домен"
noinc "ложного успокоения нет"  "$out" "никому не придётся"
after2="$(snapshot "$D")"
[ "$before" = "$after2" ] && ok "и даже разрушительный план ничего не тронул" \
    || bad "план с --reconfigure изменил файлы"

# ═══════════════════════════════════════════════════════════════════════════
head_ "4. --update: до профиля и клиентов дело не доходит"
out="$(plan "$D" --update)"
inc "названа операция"        "$out" "ОБНОВЛЕНИЕ КОДА"
inc "профили сохраняются"     "$out" "✓ профиль обфускации 2.0"
inc "конфиги сохраняются"     "$out" "конфиги клиентов 2.0: 3, 3.0: 3 — не пересоздаются"
inc "модуль не трогается"     "$out" "✗ сборка kernel-модуля и утилит"
inc "и apt тоже"              "$out" "✗ apt-get"
noinc "apt не в «изменится»"  "$out" "! пакеты: apt-get update"
inc "порты не меняются"       "$out" "смена портов, подсетей и ключей"
inc "переимпорт не нужен"     "$out" "Переимпортировать конфиги никому не придётся"
noinc "ничего не «НОВЫЙ»"     "$out" "НОВЫЙ"
noinc "слой 2.0 не дёргается" "$out" "связь прервётся дважды"

# ═══════════════════════════════════════════════════════════════════════════
head_ "5. Только слой 2.0: про 3.0 не выдумывается"
D2="$WORK/l2"; mk_stand "$D2" 2 4
out="$(plan "$D2" --awg 2)"
inc "конфиги 2.0 посчитаны"   "$out" "конфиги клиентов 2.0: 4"
noinc "нет чужого порта"      "$out" "51821"
noinc "нет профиля 3.0"       "$out" "профиль обфускации 3.0"
# «3.0: 0» на сервере без слоя 3.0 — тот же сорт вранья, что и умолчание.
out="$(plan "$D2" --awg 2 --update)"
inc "обновление считает конфиги 2.0" "$out" "конфиги клиентов 2.0: 4 — не пересоздаются"
noinc "и не выдумывает нулевой 3.0"  "$out" "3.0: 0"

head_ "5б. --awg без --reconfigure не применяется — и план это говорит"
# ask_params при существующем install-state.env и без --reconfigure выходит
# РАНЬШЕ строки AWG_VER="${CLI_VER:-}". Значит --awg 3 на установленном сервере
# не отключает ничего, и отчёт, обещающий отключение слоя, — ложная тревога в
# самом опасном месте.
out="$(plan "$D" --awg 3)"
inc "сказано, что флаг проглочен" "$out" "НЕ будут применены: --awg"
inc "и почему"                    "$out" "меняются только вместе с"
noinc "ложной тревоги нет"        "$out" "ОТКЛЮЧАЕТСЯ"
inc "показаны оба слоя, как и будет" "$out" "2.0 51820"
inc "и второй тоже"                  "$out" "3.0 51821"

head_ "5в. --reconfigure --awg 3 действительно отключает 2.0 — и говорит это"
# Здесь ask_params отрабатывает целиком, AWG_VER=3, write_services пишет
# LAYER2=0: туннель останется, но awg-client перестанет обслуживать слой.
out="$(plan "$D" --reconfigure --awg 3)"
inc "сказано про отключение"  "$out" "слой 2.0 ОТКЛЮЧАЕТСЯ"
inc "названа причина"         "$out" "LAYER2=0"
inc "назван масштаб"          "$out" "конфиги 2.0 (3 шт.) больше не выпускаются"
noinc "порт выключенного слоя не в «не изменится»" "$out" "2.0 51820"

head_ "5г. Добавление 3.0 к работающему 2.0 стоит клиентов 2.0"
# Слой добавляется только через --reconfigure, а он перевыпускает ОБА профиля:
# obf_mode при RECONFIGURE=1 отдаёт --apply для каждого. Умолчать об этом —
# отправить владельца отключать всех, не сказав ему об этом.
out="$(plan "$D2" --reconfigure --awg both)"
inc "профиль 3.0 будет создан"    "$out" "профиль обфускации 3.0 — НОВЫЙ"
inc "сказано, что слой новый"     "$out" "слой 3.0 добавляется к существующей установке"
inc "но и профиль 2.0 новый"      "$out" "профиль обфускации 2.0 — НОВЫЙ"
inc "и клиенты 2.0 названы"       "$out" "конфиги клиентов 2.0: 4 — все перестанут подключаться"
noinc "ложного успокоения нет"    "$out" "слой 2.0 при этом не затрагивается"

# ═══════════════════════════════════════════════════════════════════════════
head_ "5д. --host меняет адрес, а выданные конфиги остаются со старым"
# resolve_endpoint отдаёт приоритет --host, но зовут её только из ask_params —
# то есть при --reconfigure. А regen-all переписывает лишь блок обфускации и
# [Peer] не трогает: Endpoint в уже выданных конфигах останется прежним.
out="$(plan "$D" --reconfigure --host new.example.org)"
inc "смена адреса названа"        "$out" "адрес сервера: vpn.example.org → new.example.org"
inc "сказано про старый Endpoint" "$out" "останутся со СТАРЫМ Endpoint"
noinc "адрес не обещан неизменным" "$out" "адрес vpn.example.org"
# А без --reconfigure --host не применяется вовсе
out="$(plan "$D" --host new.example.org)"
inc "проглоченный --host назван"  "$out" "НЕ будут применены: --host"
noinc "смены адреса нет"          "$out" "→ new.example.org"

head_ "5е. Возврат слоя 3.0 с ядра на userspace не молчит"
# plan_services гасит KMOD3 через log(), а он в отчёте заглушён редиректом.
DK="$WORK/kmod3"; mk_stand "$DK" 23 2
sed -i "s/KMOD3='0'/KMOD3='1'/" "$DK/etc/services.env"
out="$(plan "$DK")"
inc "переезд назван"        "$out" "возвращается с kernel-датапаса на userspace"
inc "названы юниты"         "$out" "поднимается awg3@"
inc "и что клиенты целы"    "$out" "остаются рабочими"

head_ "6. Чистая машина: план первой установки"
D3="$WORK/empty"; mk_stand "$D3" none
out="$(plan "$D3")"
inc "названа операция"           "$out" "ПЕРВАЯ УСТАНОВКА"
inc "сказано про сборку"         "$out" "сборка из исходников"
inc "порты названы честно"       "$out" "случайные свободные UDP-порты"
inc "сказано, что ломать нечего" "$out" "ломать нечего"
[ -f "$D3/etc/services.env" ] && bad "план создал services.env" || ok "services.env не создан"
[ -f "$D3/dest/install-state.env" ] && bad "план создал install-state.env" \
    || ok "install-state.env не создан"

head_ "6а. --ports проверяется там же, где проверит прогон"
# Валидация живёт в plan_services, а ветка первой установки до неё не доходит:
# без отдельной проверки план отвечал «успех» там, где прогон падает с кодом 2.
outp="$(plan "$D3" --ports 100,100 2>&1)"; rcp=$?
[ "$rcp" = 2 ] && ok "битые --ports → код 2, как у прогона" \
    || bad "битые --ports приняты" "код $rcp"
inc "и сказано, что это повтор отказа" "$outp" "откажет с кодом 2"
out="$(plan "$D3" --ports 51820,51821)"
inc "хорошие порты показаны"     "$out" "UDP-порты 51820 и 51821"

head_ "6б. --update на неустановленном сервере не притворяется"
out="$(plan "$D3" --update)"
inc "сказано прямо"        "$out" "ОБНОВЛЯТЬ НЕЧЕГО"
inc "и что будет без плана" "$out" "завершится отказом"

# ═══════════════════════════════════════════════════════════════════════════
head_ "7. Проверка на root остаётся"
if grep -q '^\[ "$(id -u)" = 0 \]' install.sh; then
    ok "установщик по-прежнему требует root"
else
    bad "проверка на root пропала" "без неё план прочитает не всё и соврёт"
fi

head_ "8. У плана нет своей копии условия"
# Если бы план решал сам, он бы разошёлся с прогоном — ровно этот класс ошибок
# в родственном репозитории уже случался дважды.
body="$(sed -n '/^plan_report()/,/^}/p' install.sh)"
if printf '%s\n' "$body" | grep -q 'RECONFIGURE.*!= 1.*-s '; then
    bad "в plan_report своя проверка профиля — она разойдётся с gen_obfuscation"
else
    ok "решение берётся общей obf_mode, а не повторяется"
fi
n="$(grep -c 'obf_mode "\$AWG_DIR/obfuscation' install.sh)"
[ "$n" -ge 4 ] && ok "obf_mode зовут и прогон, и план ($n мест)" \
    || bad "obf_mode используется реже, чем ожидалось ($n)"
if sed -n '/^gen_obfuscation()/,/^}/p' install.sh | grep -q 'mode2=--reapply'; then
    bad "в gen_obfuscation осталась своя копия условия"
else
    ok "gen_obfuscation тоже спрашивает obf_mode"
fi

# ═══════════════════════════════════════════════════════════════════════════
head_ "9. План стоит раньше любых действий"
# Тут была настоящая дыра в родственном репозитории: --update уходил своей
# дорогой ДО проверки плана, и `--plan --update` делал настоящее обновление.
mbody="$(sed -n '/^main()/,/^}/p' install.sh)"
nl_of() { printf '%s\n' "$mbody" | grep -n "$1" | head -1 | cut -d: -f1; }
pl="$(nl_of 'PLAN" = 1 \]; then')"
if [ -z "$pl" ]; then
    bad "в main() нет ветки плана"
else
    for pair in 'UNINSTALL" = 1 \]:--uninstall' 'UPDATE" = 1 \]:--update' \
                'menu_installed:меню' 'install_base_deps:установка пакетов' \
                'ask_params:опрос параметров' 'write_services:запись services.env'; do
        pat="${pair%%:*}"; name="${pair##*:}"
        n="$(nl_of "$pat")"
        if [ -z "$n" ]; then
            bad "не нашли в main(): $name"
        elif [ "$pl" -lt "$n" ]; then
            ok "план раньше, чем $name"
        else
            bad "$name отрабатывает раньше плана" "с --plan это будет сделано по-настоящему"
        fi
    done
fi

head_ "10. Операции без отчёта план не подменяет собой"
PE="$(sed -n '/^plan_entry()/,/^}/p' install.sh)"
if [ -z "$PE" ]; then
    bad "plan_entry не найдена"
else
    run_pe() {  # run_pe <переменная|""> → вывод и rc
        # shellcheck disable=SC2034  # их читает сама plan_entry под eval
        ( UNINSTALL=0; INSTALL_BOT=0; REMOVE_BOT=0
          [ -n "$1" ] && eval "$1=1"
          err() { printf 'ERR %s\n' "$*"; }
          plan_report() { echo "ВЫЗВАН_PLAN_REPORT"; }
          eval "$PE"
          plan_entry; printf 'rc=%s\n' "$?" )
    }
    out="$(run_pe "")"
    inc "обычный план доходит до отчёта" "$out" "ВЫЗВАН_PLAN_REPORT"
    inc "и завершается успехом"          "$out" "rc=0"
    for pair in 'UNINSTALL:--uninstall' 'INSTALL_BOT:--install-bot' \
                'REMOVE_BOT:--remove-bot'; do
        var="${pair%%:*}"; flag="${pair##*:}"
        out="$(run_pe "$var")"
        noinc "$flag не выполняется"  "$out" "ВЫЗВАН_PLAN_REPORT"
        inc   "$flag назван в отказе" "$out" "$flag"
        inc   "$flag → код 2"         "$out" "rc=2"
    done
fi

head_ "11. Страховки: в режиме плана запись невозможна"
for pair in 'write_services:services.env' 'ask_params:install-state.env'; do
    fn="${pair%%:*}"; what="${pair##*:}"
    if sed -n "/^$fn()/,/^}/p" install.sh | grep -q 'PLAN" = 1'; then
        ok "$fn отказывается работать в режиме плана ($what)"
    else
        bad "в $fn нет страховки" "ошибка в коде обернулась бы тихой записью $what"
    fi
done

head_ "11б. План не платит собой за самозагрузку"
# Разбор флагов идёт ПОСЛЕ блока самозагрузки: `bash <(curl …) --plan` на
# машине без git успевал поставить пакет раньше, чем что-то показать.
if grep -q 'PLAN_EARLY=1' install.sh && \
   sed -n '/PLAN_EARLY=0/,/^REPO_DIR=/p' install.sh | grep -q 'требует git'; then
    ok "по curl план отказывается ставить git ради отчёта"
else
    bad "самозагрузка ставит пакеты и в режиме плана"
fi
# И отказ должен стоять ДО самой установки пакета
bl="$(sed -n '/PLAN_EARLY=0/,/^REPO_DIR=/p' install.sh)"
g="$(printf '%s\n' "$bl" | grep -n 'PLAN_EARLY" = 1' | head -1 | cut -d: -f1)"
a="$(printf '%s\n' "$bl" | grep -n 'apt-get install -y -qq git' | head -1 | cut -d: -f1)"
if [ -n "$g" ] && [ -n "$a" ] && [ "$g" -lt "$a" ]; then
    ok "отказ стоит раньше apt-get"
else
    bad "отказ стоит позже установки пакета" "план успеет изменить машину"
fi

head_ "11в. Код возврата плана не теряется"
# Простой вызов plan_entry под set -e убивает оболочку прямо на нём: строка
# exit ниже не выполняется никогда, и всё, что допишут между ними, пропадёт.
if sed -n '/^main()/,/^}/p' install.sh | grep -q 'plan_entry || exit'; then
    ok "plan_entry вызывается так, что exit ниже достижим"
else
    bad "после plan_entry стоит недостижимый exit"
fi

head_ "12. Проверки апстрима повторяют условия сборщиков"
# plan_tools обязана спрашивать то же, что install_tools: одной версии
# бинарника мало — собранное из ветки и из тега сообщает одну строку.
if sed -n '/^plan_tools()/,/^}/p' install.sh | grep -q 'describe --tags --exact-match'; then
    ok "plan_tools сверяет и чекаут, как install_tools"
else
    bad "plan_tools смотрит только версию" "скажет «не трогаются» там, где будет пересборка"
fi
if sed -n '/^plan_kmod()/,/^}/p' install.sh | grep -q 'AWG_KMOD_REF'; then
    ok "plan_kmod смотрит на пин ревизии, как install_kmod"
else
    bad "plan_kmod не смотрит AWG_KMOD_REF"
fi
D4="$WORK/nosrc"; mk_stand "$D4" 23 1; rm -rf "$D4/src/amneziawg-tools"
out="$(plan "$D4")"
inc "без исходников утилит сказано про сборку" "$out" "утилиты amneziawg-tools: сборка из исходников"
noinc "и не выдаётся «X → X»" "$out" "v1.0.20260618-2 → v1.0.20260618-2"

printf '\n'
[ "$fail" = 0 ] && echo "═══ ВСЁ ЗЕЛЁНОЕ ═══" || echo "═══ ЕСТЬ ПАДЕНИЯ ═══"
exit $fail
