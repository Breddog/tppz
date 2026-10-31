# Прошивка HackRF One — редакція SDR Watch

Збирається в GitHub Actions (`.github/workflows/build-hackrf.yml`) з **офіційного** коду
[greatscottgadgets/hackrf](https://github.com/greatscottgadgets/hackrf) (тег у `UPSTREAM_TAG`) з патчами з `patches/`.
Готовий файл — у релізі `hackrf-N`: `hackrf_one_usb-sdrwatch.bin` + `.sha256`.

## Що змінено під задачі виявлення

| Патч | Навіщо |
|---|---|
| `0001-sdrwatch-rx-only.patch` | **Лише приймання.** Прошивка відхиляє перемикання в режим передачі (TX). Модуль фізично не може випромінювати навіть через помилку ПЗ чи злам — не демаскує позицію і не створює завад. Режими RX і апаратного огляду (sweep) працюють як в оригіналі |

Решта — як в офіційному релізі: апаратний режим швидкого огляду (sweep, до ~8 ГГц/с), підтримка всіх ревізій
HackRF One (r1–r10), вбудований CPLD-образ. Рядок версії: `<офіційна версія>-sdrwatch-rx`.

## Оновлення

- **З застосунку** (локально, через точку доступу або віддалено через Tailscale): модуль → «Керування» → «Оновлення» →
  «Прошити HackRF». Модуль зупиняє сканування, записує прошивку у флеш HackRF, перезавантажує його й перевіряє версію.
- **Вручну на Raspberry Pi:** `sudo systemctl stop sdrwatch && hackrf_spiflash -w hackrf_one_usb-sdrwatch.bin -R && sudo systemctl start sdrwatch`.
- **Повернути офіційну прошивку:** те саме з файлом `hackrf_one_usb.bin` з офіційного релізу HackRF.

## Якщо щось пішло не так (відновлення)

Записати прошивку «намертво» неможливо: завантажувач DFU у ПЗП мікроконтролера. Якщо HackRF не визначається:
1. Тримаючи кнопку **DFU**, підключіть HackRF до USB (або натисніть RESET, тримаючи DFU).
2. На Pi: `sudo apt install dfu-util` і `dfu-util --device 1fc9:000c --alt 0 --download hackrf_one_usb.dfu`
   (файл `.dfu` з офіційного релізу HackRF) — HackRF тимчасово запуститься з RAM.
3. Запишіть прошивку у флеш: `hackrf_spiflash -w hackrf_one_usb-sdrwatch.bin -R`.
