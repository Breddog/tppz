#!/bin/bash
# Встановлення оновлення, підготовленого сервісом sdrwatch (запускається від root через
# sdrwatch-update.path, коли з'являється /var/lib/sdrwatch/update/request.json).
set -u
D=/var/lib/sdrwatch/update
REQ=$D/request.json
[ -f "$REQ" ] || exit 0
LOG=$D/update.log
: > "$LOG"
exec >>"$LOG" 2>&1

j() { python3 -c "import json,sys;print(json.load(open('$REQ')).get('$1',''))"; }
KIND=$(j kind); FILE=$(j file); SHA=$(j sha256); TAG=$(j tag)
rm -f "$REQ"

status() {  # state message
  python3 - "$1" "$2" "$KIND" "$TAG" <<'PY'
import json, sys, time
state, msg, kind, tag = sys.argv[1:5]
log = open("/var/lib/sdrwatch/update/update.log", errors="replace").read()[-4000:]
json.dump({"state": state, "message": msg, "kind": kind, "tag": tag, "ts": time.time(), "log": log},
          open("/var/lib/sdrwatch/update/status.json", "w"), ensure_ascii=False)
PY
  chown sdrwatch:plugdev "$D/status.json" 2>/dev/null || true
}

fail() { echo "ПОМИЛКА: $1"; status error "$1"; systemctl start sdrwatch; exit 1; }

case "$FILE" in "$D"/*) ;; *) fail "Недопустимий шлях файлу";; esac
[ -f "$FILE" ] || fail "Файл оновлення не знайдено"
echo "$SHA  $FILE" | sha256sum -c - || fail "Контрольна сума не збігається"
status running "Встановлення…"

case "$KIND" in
  pi)
    T=$(mktemp -d)
    tar xzf "$FILE" -C "$T" || fail "Архів пошкоджено"
    [ -x "$T/sdrwatch-pi/install.sh" ] || fail "В архіві немає install.sh"
    [ -n "$TAG" ] && echo "$TAG" > "$T/sdrwatch-pi/BUILD"
    # Інсталятор сам перезапускає сервіс; статус пишемо до перезапуску
    status running "Встановлення ПЗ модуля, сервіс перезапуститься…"
    if bash "$T/sdrwatch-pi/install.sh"; then
      status ok "ПЗ модуля оновлено${TAG:+ до $TAG}"
    else
      fail "Інсталятор завершився з помилкою (див. журнал)"
    fi
    rm -rf "$T"
    ;;
  hackrf)
    command -v hackrf_spiflash >/dev/null || fail "Немає hackrf_spiflash (пакет hackrf)"
    status running "Запис прошивки HackRF… не вимикайте живлення"
    systemctl stop sdrwatch
    sleep 2
    hackrf_spiflash -w "$FILE" || fail "Не вдалося записати прошивку (див. журнал; відновлення — hackrf/README.md)"
    hackrf_spiflash -R || true          # перезавантажити HackRF з новою прошивкою
    sleep 4
    INFO=$(hackrf_info 2>&1 || true)
    echo "$INFO"
    VER=$(echo "$INFO" | grep -m1 "Firmware Version" | cut -d: -f2- | xargs)
    systemctl start sdrwatch
    [ -n "$VER" ] || fail "HackRF не відповідає після прошивки — перепідключіть USB або див. hackrf/README.md"
    status ok "Прошивку HackRF оновлено: $VER"
    ;;
  *) fail "Невідомий тип оновлення";;
esac
