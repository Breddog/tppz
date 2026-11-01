# API модуля SDR Watch

Базова адреса: `http://<raspberry>:8080`. Авторизація — `Authorization: Bearer <token>` або `?token=<token>`
(для WebSocket і зображень). Токен генерується при першому запуску й показується командою `sdrwatch pair`.

## Стан і сигнали

| Метод | Шлях | Опис |
|---|---|---|
| GET | `/api/ping` | Без авторизації: `{app, name, id, version}` |
| GET | `/api/status` | Режим, підсилення, діапазони, статистика, температура CPU, заповненість сховища |
| GET | `/api/signals` | Активні та нещодавно втрачені сигнали |
| GET | `/api/signals/{id}` | Сигнал + історія RSSI |
| GET | `/api/spectrum` | Останні кадри спектра всіх діапазонів |
| GET | `/api/channels` | Сітки каналів і діапазони лінків |

Об'єкт сигналу:
```json
{
  "id": "s12", "freq_hz": 5877700000, "bandwidth_hz": 8700000, "state": "confirmed",
  "rssi_dbm": -65.0, "snr_db": 29.6, "presence": 0.98, "hopping": false,
  "class": {"code": "analog_video_inverted", "label": "Аналогове відео (інвертоване)", "subtype": "PAL",
            "confidence": 0.99, "priority": 2, "can_show_video": true, "hints": ["..."]},
  "channel": {"band": "F", "name": "F8", "freq_hz": 5880000000, "offset_hz": -2300000},
  "video": {"standard": "PAL", "inverted": true, "scrambled": null, "sync_score": 0.997, "snr_db": 32.9},
  "distance": {"min_m": 32, "likely_m": 125, "max_m": 235, "trend": "steady", "text": "≈125 м (32 м–235 м)"},
  "hint": "5877.7 МГц (F8) — Аналогове відео (інвертоване): PAL — ≈125 м (32 м–235 м) — сигнал сильний"
}
```
Коди класів: `analog_video`, `analog_video_inverted`, `analog_video_scrambled`, `analog_video_weak`,
`digital_video`, `control_link`, `telemetry`, `wifi`, `wideband_unknown`, `carrier`, `unknown`.

## Історія (кільцевий запис)

| Метод | Шлях | Опис |
|---|---|---|
| GET | `/api/events?since_id=&before_id=&limit=&min_priority=&class_code=&ts_from=&ts_to=` | Події `new` / `lost` / `reacquired` / `changed` |
| GET | `/api/events/{id}` | Подія + медіа |
| GET | `/api/media/{file_id}` | Кадр (JPEG) або метадані кліпу |
| GET | `/api/clips` | Список відеозаписів |
| GET | `/api/clips/{file_id}/frame/{n}` | Кадр кліпу |
| GET | `/api/waterfall/ranges` | Діапазони з архівом водоспаду |
| GET | `/api/waterfall?range_name=&ts_from=&ts_to=&max_rows=` | Рядки водоспаду (дБм) |
| GET | `/api/storage` | Використання місця |
| POST | `/api/storage/clear` | Очистити історію |

## Керування

| Метод | Шлях | Тіло |
|---|---|---|
| POST | `/api/control/scan` | — |
| POST | `/api/control/pause` | — |
| POST | `/api/control/watch` | `{"freq_hz": 5800e6}` або `{"track_id": "s12"}` |
| POST | `/api/control/video` | `{"invert": true/false, "invert_auto": true, "auto_contrast", "descramble", "afc"}` |
| POST | `/api/control/record` | `{"on": true}` |
| POST | `/api/control/gain` | `{"lna": 32, "vga": 30, "amp": false, "auto": true}` |
| POST | `/api/ranges/toggle` | `{"index": 4, "enabled": true}` |
| POST | `/api/calibrate` | `{"freq_hz": 5800e6, "distance_m": 10, "eirp_dbm": 14}` |
| POST | `/api/control/restart` | — |
| GET / PUT | `/api/config` | Частковий JSON конфігу (крім секції `api`) |

## WebSocket

- `/ws/live?token=` — JSON-повідомлення:
  - `spectrum` — `{range, name, f_start, f_stop, bins[1024], floor[1024], threshold_db, ts}` (дБм);
  - `signals` — список сигналів після кожного повного проходу;
  - `event` — `{kind, event_id, track}`;
  - `watch` — стан режиму стеження (частота, канал, параметри відео, запис, пошук);
  - клієнт може надіслати `{"range": N}`, щоб отримувати спектр лише одного діапазону.
- `/ws/baseband?token=&quality=economy|normal|detail` — **основний відеопотік**: «сирий» відеосигнал
  після ЧМ-детектора (одне поле ≈20,5 мс на пакет, до 25 пакетів/с), декодує телефон.
  Пакет: 32-байтний заголовок `<4sBBHdfffI` — `b"SDRB"`, версія 1, біт на відлік (8 або 4),
  прапорці (bit0 — модуль бачить синхронізацію, bit1 — інверсія), частота (Гц), частота відліків,
  `lo`/`hi` (Гц девіації, що відповідають коду 0 і максимальному), кількість відліків; далі відліки.
  Якість: economy ≈3 Мвідл/с × 4 біти (~6 Мбіт/с), normal ≈4 Мвідл/с × 8 біт (~16 Мбіт/с),
  detail ≈6,7 Мвідл/с × 8 біт (~27 Мбіт/с). Див. `pi/sdrwatch/dsp/baseband.py`.
- `/ws/video?token=` — бінарні JPEG-кадри, декодовані на модулі (для веб-сторінки й старих застосунків).
- `/ws/live?token=&binary=1` — з `binary=1` кадри спектра бінарні: 40-байтний заголовок `<4sBBhdddfI`
  (`b"SPEC"`, версія, прапорці: bit0 — збільшена ділянка, діапазон, f_start, f_stop, ts, поріг, n),
  далі n×int16 рівні (дБ×10) і n×int16 шум. Клієнт може надіслати `{"range": N, "fps": 15,
  "zoom": {"range": N, "lo": Гц, "hi": Гц}}` — модуль додатково шле збільшену ділянку з повною деталізацією.
- `/ws/audioiq?token=` — вирізаний звуковий канал для демодуляції на телефоні: 36-байтний заголовок
  `<4sBBHdffffI` (`b"SDRA"`, версія, модуляція 0 nfm/1 wfm/2 am, прапорці bit0 — шумодав відкритий,
  частота, частота відліків 48 000 або 240 000, масштаб, рівень дБ, шумодав дБ, n), далі n пар int16 I/Q.
- Звук — сканер: `POST /api/audio/start` приймає також `scan_freqs` (список збережених частот),
  `hold_s` (затримка після кінця передачі), `lockout` (заблоковані частоти; `[]` — зняти всі).
  `POST /api/audio/skip` — заблокувати поточну частоту й шукати далі; `POST /api/audio/resume?unlock=Гц` —
  продовжити пошук / зняти блокування. Стан сканера (`audio.scan`): знайдене (частота, рівень, скільки разів,
  коли), блокування, кількість кіл. Канал рахується лише як місцевий максимум (сусідні «бризки» відкидаються).
- `/ws/audioiq`: модуль лише переносить канал на 0 Гц і проріджує підсумовуванням (як rtl_fm) —
  точний фільтр каналу, демодуляцію, шумодав і гучність робить телефон.
- `GET /api/health` — стан модуля: температура/навантаження/частота ЦП, просідання живлення
  (`vcgencmd get_throttled`), пам'ять, флешка, попередження + історія за годину (кожні 5 с).
  Ті самі дані щоп'ять секунд приходять у `/ws/live` як `{"type": "health", ...}`.
- `POST /api/time` `{"ts", "lat"?, "lon"?}` — час і координати з телефона (у Pi немає годинника з батарейкою).
- `POST /api/control/video_autoscan` `{"on", "mode": "grids|full|range", "bands", "start_hz", "stop_hz",
  "circular": true, "dwell_s": 3, "audio": true}` — круговий автоскан. `grids` — канали сіток, `full` — весь
  діапазон SDR, `range` — від `start_hz` до `stop_hz`; іде по порядку, коло за колом. Повний діапазон —
  швидкий спектр вікнами ~16 МГц + перевірка синхроімпульсів на широких сигналах; `audio` — ще й вузькі
  сигнали < 1.3 ГГц (рації). Знайдене — у `watch.autoscan.found` (`type`: video / audio).
  `circular` — іти по колу: знайдене показати `dwell_s` секунд і йти далі (знайдене копиться в
  `autoscan.found`); `false` — зупинитися на першій картинці.

## Пошук у мережі

UDP-broadcast `SDRWATCH_DISCOVER` на порт `47800` → відповідь `{"app":"sdrwatch","name","id","port"}` (без токена).
Якщо встановлено `zeroconf`, модуль також оголошується як `_sdrwatch._tcp` (mDNS).
