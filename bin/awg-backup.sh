#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# awg-backup.sh — бэкап и восстановление сервера AmneziaWG.
#
#   awg-backup backup [файл] [--encrypt]   создать архив
#   awg-backup restore <файл>              восстановить (.enc распознаётся сам)
#
# В архиве: ключи сервера, профили обфускации, план сервисов, ВСЕ клиентские
# конфиги и накопленная статистика. Приватные ключи клиентов существуют только
# в их конфигах — без этого каталога восстановленный сервер работает, но всех
# клиентов пришлось бы выдавать заново.
#
# --encrypt: архив шифруется (AES-256, PBKDF2). Бот умеет присылать бэкап в
# чат, а значит копия навсегда оседает в переписке — наружу лучше отдавать
# уже зашифрованный файл.
set -euo pipefail

AWG_DIR=/etc/amnezia/amneziawg
DEST=/opt/awg3
OUT_DIR="${AWG_BACKUP_DIR:-/root}"

log() { printf '\033[1;36m[awg-backup]\033[0m %s\n' "$*" >&2; }
err() { printf '\033[1;31m[awg-backup]\033[0m %s\n' "$*" >&2; }

do_backup() {
    local out="${1:-}"
    [ -n "$out" ] || out="${OUT_DIR}/awg-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
    local stage; stage="$(mktemp -d)"
    log "Сбор файлов…"
    mkdir -p "$stage/amneziawg" "$stage/clients" "$stage/state"

    cp "$AWG_DIR"/*.conf "$AWG_DIR"/*.env "$AWG_DIR"/*.v3 "$AWG_DIR"/*.meta \
        "$stage/amneziawg/" 2>/dev/null || true
    [ -d "$DEST/clients" ] && cp -r "$DEST/clients/." "$stage/clients/" 2>/dev/null || true
    cp "$DEST/stats.db" "$DEST/expiry.tsv" "$DEST/install-state.env" \
        "$stage/state/" 2>/dev/null || true

    echo "awg3 backup $(date -u +%FT%TZ)" > "$stage/MANIFEST"
    umask 077
    tar -czf "$out" -C "$stage" .
    rm -rf "$stage"
    chmod 600 "$out"

    if [ -n "${BACKUP_PASS:-}" ]; then
        if command -v openssl >/dev/null 2>&1; then
            if openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt \
                -in "$out" -out "$out.enc" -pass env:BACKUP_PASS 2>/dev/null; then
                shred -u "$out" 2>/dev/null || rm -f "$out"
                out="$out.enc"; chmod 600 "$out"
                log "Архив зашифрован (AES-256, PBKDF2)"
            else
                err "не удалось зашифровать — оставляю открытый архив"
            fi
        else
            err "openssl не найден — архив остаётся незашифрованным"
        fi
    fi

    log "Готово: $out ($(du -h "$out" | cut -f1))"
    echo "$out"
}

do_restore() {
    local file="$1"
    [ -f "$file" ] || { err "файл не найден: $file"; exit 1; }

    # зашифрованный архив расшифровываем во временный файл
    if [ "$file" != "${file%.enc}" ]; then
        if [ -z "${BACKUP_PASS:-}" ] && (exec </dev/tty) 2>/dev/null; then
            read -rsp "Пароль архива: " BACKUP_PASS < /dev/tty; echo >&2
            # export обязателен: openssl читает пароль ИЗ ОКРУЖЕНИЯ
            # (-pass env:…), а read создаёт обычную переменную оболочки.
            # Без него введённый с клавиатуры правильный пароль давал
            # «No environment variable BACKUP_PASS» и, с заглушённым stderr,
            # сообщение «неверный пароль или битый архив». То есть
            # восстановление зашифрованного архива в интерактиве не работало
            # никогда — работал только путь BACKUP_PASS=… в окружении.
            # На стороне создания архива export уже стоит, ниже по файлу.
            export BACKUP_PASS
        fi
        [ -n "${BACKUP_PASS:-}" ] || { err "нужен пароль для $file"; exit 2; }
        # НЕ local: тело trap в одинарных кавычках вычисляется в момент выхода
        # ОБОЛОЧКИ, когда do_restore давно вернулась и её local уже уничтожен.
        # Под set -u trap падал на «unbound variable»: расшифрованный архив с
        # приватными ключами сервера и ВСЕХ клиентов оставался лежать в /tmp, а
        # скрипт отдавал 1 сразу после строки «Восстановление завершено» — тот,
        # кто читает код возврата, видел отказ на успешном восстановлении.
        # ${_dec:-} — на случай выхода до присваивания: trap исполняется всегда.
        _dec="$(mktemp /tmp/awg-restore.XXXXXX.tar.gz)"
        trap 'rm -f "${_dec:-}"' EXIT
        openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 \
            -in "$file" -out "$_dec" -pass env:BACKUP_PASS 2>/dev/null \
            || { err "неверный пароль или битый архив"; exit 2; }
        file="$_dec"
    fi

    local stage; stage="$(mktemp -d)"
    log "Распаковка…"
    tar -xzf "$file" -C "$stage"
    [ -f "$stage/MANIFEST" ] || { err "не похоже на бэкап awg3"; exit 1; }

    mkdir -p "$AWG_DIR" "$DEST/clients"
    cp "$stage"/amneziawg/* "$AWG_DIR/" 2>/dev/null || true
    cp -r "$stage/clients/." "$DEST/clients/" 2>/dev/null || true
    cp "$stage"/state/* "$DEST/" 2>/dev/null || true
    chmod 600 "$AWG_DIR"/* 2>/dev/null || true
    rm -rf "$stage"

    log "Перезапуск сервисов…"
    # shellcheck disable=SC1090
    [ -f "$AWG_DIR/services.env" ] && . "$AWG_DIR/services.env" 2>/dev/null || true
    [ "${LAYER2:-0}" = 1 ] && systemctl restart "awg-quick@${IFACE2:-awg2}" 2>/dev/null || true
    if [ "${LAYER3:-0}" = 1 ]; then
        if [ "${KMOD3:-0}" = 1 ]; then u3="awg-quick@${IFACE3:-awg3}"; else u3="awg3@${IFACE3:-awg3}"; fi
        systemctl restart "$u3" 2>/dev/null || true
    fi
    log "Восстановление завершено. Проверка: awg-doctor"
    return 0
}

# --encrypt может стоять и вторым, и третьим аргументом
if [ "${2:-}" = "--encrypt" ] || [ "${3:-}" = "--encrypt" ]; then
    if [ -z "${BACKUP_PASS:-}" ]; then
        if (exec </dev/tty) 2>/dev/null; then
            read -rsp "Пароль для архива: " BACKUP_PASS < /dev/tty; echo >&2
        else
            err "нужен пароль: BACKUP_PASS=… awg-backup backup --encrypt"; exit 2
        fi
    fi
    export BACKUP_PASS
fi

case "${1:-}" in
    backup)  do_backup "$(printf '%s' "${2:-}" | grep -v '^--' || true)" ;;
    restore) [ $# -ge 2 ] || { err "укажи файл: restore <файл>"; exit 2; }; do_restore "$2" ;;
    *) grep '^#' "$0" | sed 's/^# \?//'; exit 0 ;;
esac
