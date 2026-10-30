#!/usr/bin/env bash
# Встановлення SDR Watch на Raspberry Pi OS (Bookworm, 64-bit). Запуск: sudo ./install.sh
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "Запустіть через sudo"; exit 1; }
SRC="$(cd "$(dirname "$0")" && pwd)"

echo "==> Системні пакети (SoapySDR + драйвери HackRF / RTL-SDR / Airspy)"
apt-get update
apt-get install -y python3-venv python3-dev python3-numpy python3-soapysdr soapysdr-tools \
    soapysdr-module-hackrf soapysdr-module-rtlsdr soapysdr-module-airspy hackrf rtl-sdr \
    libjpeg-dev zlib1g-dev

echo "==> Користувач і теки"
id sdrwatch >/dev/null 2>&1 || useradd -r -s /usr/sbin/nologin -G plugdev sdrwatch
mkdir -p /opt/sdrwatch /etc/sdrwatch /var/lib/sdrwatch
rsync -a --delete --exclude tests "$SRC/sdrwatch" /opt/sdrwatch/
chown -R sdrwatch:plugdev /var/lib/sdrwatch /etc/sdrwatch

echo "==> Python-оточення (з доступом до системного SoapySDR)"
python3 -m venv --system-site-packages /opt/sdrwatch/venv
/opt/sdrwatch/venv/bin/pip install -q -r "$SRC/requirements.txt"

echo "==> Правила udev (доступ до SDR без root) і вимкнення DVB-драйвера RTL-SDR"
cat > /etc/udev/rules.d/52-sdrwatch.rules <<'R'
SUBSYSTEM=="usb", ATTR{idVendor}=="1d50", ATTR{idProduct}=="6089", MODE="0660", GROUP="plugdev"
SUBSYSTEM=="usb", ATTR{idVendor}=="0bda", ATTR{idProduct}=="2838", MODE="0660", GROUP="plugdev"
SUBSYSTEM=="usb", ATTR{idVendor}=="1d50", ATTR{idProduct}=="60a1", MODE="0660", GROUP="plugdev"
R
echo "blacklist dvb_usb_rtl28xxu" > /etc/modprobe.d/blacklist-rtlsdr.conf
udevadm control --reload-rules && udevadm trigger

echo "==> Сервіс"
install -m 644 "$SRC/systemd/sdrwatch.service" /etc/systemd/system/sdrwatch.service
systemctl daemon-reload
systemctl enable --now sdrwatch
sleep 3
sudo -u sdrwatch SDRWATCH_CONFIG=/etc/sdrwatch/config.json /opt/sdrwatch/venv/bin/python -m sdrwatch pair || true
echo "Готово. Журнал: journalctl -u sdrwatch -f"
