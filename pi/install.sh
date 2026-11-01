#!/usr/bin/env bash
# Встановлення SDR Watch на Raspberry Pi OS (64-bit, Bookworm/Trixie).
#   sudo ./install.sh          — на працюючому Raspberry Pi
#   sudo ./install.sh --image  — усередині збірки образу (без запуску сервісів)
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "Запустіть через sudo"; exit 1; }
SRC="$(cd "$(dirname "$0")" && pwd)"
IMAGE=0
[ "${1:-}" = "--image" ] && IMAGE=1

echo "==> Системні пакети (SoapySDR + драйвери HackRF / RTL-SDR / Airspy)"
export DEBIAN_FRONTEND=noninteractive
PKGS="python3-venv python3-dev python3-numpy python3-pil python3-soapysdr soapysdr-tools soapysdr-module-hackrf
      soapysdr-module-rtlsdr soapysdr-module-airspy hackrf rtl-sdr network-manager ca-certificates"
# Оновлення з телефону може прийти, коли в модуля немає інтернету — тоді apt не потрібен
if dpkg -s $PKGS >/dev/null 2>&1; then
  echo "    усі пакети вже встановлено"
else
  apt-get update
  apt-get install -y --no-install-recommends $PKGS
  apt-get install -y --no-install-recommends python3-lgpio python3-gpiozero || true
fi

echo "==> Користувач і теки"
id sdrwatch >/dev/null 2>&1 || useradd -r -s /usr/sbin/nologin -G plugdev sdrwatch
getent group gpio >/dev/null && usermod -aG gpio sdrwatch || true
usermod -aG netdev sdrwatch 2>/dev/null || true

echo "==> Дозвіл виставляти годинник за часом телефона (у Pi немає годинника з батарейкою)"
cat > /etc/sudoers.d/sdrwatch-time <<'S'
sdrwatch ALL=(root) NOPASSWD: /usr/bin/date -u -s @*
S
chmod 440 /etc/sudoers.d/sdrwatch-time

echo "==> Дозвіл керувати Wi-Fi/мережею з застосунку (polkit для сервісу)"
mkdir -p /etc/polkit-1/rules.d
cat > /etc/polkit-1/rules.d/50-sdrwatch-nm.rules <<'P'
// SDR Watch: користувач сервісу може керувати Wi-Fi через NetworkManager
polkit.addRule(function(action, subject) {
  if (subject.user == "sdrwatch" &&
      action.id.indexOf("org.freedesktop.NetworkManager.") === 0) {
    return polkit.Result.YES;
  }
});
P
mkdir -p /opt/sdrwatch /etc/sdrwatch /var/lib/sdrwatch
rm -rf /opt/sdrwatch/sdrwatch
cp -r "$SRC/sdrwatch" /opt/sdrwatch/
cp "$SRC/requirements.txt" /opt/sdrwatch/
install -m 755 "$SRC/image/sdrwatch-firstboot.sh" /usr/local/sbin/sdrwatch-firstboot
install -m 755 "$SRC/image/sdrwatch-netwatch.sh" /usr/local/sbin/sdrwatch-netwatch
install -m 755 "$SRC/image/sdrwatch-update.sh" /usr/local/sbin/sdrwatch-update
[ -f "$SRC/BUILD" ] && install -m 644 "$SRC/BUILD" /opt/sdrwatch/BUILD
mkdir -p /var/lib/sdrwatch/update
chown -R sdrwatch:plugdev /var/lib/sdrwatch /etc/sdrwatch

echo "==> Python-оточення (з доступом до системного SoapySDR і numpy)"
[ -x /opt/sdrwatch/venv/bin/python ] || python3 -m venv --system-site-packages /opt/sdrwatch/venv
if ! { /opt/sdrwatch/venv/bin/pip install -q --upgrade pip && \
       /opt/sdrwatch/venv/bin/pip install -q -r /opt/sdrwatch/requirements.txt; }; then
  # Без інтернету: продовжуємо, якщо потрібні модулі вже є
  /opt/sdrwatch/venv/bin/python -c "import fastapi, uvicorn, numpy" \
    && echo "    pip недоступний, використовую вже встановлені бібліотеки" \
    || { echo "Немає інтернету й бібліотек Python — підключіть модуль до інтернету"; exit 1; }
fi
cat > /usr/local/bin/sdrwatch <<'B'
#!/bin/sh
exec sudo -u sdrwatch SDRWATCH_CONFIG=/etc/sdrwatch/config.json /opt/sdrwatch/venv/bin/python -m sdrwatch "$@"
B
chmod 755 /usr/local/bin/sdrwatch

echo "==> udev (доступ до SDR без root), вимкнення DVB-драйвера RTL-SDR"
cat > /etc/udev/rules.d/52-sdrwatch.rules <<'R'
SUBSYSTEM=="usb", ATTR{idVendor}=="1d50", ATTR{idProduct}=="6089", MODE="0660", GROUP="plugdev"
SUBSYSTEM=="usb", ATTR{idVendor}=="1d50", ATTR{idProduct}=="cc15", MODE="0660", GROUP="plugdev"
SUBSYSTEM=="usb", ATTR{idVendor}=="0bda", ATTR{idProduct}=="2838", MODE="0660", GROUP="plugdev"
SUBSYSTEM=="usb", ATTR{idVendor}=="1d50", ATTR{idProduct}=="60a1", MODE="0660", GROUP="plugdev"
SUBSYSTEM=="usb", ATTR{idVendor}=="2cf0", ATTR{idProduct}=="5250", MODE="0660", GROUP="plugdev"
R
echo "blacklist dvb_usb_rtl28xxu" > /etc/modprobe.d/blacklist-rtlsdr.conf

echo "==> Резервна мережа: точка доступу телефону sdrdetect / 12345678"
# Профіль пишемо файлом (працює й у chroot збірки образу, де NetworkManager не запущено).
# Пріоритет нижчий за звичайний Wi-Fi: вдома модуль іде у вашу мережу, у полі — на телефон.
mkdir -p /etc/NetworkManager/system-connections
if [ ! -f /etc/NetworkManager/system-connections/sdrdetect.nmconnection ]; then
  cat > /etc/NetworkManager/system-connections/sdrdetect.nmconnection <<'N'
[connection]
id=sdrdetect
type=wifi
autoconnect=true
autoconnect-priority=-10
autoconnect-retries=0

[wifi]
mode=infrastructure
ssid=sdrdetect

[wifi-security]
key-mgmt=wpa-psk
psk=12345678

[ipv4]
method=auto

[ipv6]
method=auto
N
  chmod 600 /etc/NetworkManager/system-connections/sdrdetect.nmconnection
fi
[ "$IMAGE" = 0 ] && nmcli connection reload 2>/dev/null || true

echo "==> Вимкнути власний Wi-Fi/Bluetooth? (вони світять у 2.4/5 ГГц — див. docs/HARDWARE.md)"
echo "    За замовчуванням лишаються ввімкненими, бо через Wi-Fi модуль може бути на зв'язку."

echo "==> Сервіси"
install -m 644 "$SRC/systemd/sdrwatch.service" /etc/systemd/system/sdrwatch.service
install -m 644 "$SRC/image/sdrwatch-firstboot.service" /etc/systemd/system/sdrwatch-firstboot.service
install -m 644 "$SRC/image/sdrwatch-netwatch.service" /etc/systemd/system/sdrwatch-netwatch.service
install -m 644 "$SRC/image/sdrwatch-update.service" /etc/systemd/system/sdrwatch-update.service
install -m 644 "$SRC/image/sdrwatch-update.path" /etc/systemd/system/sdrwatch-update.path
chown -R sdrwatch:plugdev /var/lib/sdrwatch
systemctl enable sdrwatch.service sdrwatch-firstboot.service sdrwatch-netwatch.service sdrwatch-update.path

if [ "$IMAGE" = 0 ]; then
  udevadm control --reload-rules && udevadm trigger || true
  systemctl daemon-reload
  systemctl restart sdrwatch sdrwatch-netwatch
  systemctl start sdrwatch-update.path
  sleep 4
  sdrwatch pair || true
  IP=$(hostname -I | awk '{print $1}')
  echo
  echo "Готово. Сторінка модуля: http://$IP:8080  · журнал: journalctl -u sdrwatch -f"
fi
