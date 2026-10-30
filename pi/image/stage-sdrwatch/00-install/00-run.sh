#!/bin/bash -e
# Копіюємо ПЗ у rootfs і запускаємо інсталятор у chroot (без запуску сервісів).
# Теку files/ заповнює workflow .github/workflows/build-pi.yml.
rm -rf "${ROOTFS_DIR}/tmp/sdrwatch-src"
cp -r files "${ROOTFS_DIR}/tmp/sdrwatch-src"
on_chroot << CHROOT
bash /tmp/sdrwatch-src/install.sh --image
rm -rf /tmp/sdrwatch-src
CHROOT
install -m 644 files/image/sdrwatch.txt "${ROOTFS_DIR}/boot/firmware/sdrwatch.txt"
