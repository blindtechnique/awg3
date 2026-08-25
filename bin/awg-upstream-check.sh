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
        -h|--help) sed -n '3,12p' "$0" | sed 's/^# \?//'; exit 0 ;;
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

if [ "$JSON" = 1 ]; then
    printf '{"updates": %d, "kmod3": "%s", "items": [' "$UPDATES" "${KMOD3_STATE:-n/a}"
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

    # Отдельной строкой — не обновление, а смена возможностей апстрима.
    case "$KMOD3_STATE" in
        v30|v31)
            echo
            echo "Слой 3.0 в kernel-модуле апстрима есть (PR #192 влит 30.07.2026),"
            echo "но переезд датапаса с userspace на ядро ОТЛОЖЕН:"
            echo "  • kmod issue #215 — регрессия 3.0→3.1: хендшейк проходит, трафика нет;"
            echo "  • amnezia-client issue #3043 — то же самое, причём и на userspace 3.1,"
            echo "    и на kernel-модуле 3.1 одинаково."
            echo "Обе открыты без ответа мейнтейнеров. Чистого тега модуля сейчас нет:"
            echo "в v3.0.20260805 use-after-free в send.c, а фикс попал только в v3.1."
            [ "$KMOD3_STATE" = v31 ] && \
                echo "В master уже 3.1 (RandomTrailers, DisableCookies) — тем более не берём."
            echo "Сейчас 3.0 работает через userspace-датапас, и это штатный режим." ;;
    esac
    if [ -n "${UPSTREAM_NOTE:-}" ]; then
        echo
        echo "ℹ️  $UPSTREAM_NOTE"
        echo "   Это справка, а не повод обновляться: пин меняется вместе с кодом awg3."
    fi
fi

[ "$UPDATES" -gt 0 ] && exit 10
exit 0
