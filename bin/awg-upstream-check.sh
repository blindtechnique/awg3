#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# awg-upstream-check.sh — есть ли новые версии апстрима.
#
#   awg-upstream-check           # человекочитаемо
#   awg-upstream-check --json    # для бота
#   awg-upstream-check --quiet   # молча; код возврата 10 = есть обновления
#
# Проверяются: amneziawg-go (датапас слоя 3.0), amneziawg-tools и код самого
# слоя на GitHub. НИЧЕГО не обновляет — только сообщает. Пересборка датапаса
# без спроса рвёт туннели, поэтому решение всегда за администратором.
set -uo pipefail

DEST=/opt/awg3
SRC=/opt/src
JSON=0; QUIET=0

while [ $# -gt 0 ]; do
    case "$1" in
        --json) JSON=1; shift ;;
        --quiet) QUIET=1; shift ;;
        # Справка — это шапка файла, а не диапазон строк: жёсткие номера не
        # знают, где она кончилась, и ошибаются молча в обе стороны.
        -h|--help) awk 'NR==1||/^# *SPDX-/{next} /^#/{sub(/^# ?/,"");print;next} {exit}' "$0"; exit 0 ;;
        *) echo "Неизвестный флаг: $1" >&2; exit 2 ;;
    esac
done

# последний НЕ пре-релизный тег вида vX.Y.Z или vX.Y.YYYYMMDD
latest_tag() {  # latest_tag <owner/repo>
    git ls-remote --tags --refs "https://github.com/$1.git" 2>/dev/null \
        | awk -F/ '{print $NF}' | grep -E '^v[0-9]' | sort -V | tail -1
}

# Готов ли kernel-модуль принять слой 3.0.
#
# Раньше здесь искали в master netlink-атрибут header protection и по его
# наличию печатали зелёное «можно переводить датапас в ядро». PR #192 влит,
# атрибут в master есть с 30.07.2026 — и совет стал срабатывать всегда, толкая
# владельца ровно туда, где открыты регрессии. Наличия атрибута мало: важно,
# работает ли модуль. Поэтому теперь различаем 3.0 и 3.1 и не советуем переезд,
# пока открыты issues. Ветку feat/awg3 не проверяем — она удалена апстримом.
kmod3_state() {
    local url=https://raw.githubusercontent.com/amnezia-vpn/amneziawg-linux-kernel-module
    local hdr
    hdr="$(curl -fsS --max-time 15 "$url/master/src/uapi/wireguard.h" 2>/dev/null || true)"
    [ -n "$hdr" ] || { echo unknown; return 0; }
    if printf '%s' "$hdr" | grep -q WGDEVICE_A_RANDOM_TRAILERS; then
        echo v31; return 0
    fi
    if printf '%s' "$hdr" | grep -q WGDEVICE_A_HEADER_PROTECTION_KEY; then
        echo v30; return 0
    fi
    echo unknown
}

# ── блокеры переезда датапаса 3.0 в ядро ────────────────────────────────────
# Наличие параметров в модуле ещё не значит, что на нём можно работать: код 3.0
# лежит в выпущенном теге с 30.07.2026, а переезд не сделан из-за качества.
# Поэтому спрашиваем не «есть ли атрибут», а «закрыты ли дефекты».
#
# Список ведётся РУКАМИ и меняется вместе с кодом: это не «все issue апстрима»,
# а ровно те, на которых стоит решение держать 3.0 в userspace. Обоснование
# каждой — в README, раздел «Почему слой 3.0 не в ядре и когда будет».
KMOD_REPO="${AWG_KMOD_REPO:-amnezia-vpn/amneziawg-linux-kernel-module}"
KMOD_BLOCKERS="${AWG_KMOD_BLOCKERS:-215 222 225 226 227 228 233 253}"
BLOCKERS_CACHE="${AWG_BLOCKERS_CACHE:-$DEST/.kmod-blockers}"
BLOCKERS_TTL="${AWG_BLOCKERS_TTL:-21600}"   # 6 часов

# Печатает по строке на issue: "<номер> <open|closed>". Возвращает 1, если хоть
# об одной узнать не удалось: частичный ответ хуже отсутствия — пропущенная
# открытая issue превратилась бы в «всё закрыто, можно переезжать».
blockers_fetch() {
    command -v python3 >/dev/null 2>&1 || return 1
    local n raw st out="" want=0 got=0
    for n in $KMOD_BLOCKERS; do
        want=$((want + 1))
        raw="$(curl -fsS --max-time 10 "https://api.github.com/repos/$KMOD_REPO/issues/$n" 2>/dev/null || true)"
        [ -n "$raw" ] || continue
        st="$(printf '%s' "$raw" | python3 -c 'import sys, json
try:
    print(json.load(sys.stdin).get("state", ""))
except Exception:
    pass' 2>/dev/null || true)"
        case "$st" in
            open|closed) out="${out}${n} ${st}"$'\n'; got=$((got + 1)) ;;
        esac
    done
    [ "$got" = "$want" ] || return 1
    printf '%s' "$out"
}

# Ответ кэшируем: у неавторизованного API GitHub 60 запросов в час на адрес, а
# кнопку «Проверить обновления» в боте нажимают сколько угодно раз. Без кэша
# владелец получал бы 403 ровно тогда, когда ответ нужен.
blockers_state() {  # печатает строки "<номер> <open|closed>"; 1 — данных нет
    local now age=0 mtime new
    now="$(date +%s)"
    if [ -f "$BLOCKERS_CACHE" ]; then
        mtime="$(stat -c %Y "$BLOCKERS_CACHE" 2>/dev/null || echo 0)"
        age=$((now - mtime))
    fi
    if [ ! -f "$BLOCKERS_CACHE" ] || [ "$age" -ge "$BLOCKERS_TTL" ]; then
        new="$(blockers_fetch || true)"
        # Пишем только полный ответ. Неполный не кэшируем вовсе, иначе «не
        # смогли спросить» осело бы в кэше как факт и жило там шесть часов.
        if [ -n "$new" ]; then
            mkdir -p "$(dirname "$BLOCKERS_CACHE")" 2>/dev/null || true
            if printf '%s' "$new" > "$BLOCKERS_CACHE.tmp" 2>/dev/null; then
                mv -f "$BLOCKERS_CACHE.tmp" "$BLOCKERS_CACHE" 2>/dev/null || rm -f "$BLOCKERS_CACHE.tmp"
            else
                rm -f "$BLOCKERS_CACHE.tmp" 2>/dev/null || true
            fi
        fi
    fi
    [ -s "$BLOCKERS_CACHE" ] || return 1
    cat "$BLOCKERS_CACHE"
}

# Отдельный раздел вывода — не обновление, а состояние вопроса «когда в ядро».
# Вынесен функцией, чтобы стенд мог прогнать все три исхода, а не читать их
# глазами: ветка «проверить не удалось» обязана молчать о готовности, и это
# единственное, что отличает честный отчёт от ложной зелени.
kmod3_report() {
    case "$KMOD3_STATE" in
        v30|v31) ;;
        *) return 0 ;;
    esac
    echo
    echo "Переезд датапаса 3.0 в ядро"
    echo "  Параметры 3.0 в модуле апстрима есть с тега v3.0.20260730."
    if [ "$BLOCKERS_KNOWN" = 1 ] && [ "$BLOCKERS_OPEN" != 0 ]; then
        echo "  Открыто блокеров: $BLOCKERS_OPEN из $BLOCKERS_TOTAL —$BLOCKERS_LIST"
        echo "  Пока открыт хотя бы один, слой 3.0 остаётся на amneziawg-go."
        echo "  Что именно сломано — в README, «Почему слой 3.0 не в ядре»."
    elif [ "$BLOCKERS_KNOWN" = 1 ]; then
        echo "  Открыто блокеров: 0 из $BLOCKERS_TOTAL — все известные закрыты."
        echo "  Это НЕ команда переезжать: решение принимается руками и после"
        echo "  проверки на стенде. Начать — с README, «Почему слой 3.0 не в ядре»."
    else
        echo "  Состояние блокеров проверить не удалось (нет сети, нет python3"
        echo "  или исчерпан лимит запросов GitHub)."
        echo "  Решение от этого не меняется: слой 3.0 остаётся на amneziawg-go."
    fi
    if [ "$KMOD3_STATE" = v31 ]; then
        echo "  В master апстрима уже 3.1 (RandomTrailers, DisableCookies) — не берём."
    fi
}

installed_go_ref() {
    [ -d "$SRC/amneziawg-go/.git" ] || { echo ""; return; }
    git -C "$SRC/amneziawg-go" describe --tags --exact-match 2>/dev/null \
        || git -C "$SRC/amneziawg-go" rev-parse --short HEAD 2>/dev/null
}

UPDATES=0
declare -a ROWS=()

add_row() {  # add_row <что> <установлено> <доступно> <есть_обновление>
    ROWS+=("$1|$2|$3|$4")
    [ "$4" = 1 ] && UPDATES=$((UPDATES+1))
    return 0
}

# Пины установщика. Держим их в согласии с install.sh — там же объяснено, почему
# проект остаётся на серии 3.0 и не идёт на 3.1.
#
# Сравнивать установленное с ПОСЛЕДНИМ тегом апстрима нельзя: мы намеренно
# пинуемся на 3.0, апстрим ушёл на 3.1, и «есть обновление» горело бы вечно —
# бот слал бы уведомления, `--update` ничего бы не менял, и так по кругу.
# Ровно этот класс бага уже числится исправленным для 1.0.1. Поэтому обновлением
# считается расхождение с ПИНОМ, а свежий тег апстрима идёт отдельной справкой.
PIN_GO="${AWG_GO_REF:-v3.0.20260805}"
PIN_TOOLS="${AWG_TOOLS_REF:-v1.0.20260618-2}"
UPSTREAM_NOTE=""

# ── amneziawg-go: только если стоит слой 3.0 ────────────────────────────────
if command -v amneziawg-go >/dev/null 2>&1; then
    cur="$(installed_go_ref)"; [ -n "$cur" ] || cur="(неизвестно)"
    if [ "$cur" != "$PIN_GO" ]; then add_row "amneziawg-go" "$cur" "$PIN_GO" 1
    else add_row "amneziawg-go" "$cur" "$PIN_GO" 0; fi
    new="$(latest_tag amnezia-vpn/amneziawg-go)"
    [ -n "$new" ] && [ "$new" != "$PIN_GO" ] && \
        UPSTREAM_NOTE="апстрим выпустил amneziawg-go $new (установщик пиннится на $PIN_GO)"
fi

# ── amneziawg-tools: ставится пакетом, сравниваем с тегом апстрима ──────────
if command -v awg >/dev/null 2>&1; then
    # ВАЖНО: суффикс «-2» — часть версии (v1.0.20260618-2). Без него в шаблоне
    # установленная версия обрезалась до v1.0.20260618 и не совпадала с тегом,
    # из-за чего скрипт вечно докладывал о несуществующем обновлении.
    cur="$(awg --version 2>&1 | grep -oE 'v[0-9][0-9.]*(-[0-9]+)?' | head -1 || true)"
    [ -n "$cur" ] || cur="(пакет)"
    if [ "$cur" != "$PIN_TOOLS" ]; then add_row "amneziawg-tools" "$cur" "$PIN_TOOLS" 1
    else add_row "amneziawg-tools" "$cur" "$PIN_TOOLS" 0; fi
fi

# ── kernel-модуль: что реально собрано ──────────────────────────────────────
if [ -f /opt/src/.amneziawg-kmod.ref ]; then
    cur="$(cut -f1 /opt/src/.amneziawg-kmod.ref 2>/dev/null || true)"
    add_row "kernel-модуль" "${cur:-неизвестно}" "${cur:-—}" 0
fi

# ── код слоя ────────────────────────────────────────────────────────────────
if [ -f "$DEST/.rev" ]; then
    cur="$(cat "$DEST/.rev")"
    branch="$(cat "$DEST/.branch" 2>/dev/null || echo main)"
    new="$(git ls-remote "https://github.com/blindtechnique/awg3.git" "refs/heads/$branch" 2>/dev/null | cut -c1-12)"
    if [ -n "$new" ] && [ "$new" != "$cur" ]; then add_row "код awg3 ($branch)" "$cur" "$new" 1
    else add_row "код awg3 ($branch)" "$cur" "${new:-?}" 0; fi
fi

# состояние поддержки 3.0 в ядре — только когда слой 3.0 вообще установлен
KMOD3_STATE=""
# shellcheck disable=SC1090
[ -f /etc/amnezia/amneziawg/services.env ] && . /etc/amnezia/amneziawg/services.env 2>/dev/null || true
[ "${LAYER3:-0}" = 1 ] && KMOD3_STATE="$(kmod3_state)"

# Блокеры спрашиваем там же и по тому же условию: без слоя 3.0 вопрос «когда в
# ядро» не стоит, а лишние запросы к GitHub съедают лимит.
BLOCKERS_OPEN=0; BLOCKERS_TOTAL=0; BLOCKERS_KNOWN=0; BLOCKERS_LIST=""
if [ "${LAYER3:-0}" = 1 ]; then
    BLOCKERS_TXT="$(blockers_state || true)"
    if [ -n "$BLOCKERS_TXT" ]; then
        BLOCKERS_KNOWN=1
        while read -r bnum bstate; do
            [ -n "$bnum" ] || continue
            BLOCKERS_TOTAL=$((BLOCKERS_TOTAL + 1))
            if [ "$bstate" = open ]; then
                BLOCKERS_OPEN=$((BLOCKERS_OPEN + 1))
                BLOCKERS_LIST="$BLOCKERS_LIST #$bnum"
            fi
        done <<< "$BLOCKERS_TXT"
    fi
fi

if [ "$JSON" = 1 ]; then
    printf '{"updates": %d, "kmod3": "%s", "kmod3_blockers": {"known": %s, "open": %d, "total": %d}, "items": [' \
        "$UPDATES" "${KMOD3_STATE:-n/a}" \
        "$([ "$BLOCKERS_KNOWN" = 1 ] && echo true || echo false)" \
        "$BLOCKERS_OPEN" "$BLOCKERS_TOTAL"
    first=1
    for r in "${ROWS[@]}"; do
        IFS='|' read -r what cur new upd <<< "$r"
        [ "$first" = 1 ] || printf ','
        first=0
        printf '{"name":"%s","installed":"%s","latest":"%s","update":%s}' \
            "$what" "$cur" "$new" "$([ "$upd" = 1 ] && echo true || echo false)"
    done
    printf ']}\n'
elif [ "$QUIET" = 0 ]; then
    printf '%-22s %-18s %s\n' КОМПОНЕНТ УСТАНОВЛЕНО ДОСТУПНО
    for r in "${ROWS[@]}"; do
        IFS='|' read -r what cur new upd <<< "$r"
        mark=""; [ "$upd" = 1 ] && mark="  ← есть обновление"
        printf '%-22s %-18s %s%s\n' "$what" "$cur" "$new" "$mark"
    done
    echo
    if [ "$UPDATES" = 0 ]; then
        echo "Всё актуально."
    else
        echo "Обновить код слоя:  bash install.sh --update"
        echo "(конфиги, порты и клиенты при этом не меняются)"
    fi

    kmod3_report
    if [ -n "${UPSTREAM_NOTE:-}" ]; then
        echo
        echo "ℹ️  $UPSTREAM_NOTE"
        echo "   Это справка, а не повод обновляться: пин меняется вместе с кодом awg3."
    fi
fi

[ "$UPDATES" -gt 0 ] && exit 10
exit 0
