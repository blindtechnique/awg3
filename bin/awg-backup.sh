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
# Метка незавершённого восстановления — по образцу .migrate-in-progress из
# az-awg2. Ставится до первой разрушающей записи, снимается только если
# сервисы поднялись; её видит awg-doctor.
RESTORE_MARK="$AWG_DIR/.restore-in-progress"
DEST=/opt/awg3
OUT_DIR="${AWG_BACKUP_DIR:-/root}"

log() { printf '\033[1;36m[awg-backup]\033[0m %s\n' "$*" >&2; }
err() { printf '\033[1;31m[awg-backup]\033[0m %s\n' "$*" >&2; }

do_backup() {
    local out="${1:-}"
    local rc=0
    [ -n "$out" ] || out="${OUT_DIR}/awg-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
    local stage; stage="$(mktemp -d)"
    log "Сбор файлов…"
    mkdir -p "$stage/amneziawg" "$stage/clients" "$stage/state"

    cp "$AWG_DIR"/*.conf "$AWG_DIR"/*.env "$AWG_DIR"/*.v3 "$AWG_DIR"/*.meta \
        "$stage/amneziawg/" 2>/dev/null || true
    [ -d "$DEST/clients" ] && cp -r "$DEST/clients/." "$stage/clients/" 2>/dev/null || true
    cp "$DEST/stats.db" "$DEST/expiry.tsv" "$DEST/install-state.env" \
        "$stage/state/" 2>/dev/null || true

    # Считаем то, что уехало. В az-awg2 этот же `[ -d ] && cp || true` годами
    # был ложен из-за неверного DEST, и архив молча уходил без клиентских
    # ключей. Здесь путь верный, но конструкция та же — значит и проверка
    # нужна та же: только счёт отличает «клиентов нет» от «не скопировались».
    local n_src n_dst
    if [ -d "$DEST/clients" ]; then
        # `|| true` обязателен: под pipefail отказ find роняет присваивание, а
        # значит и весь прогон — ровно в том случае, который надо сообщить.
        n_src="$(find "$DEST/clients" -name '*.conf' 2>/dev/null | wc -l || true)"
        n_dst="$(find "$stage/clients" -name '*.conf' 2>/dev/null | wc -l || true)"
        if [ "$n_dst" != "$n_src" ]; then
            err "в архив попало $n_dst клиентских конфигов из $n_src в $DEST/clients"
            err "приватные ключи клиентов есть ТОЛЬКО там — такой архив их не восстановит"
            rc=1
        elif [ "$n_src" != 0 ]; then
            log "клиентских конфигов в архиве: $n_src"
        fi
    else
        log "$DEST/clients нет — клиентов ещё не выдавали"
    fi

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
    # Неполный архив не должен уезжать в чат как хороший: бот отдаёт файл
    # только при нулевом коде.
    return "$rc"
}

do_restore() {
    local file="$1"
    local orig="$1"          # путь владельца, а не расшифрованная копия в /tmp
    [ -f "$file" ] || { err "файл не найден: $file"; exit 1; }
    # rc — накопитель: прогон не обрывается на первом отказе (файлы уже
    # частично подменены), но код возврата обязан быть ненулевым. Бот печатает
    # «✅ Восстановлено.» ровно по rc = 0 (awg_bot.py:882) — до сих пор эта
    # галочка приходила всегда, даже когда не перезапускалось ничего.
    # svc — отдельно: только он решает судьбу метки, она про «файлы новые,
    # сервисы старые».
    local rc=0 svc=0

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
    # Метка ставится ДО первой разрушающей записи. Имя с точки: cp по маске *
    # её не затрёт и в следующий архив она не уедет.
    {
        printf 'MARK_STARTED=%s\n' "$(date -u +%FT%TZ 2>/dev/null || echo '?')"
        printf 'MARK_ARCHIVE=%s\n' "$orig"
    } > "$RESTORE_MARK"
    cp "$stage"/amneziawg/* "$AWG_DIR/" 2>/dev/null || true
    # Каталог клиентских ключей: пустой он означает не отказ копирования, а
    # архив без ключей — и тот, кто на него рассчитывает, обязан это узнать.
    if [ -n "$(ls -A "$stage/clients" 2>/dev/null || true)" ]; then
        cp -r "$stage/clients/." "$DEST/clients/" || {
            err "не скопированы клиентские конфиги в $DEST/clients"; rc=1; }
    else
        err "в архиве нет клиентских конфигов — приватные ключи клиентов"
        err "существуют только там, восстановить выданные конфиги нечем."
        rc=1
    fi
    cp "$stage"/state/* "$DEST/" 2>/dev/null || true
    chmod 600 "$AWG_DIR"/* 2>/dev/null || true
    rm -rf "$stage"

    log "Перезапуск сервисов…"
    # Без services.env оба флага берут умолчание 0, и весь блок ниже
    # становится пустым: не поднимается ни один интерфейс, и раньше об этом
    # не печаталось ни строки.
    if [ -f "$AWG_DIR/services.env" ]; then
        # shellcheck disable=SC1090
        . "$AWG_DIR/services.env" 2>/dev/null || { err "services.env битый"; rc=1; }
    else
        err "services.env не восстановлен — перезапускать нечего и нечем,"
        err "сервер остался на прежней конфигурации."
        rc=1; svc=1
    fi
    # 2>/dev/null снято сознательно: только так причина отказа доезжает до
    # бота — он показывает stderr исключительно при ненулевом коде.
    _svc() {  # _svc <что сломается, если не встанет> <юнит>
        local why="$1"; shift
        systemctl restart "$@" || {
            err "не перезапущено: $* — $why"
            err "  смотри: journalctl -u $1 -n 30 --no-pager"
            rc=1; svc=1
        }
    }
    if [ "${LAYER2:-0}" = 1 ]; then
        _svc "тоннель 2.0 не поднят, не подключится никто" "awg-quick@${IFACE2:-awg2}"
    fi
    if [ "${LAYER3:-0}" = 1 ]; then
        if [ "${KMOD3:-0}" = 1 ]; then u3="awg-quick@${IFACE3:-awg3}"; else u3="awg3@${IFACE3:-awg3}"; fi
        _svc "тоннель 3.0 не поднят" "$u3"
    fi
    if [ "$svc" = 0 ]; then rm -f "$RESTORE_MARK"; fi
    log "Восстановление завершено. Проверка: awg-doctor"
    if [ "$rc" != 0 ]; then
        err "восстановление доехало НЕ полностью — что именно, сказано выше."
        [ "$svc" = 0 ] || err "метка $RESTORE_MARK оставлена: awg-doctor напомнит."
    fi
    return "$rc"
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
