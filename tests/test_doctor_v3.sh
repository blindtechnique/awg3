#!/bin/bash
# Приёмка: доктор awg3 не пугает на пресетах без header protection и отличает
# «ключа нет» от «спросить не удалось».
DOC="${1:?awg-doctor.sh}"
fail=0
chk(){ if [ "$2" = "$3" ]; then echo "  ✔ $1"; else echo "  ✘ $1 — ждали [$3], получили [$2]"; fail=1; fi; }

# блок кончается ВТОРЫМ "    fi": первый закрывает определение hp3
blk="$(awk '/^    v3_preset=/{on=1} on{print} on && /^    fi$/{if(++n==2) exit}' "$DOC")"
case "$blk" in
    *'hp3'*'v3_preset'*) ;;
    *) echo "  ✘ блок проверки 3.0 вырезан не целиком"; exit 1 ;;
esac

# run <пресет в meta> <режим UAPI> — режимы:
#   key    — демон отдал ключ (как настоящий cmd_show с параметрами)
#   nokey  — демон ответил, но параметров нет (реальная строка «не заданы»)
#   dead   — демон не ответил вовсе (нет сокета): пустой вывод
#   nofile — самого awg-uapi.py нет
run() {
    local d; d="$(mktemp -d)"
    mkdir -p "$d/etc" "$d/dest"
    [ -n "$1" ] && printf 'META_PRESET=%s\nMETA_TEMPLATE=web\n' "$1" > "$d/etc/obfuscation3.meta"
    case "$2" in
        key)   printf 'print("awg3: активные параметры AmneziaWG 3.0")\nprint("  header_protection_key = abcd(скрыт)")\n' > "$d/dest/awg-uapi.py" ;;
        nokey) printf 'print("awg3: параметры AmneziaWG 3.0 не заданы (работает как 2.0)")\n' > "$d/dest/awg-uapi.py" ;;
        dead)  printf 'import sys\nsys.exit(1)\n' > "$d/dest/awg-uapi.py" ;;
        nofile) : ;;
    esac
    ( set -uo pipefail
      AWG_DIR="$d/etc"; DEST="$d/dest"; KMOD3=0; IFACE3=awg3
      ok(){   echo "ok|$*";   }
      warn(){ echo "warn|$*"; }
      eval "$blk" ) 2>/dev/null
    rm -rf "$d"
}

echo "── Демон отдал ключ: зелено при любом пресете ──────────────────────────"
chk "medium с ключом"   "$(run medium key)"   "ok|header protection применена (пресет medium)"
chk "low с ключом"      "$(run low key)"      "ok|header protection применена (пресет low)"

echo
echo "── Ключа нет, но пресет его и не обещал: это НЕ поломка ────────────────"
chk "low"    "$(run low nokey)"    "ok|пресет low — без header protection, так и задумано"
chk "router" "$(run router nokey)" "ok|пресет router — без header protection, так и задумано"
echo "  (именно на этом доктор раньше писал «параметры 3.0 не применены»)"

echo
echo "── Ключа нет там, где он должен быть: предупреждаем ────────────────────"
chk "medium"   "$(run medium nokey)"   "warn|пресет medium должен включать header protection, но её нет"
chk "high"     "$(run high nokey)"     "warn|пресет high должен включать header protection, но её нет"
chk "paranoid" "$(run paranoid nokey)" "warn|пресет paranoid должен включать header protection, но её нет"
chk "нет obfuscation3.meta" "$(run '' nokey)" "warn|пресет ? должен включать header protection, но её нет"

echo
echo "── «Спросить не удалось» ≠ «ключа нет» ─────────────────────────────────"
o="$(run medium dead)"
chk "демон молчит — так и сказано" "$(printf '%s' "$o" | head -1)" \
    "warn|awg3: демон не ответил — состояние 3.0 неизвестно"
case "$o" in *"должен включать header protection"*) echo "  ✘ подмешан чужой диагноз"; fail=1 ;;
             *) echo "  ✔ пресет тут ни при чём — про него молчим" ;; esac
o="$(run medium nofile)"
case "$o" in *"нечем спросить демона"*) echo "  ✔ нет awg-uapi.py — сказано прямо" ;;
             *) echo "  ✘ пропажа awg-uapi.py не названа: [$o]"; fail=1 ;; esac
case "$o" in *"должен включать header protection"*) echo "  ✘ и снова чужой диагноз"; fail=1 ;;
             *) echo "  ✔ и без обвинения пресета" ;; esac
echo "  (раньше обе ситуации давали «параметры 3.0 не применены»)"

echo
echo "── Бит +x потерян, но python3 всё равно запускает ──────────────────────"
if printf '%s\n' "$blk" | grep -q '\[ -x "\$DEST'; then
    echo "  ✘ проверка -x осталась — потеря бита даёт ложный диагноз"; fail=1
else
    echo "  ✔ наличие файла проверяется через -f"
fi

echo
echo "── Совет исполним: в нём есть --preset ─────────────────────────────────"
if grep -qF -- '--v3 --preset medium --regenerate --apply' "$DOC"; then
    echo "  ✔ совет для router/low называет новый пресет"
else
    echo "  ✘ совет для router/low не задаёт пресет"; fail=1
fi

echo
bash -n "$DOC" && echo "  ✔ синтаксис" || fail=1
echo
[ "$fail" = 0 ] && echo "═══ ВСЁ ЗЕЛЁНОЕ ═══" || echo "═══ ЕСТЬ ПАДЕНИЯ ═══"
exit $fail
