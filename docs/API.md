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
- `POST /api/control/video_autoscan` `{"on", "bands", "circular": true, "dwell_s": 4}` — автоскан відео.
  `circular` — іти по колу: знайдене показати `dwell_s` секунд і йти далі (знайдене копиться в
  `autoscan.found`); `false` — зупинитися на першій картинці.

## Пошук у мережі

UDP-broadcast `SDRWATCH_DISCOVER` на порт `47800` → відповідь `{"app":"sdrwatch","name","id","port"}` (без токена).
Якщо встановлено `zeroconf`, модуль також оголошується як `_sdrwatch._tcp` (mDNS).
