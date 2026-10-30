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
apt-get update
apt-get install -y --no-install-recommends python3-venv python3-dev python3-numpy python3-pil \
    python3-soapysdr soapysdr-tools soapysdr-module-hackrf soapysdr-module-rtlsdr soapysdr-module-airspy \
    hackrf rtl-sdr network-manager ca-certificates
apt-get install -y --no-install-recommends python3-lgpio python3-gpiozero || true

echo "==> Користувач і теки"
id sdrwatch >/dev/null 2>&1 || useradd -r -s /usr/sbin/nologin -G plugdev sdrwatch
getent group gpio >/dev/null && usermod -aG gpio sdrwatch || true
mkdir -p /opt/sdrwatch /etc/sdrwatch /var/lib/sdrwatch
rm -rf /opt/sdrwatch/sdrwatch
cp -r "$SRC/sdrwatch" /opt/sdrwatch/
cp "$SRC/requirements.txt" /opt/sdrwatch/
install -m 755 "$SRC/image/sdrwatch-firstboot.sh" /usr/local/sbin/sdrwatch-firstboot
chown -R sdrwatch:plugdev /var/lib/sdrwatch /etc/sdrwatch

echo "==> Python-оточення (з доступом до системного SoapySDR і numpy)"
[ -x /opt/sdrwatch/venv/bin/python ] || python3 -m venv --system-site-packages /opt/sdrwatch/venv
/opt/sdrwatch/venv/bin/pip install -q --upgrade pip
/opt/sdrwatch/venv/bin/pip install -q -r /opt/sdrwatch/requirements.txt
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

echo "==> Вимкнути власний Wi-Fi/Bluetooth? (вони світять у 2.4/5 ГГц — див. docs/HARDWARE.md)"
echo "    За замовчуванням лишаються ввімкненими, бо через Wi-Fi модуль може бути на зв'язку."

echo "==> Сервіси"
install -m 644 "$SRC/systemd/sdrwatch.service" /etc/systemd/system/sdrwatch.service
install -m 644 "$SRC/image/sdrwatch-firstboot.service" /etc/systemd/system/sdrwatch-firstboot.service
systemctl enable sdrwatch.service sdrwatch-firstboot.service

if [ "$IMAGE" = 0 ]; then
  udevadm control --reload-rules && udevadm trigger || true
  systemctl daemon-reload
  systemctl restart sdrwatch
  sleep 4
  sdrwatch pair || true
  IP=$(hostname -I | awk '{print $1}')
  echo
  echo "Готово. Сторінка модуля: http://$IP:8080  · журнал: journalctl -u sdrwatch -f"
fi
