#!/bin/bash
# Приёмка переноса в awg3: приоритет флагов обфускации + раздельный пресет 3.0.
INS="${1:?install.sh}"; OBF="${2:?awg-obfuscation.sh}"
fail=0
chk(){ if [ "$2" = "$3" ]; then echo "  ✔ $1"; else echo "  ✘ $1 — ждали [$3], получили [$2]"; fail=1; fi; }
has(){ if grep -qF -- "$2" "$3"; then echo "  ✔ $1"; else echo "  ✘ $1"; fail=1; fi; }

echo "══ 1. awg-obfuscation.sh: явный флаг сильнее сохранённого ═══════════════"
blk="$(sed -n '/^if \[ "\$REGEN" = 1 \]/,/^fi$/p' "$OBF")"
[ -n "$blk" ] || { echo "  ✘ блок регенерации не найден"; exit 1; }
M="$(mktemp)"; printf 'META_PRESET=low\nMETA_TEMPLATE=web\nMETA_FP=chrome\nMETA_HOST=\nMETA_MTU=1380\n' > "$M"
run(){ REGEN=1 STATE_META="$M" SET_PRESET="$1" PRESET="$2" SET_TEMPLATE="${3:-0}" TEMPLATE="${4:-}" \
       FP="" HOST="" MTU="" bash -c "log(){ :; }; APPLY=0; $blk; echo \"\$PRESET|\$TEMPLATE|\$FP|\$MTU\"" 2>/dev/null; }
chk "без флагов — из метаданных"      "$(run 0 '')"        "low|web|chrome|1380"
chk "--preset сильнее (это был баг)"  "$(run 1 medium)"    "medium|web|chrome|1380"
chk "--template тоже уважается"       "$(run 1 high 1 tls)" "high|tls|chrome|1380"
rm -f "$M"

echo
echo "══ 2. install.sh: проводка ─────────────────────────────────────────────"
has "флаг --preset3"          '--preset3)    CLI_PRESET3='   "$INS"
has "флаг --template3"        '--template3)  CLI_TEMPLATE3=' "$INS"
has "описаны в справке"       '--preset3 X --template3 Y'    "$INS"
has "переменные объявлены"    'CLI_PRESET3=""; CLI_TEMPLATE3=""' "$INS"
has "AWG_PRESET3 в state"     "AWG_PRESET3='\$PRESET3'"      "$INS"
has "AWG_TEMPLATE3 в state"   "AWG_TEMPLATE3='\$TEMPLATE3'"  "$INS"
has "совместимость: пусто = как 2.0" 'local P3="${AWG_PRESET3:-$P}" T3="${AWG_TEMPLATE3:-$T}"' "$INS"
has "слой 3.0 берёт свой пресет"     '--preset "$P3" ${T3:+--template "$T3"}' "$INS"
has "и свой лог"                     'preset=$P3 template=${T3:-default}'     "$INS"
has "предупреждение про router/low"  'router и low — БЕЗ header protection'   "$INS"
has "названа граница полного 3.0"    'Полный набор 3.0 начинается с medium'   "$INS"
has "подтверждение после выбора"     'слой 3.0 будет без header protection'   "$INS"

echo
echo "══ 3. Диалог целиком, с подставным tty ─────────────────────────────────"
dlg="$(awk '/^    if \[ -n "\$CLI_PRESET" \]; then$/,/^    fi$/' "$INS")"
[ -n "$dlg" ] || { echo "  ✘ блок диалога не найден"; fail=1; }

# перенаправление /dev/tty внутри подпроцесса невозможно, поэтому гоняем блок
# с заменой ">/dev/tty" на ">&2" — печать нас не интересует, только переменные
dlg_q="${dlg//> \/dev\/tty/>\&2}"
ask2() {
    local ver="$1"; shift
    ANSWERS="$*" AWG_VER="$ver" bash -c '
        set -euo pipefail
        has_tty(){ return 0; }
        log(){ :; }
        ask_pick(){ local v="$1" def="$2"; local a="${ANSWERS%% *}"
                    if [ "$ANSWERS" = "${ANSWERS#* }" ]; then ANSWERS=""; else ANSWERS="${ANSWERS#* }"; fi
                    [ -n "$a" ] || a="$def"; printf -v "$v" "%s" "$a"; }
        CLI_PRESET=""; CLI_TEMPLATE=""; CLI_FP=""
        CLI_PRESET3=""; CLI_TEMPLATE3=""
        PRESET=medium; TEMPLATE=""; FP=chrome; PRESET3=""; TEMPLATE3=""
        '"$dlg_q"'
        echo "$PRESET|$TEMPLATE|$PRESET3|$TEMPLATE3"
    ' 2>/dev/null
}

echo "  ── оба слоя: спрашивается второй пресет ──"
chk "2.0 low / 3.0 medium"      "$(ask2 both 2 0 3 0)"  "low||medium|"
chk "2.0 high+tls / 3.0 paranoid+quic" "$(ask2 both 4 2 5 1)" "high|tls|paranoid|quic"
chk "у 3.0 маскировка «как у 2.0»"     "$(ask2 both 4 2 3 0)" "high|tls|medium|tls"

echo "  ── только слой 3.0: вопрос всё равно задаётся ──"
chk "3.0 отдельно"              "$(ask2 3 2 0 5 0)"     "low||paranoid|"

echo "  ── только слой 2.0: лишнего вопроса нет ──"
chk "PRESET3 остаётся пустым"   "$(ask2 2 2 0)"         "low|||"

echo "  ── неинтерактивно: --preset3 подхватывается ──"
chk "флаги" "$(CLI_PRESET=low CLI_TEMPLATE=web CLI_PRESET3=paranoid CLI_TEMPLATE3=quic \
    AWG_VER=both bash -c 'set -euo pipefail; has_tty(){ return 1; }; log(){ :; }
    CLI_FP=""; PRESET=medium; TEMPLATE=""; FP=chrome; PRESET3=""; TEMPLATE3=""
    '"$dlg_q"'
    echo "$PRESET|$TEMPLATE|$PRESET3|$TEMPLATE3"' 2>/dev/null)" "low|web|paranoid|quic"

echo "  ── старая установка: пусто → слой 3.0 как 2.0 ──"
o(){ AWG_PRESET=high AWG_TEMPLATE=tls bash -c 'set -euo pipefail
     P="${AWG_PRESET:-medium}"; T="${AWG_TEMPLATE:-}"
     P3="${AWG_PRESET3:-$P}"; T3="${AWG_TEMPLATE3:-$T}"; echo "$P3|$T3"'; }
chk "наследование при отсутствии ключей" "$(o)" "high|tls"

echo
echo "══ 4. Синтаксис ────────────────────────────────────────────────────────"
bash -n "$INS" && echo "  ✔ install.sh" || fail=1
bash -n "$OBF" && echo "  ✔ awg-obfuscation.sh" || fail=1

echo
[ "$fail" = 0 ] && echo "═══ ВСЁ ЗЕЛЁНОЕ ═══" || echo "═══ ЕСТЬ ПАДЕНИЯ ═══"
exit $fail
