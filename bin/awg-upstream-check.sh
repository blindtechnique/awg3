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

# Готов ли kernel-модуль к 3.0. Проверяем не номер PR, а саму возможность:
# есть ли в заголовке ветки master netlink-атрибут header protection. Как
# только апстрим вольёт PR #192, ответ сменится сам, без правок скрипта.
kmod3_state() {
    local url=https://raw.githubusercontent.com/amnezia-vpn/amneziawg-linux-kernel-module
    if curl -fsS --max-time 15 "$url/master/src/uapi/wireguard.h" 2>/dev/null \
         | grep -q WGDEVICE_A_HEADER_PROTECTION_KEY; then
        echo master; return 0
    fi
    if curl -fsS --max-time 15 "$url/feat/awg3/src/uapi/wireguard.h" 2>/dev/null \
         | grep -q WGDEVICE_A_HEADER_PROTECTION_KEY; then
        echo branch; return 0
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

# ── amneziawg-go: только если стоит слой 3.0 ────────────────────────────────
if command -v amneziawg-go >/dev/null 2>&1; then
    cur="$(installed_go_ref)"; [ -n "$cur" ] || cur="(неизвестно)"
    new="$(latest_tag amnezia-vpn/amneziawg-go)"
    if [ -n "$new" ] && [ "$new" != "$cur" ]; then add_row "amneziawg-go" "$cur" "$new" 1
    else add_row "amneziawg-go" "$cur" "${new:-?}" 0; fi
fi

# ── amneziawg-tools: ставится пакетом, сравниваем с тегом апстрима ──────────
if command -v awg >/dev/null 2>&1; then
    # ВАЖНО: суффикс «-2» — часть версии (v1.0.20260618-2). Без него в шаблоне
    # установленная версия обрезалась до v1.0.20260618 и не совпадала с тегом,
    # из-за чего скрипт вечно докладывал о несуществующем обновлении.
    cur="$(awg --version 2>&1 | grep -oE 'v[0-9][0-9.]*(-[0-9]+)?' | head -1)"
    [ -n "$cur" ] || cur="(пакет)"
    new="$(latest_tag amnezia-vpn/amneziawg-tools)"
    if [ -n "$new" ] && [ "$new" != "$cur" ]; then add_row "amneziawg-tools" "$cur" "$new" 1
    else add_row "amneziawg-tools" "$cur" "${new:-?}" 0; fi
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
        master)
            echo
            if [ "${KMOD3:-0}" = 1 ]; then
                echo "Слой 3.0 в ядре: поддержка доехала до master — можно снять пометку"
                echo "«экспериментально» и перейти на релизные версии."
            else
                echo "🟢 Слой 3.0 появился в kernel-модуле апстрима (master)."
                echo "   Датапас 3.0 можно перевести с userspace на ядро — это быстрее."
                echo "   Клиентов перевыпускать не нужно: параметры и ключи те же."
            fi ;;
        branch)
            echo
            if [ "${KMOD3:-0}" = 1 ]; then
                echo "Режим --kmod3: модуль и утилиты собраны из ветки feat/awg3."
                echo "Она ещё не влита в master и меняется часто — следи за обновлениями."
            else
                echo "Слой 3.0 в ядре пока готовится (ветка feat/awg3, PR #192)."
                echo "Сейчас 3.0 работает через userspace-датапас — это штатный режим."
            fi ;;
    esac
fi

[ "$UPDATES" -gt 0 ] && exit 10
exit 0
