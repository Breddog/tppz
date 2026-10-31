# Прошивка HackRF One для SDR Watch

Збирається в GitHub Actions (`.github/workflows/build-hackrf.yml`) з **офіційного** коду
[greatscottgadgets/hackrf](https://github.com/greatscottgadgets/hackrf) (тег у `UPSTREAM_TAG`), **без змін** —
це та сама стандартна прошивка, що на офіційному сайті. Готовий файл — у релізі `hackrf-N`:
`hackrf_one_usb.bin` + `.sha256`.

Навіщо вона тут: щоб HackRF можна було **оновити прямо з застосунку** (модуль → «Керування» → «Оновлення»),
у т.ч. віддалено, не знімаючи пристрій. Передавання (TX) у прошивці увімкнене — воно потрібне для
**тестового генератора** (перевірка приймання інших пристроїв на заданій частоті, див. README проєкту).

## Оновлення

- **З застосунку:** модуль → «Керування» → «Оновлення» → «Прошити HackRF». Модуль зупиняє сканування,
  записує прошивку у флеш HackRF, перезавантажує його й перевіряє версію.
- **Вручну:** `sudo systemctl stop sdrwatch && hackrf_spiflash -w hackrf_one_usb.bin -R && sudo systemctl start sdrwatch`.

## Відновлення (якщо HackRF не визначається)

Прошивку «намертво» записати не можна: завантажувач DFU у ПЗП мікроконтролера.
1. Тримаючи кнопку **DFU**, підключіть HackRF до USB.
2. `sudo apt install dfu-util && dfu-util --device 1fc9:000c --alt 0 --download hackrf_one_usb.dfu`
   (файл `.dfu` з офіційного релізу HackRF) — HackRF тимчасово запуститься з RAM.
3. `hackrf_spiflash -w hackrf_one_usb.bin -R`.
