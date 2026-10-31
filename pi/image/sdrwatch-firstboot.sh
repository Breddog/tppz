#!/bin/bash
# Застосовує налаштування з /boot/firmware/sdrwatch.txt (файл можна відредагувати на будь-якому
# комп'ютері — це FAT-розділ SD-карти). Після застосування файл перейменовується, а паролі стираються.
set -u
F=/boot/firmware/sdrwatch.txt
[ -f "$F" ] || exit 0
get() { grep -E "^$1=" "$F" | tail -1 | cut -d= -f2- | sed -e 's/^"//' -e 's/"$//' -e 's/\r$//'; }

NAME=$(get NAME); SSID=$(get WIFI_SSID); PSK=$(get WIFI_PASSWORD); COUNTRY=$(get WIFI_COUNTRY)
SSHPW=$(get SSH_PASSWORD); TZ=$(get TIMEZONE); QUOTA=$(get QUOTA_MB); NOWIFI=$(get DISABLE_PI_WIFI)
HS_SSID=$(get HOTSPOT_SSID); HS_PSK=$(get HOTSPOT_PASSWORD)

[ -n "$COUNTRY" ] && raspi-config nonint do_wifi_country "$COUNTRY" >/dev/null 2>&1 || true
rfkill unblock wifi 2>/dev/null || true
if [ -n "$SSID" ]; then
  nmcli connection delete sdrwatch-wifi >/dev/null 2>&1 || true
  if [ -n "$PSK" ]; then
    nmcli connection add type wifi con-name sdrwatch-wifi ifname wlan0 ssid "$SSID" \
      wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$PSK" connection.autoconnect yes connection.autoconnect-priority 10
  else
    nmcli connection add type wifi con-name sdrwatch-wifi ifname wlan0 ssid "$SSID" \
      connection.autoconnect yes connection.autoconnect-priority 10
  fi
  nmcli connection up sdrwatch-wifi || true
fi
# Точка доступу телефону (резервна мережа): змінити назву/пароль, якщо задано
if [ -n "$HS_SSID" ]; then nmcli connection modify sdrdetect 802-11-wireless.ssid "$HS_SSID" || true; fi
if [ -n "$HS_PSK" ] && [ "$HS_PSK" != "(застосовано)" ]; then
  nmcli connection modify sdrdetect wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$HS_PSK" || true
fi

[ -n "$TZ" ] && timedatectl set-timezone "$TZ" 2>/dev/null || true

if [ -n "$SSHPW" ]; then
  echo "sdr:$SSHPW" | chpasswd
  systemctl enable --now ssh 2>/dev/null || true
fi

if [ "$NOWIFI" = "1" ]; then
  # Увага: без Wi-Fi не працюватиме й резервне підключення до точки доступу телефону
  # Модуль у мережі через Ethernet — вимикаємо власні передавачі Pi (завади у 2.4/5 ГГц)
  CFG=/boot/firmware/config.txt
  grep -q "disable-wifi" $CFG || printf "dtoverlay=disable-wifi\ndtoverlay=disable-bt\n" >> $CFG
fi

if [ -n "$NAME$QUOTA" ]; then
  /opt/sdrwatch/venv/bin/python - "$NAME" "$QUOTA" <<'PY'
import json, os, sys
p = "/etc/sdrwatch/config.json"
c = json.load(open(p)) if os.path.exists(p) else {}
if sys.argv[1]:
    c["name"] = sys.argv[1]
if sys.argv[2]:
    c.setdefault("storage", {})["quota_mb"] = int(sys.argv[2])
json.dump(c, open(p, "w"), ensure_ascii=False, indent=2)
PY
  chown sdrwatch:plugdev /etc/sdrwatch/config.json
fi

# Прибрати паролі з FAT-розділу
sed -i -e 's/^WIFI_PASSWORD=.*/WIFI_PASSWORD=(застосовано)/' -e 's/^SSH_PASSWORD=.*/SSH_PASSWORD=(застосовано)/' -e 's/^HOTSPOT_PASSWORD=.*/HOTSPOT_PASSWORD=(застосовано)/' "$F"
mv "$F" /boot/firmware/sdrwatch.applied.txt
