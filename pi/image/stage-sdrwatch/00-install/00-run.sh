#!/bin/bash -e
# Копіюємо ПЗ у rootfs і запускаємо інсталятор у chroot (без запуску сервісів).
# Теку files/ заповнює workflow .github/workflows/build-pi.yml.
# (/tmp у chroot pi-gen може бути окремим tmpfs, тому копіюємо в /opt)
SRC_DIR="${ROOTFS_DIR}/opt/sdrwatch-src"
rm -rf "${SRC_DIR}"
mkdir -p "${SRC_DIR}"
cp -r files/. "${SRC_DIR}/"
ls -la "${SRC_DIR}"
on_chroot << CHROOT
bash /opt/sdrwatch-src/install.sh --image
rm -rf /opt/sdrwatch-src
CHROOT
install -m 644 files/image/sdrwatch.txt "${ROOTFS_DIR}/boot/firmware/sdrwatch.txt"
