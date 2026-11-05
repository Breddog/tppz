#!/bin/bash
# Сторож мережі SDR Watch.
# Якщо немає інтернету АБО застосунок давно не підключався (немає спільної мережі з телефоном),
# а поруч є точка доступу телефону «sdrdetect» — переводимо Wi-Fi модуля на неї.
# Ethernet при цьому не чіпаємо: кабель і точка доступу можуть працювати одночасно.
set -u
CON=sdrdetect                                   # профіль NetworkManager (див. install.sh)
STAMP=/run/sdrwatch/last_client                 # оновлює sdrwatch при кожному запиті застосунку
CLIENT_TIMEOUT=${CLIENT_TIMEOUT:-180}           # с без застосунку → шукаємо точку доступу
INTERVAL=${INTERVAL:-20}
START=$(date +%s)

log() { echo "netwatch: $*"; }

ssid_of_profile() { nmcli -g 802-11-wireless.ssid connection show "$CON" 2>/dev/null; }

online() {
  ping -c1 -W3 1.1.1.1 >/dev/null 2>&1 || ping -c1 -W3 8.8.8.8 >/dev/null 2>&1
}

client_recent() {
  local last now
  now=$(date +%s)
  if [ -f "$STAMP" ]; then last=$(cat "$STAMP" 2>/dev/null || echo 0); else last=$START; fi
  [ $((now - last)) -lt "$CLIENT_TIMEOUT" ]
}

on_hotspot() { nmcli -t -f NAME connection show --active 2>/dev/null | grep -qx "$CON"; }

hotspot_visible() {
  local ssid; ssid=$(ssid_of_profile)
  [ -n "$ssid" ] && nmcli -t -f SSID device wifi list --rescan yes 2>/dev/null | grep -qxF "$ssid"
}

while true; do
  if nmcli -t -f DEVICE,TYPE device 2>/dev/null | grep -q ":wifi$" && ! on_hotspot; then
    if ! online || ! client_recent; then
      if hotspot_visible; then
        log "немає інтернету/застосунку — підключаюсь до точки доступу $(ssid_of_profile)"
        nmcli connection up "$CON" >/dev/null 2>&1 && log "підключено" || log "не вдалося"
      fi
    fi
  fi
  sleep "$INTERVAL"
done
