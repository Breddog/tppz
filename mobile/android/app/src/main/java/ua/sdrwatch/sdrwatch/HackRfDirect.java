package ua.sdrwatch.sdrwatch;

import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.hardware.usb.UsbConstants;
import android.hardware.usb.UsbDevice;
import android.hardware.usb.UsbDeviceConnection;
import android.hardware.usb.UsbEndpoint;
import android.hardware.usb.UsbInterface;
import android.hardware.usb.UsbManager;
import android.hardware.usb.UsbRequest;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.Map;

import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.EventChannel;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

/**
 * HackRF One напряму через USB OTG — без Raspberry Pi.
 *
 * Власний мінімальний драйвер поверх Android USB Host API (ті самі запити, що libhackrf):
 * частота дискретизації, смуговий фільтр, частота, LNA/VGA/AMP, режим приймання і потік
 * int8 I/Q з bulk-кінцевої точки 0x81. Обробка — DirectDsp (як на модулі), результат — пакети SDRB
 * у EventChannel «sdrwatch/hackrf/data»: 'B'+SDRB (відео), 'S'+спектр, 'E'+текст помилки.
 */
public final class HackRfDirect implements MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private static final int VID = 0x1d50;
    private static final int[] PIDS = {0x6089 /* HackRF One */, 0x604b /* Jawbreaker */, 0xcc15 /* rad1o */};
    private static final double FIELD_S = 0.0205;

    // Запити до прошивки HackRF (як у libhackrf)
    private static final int REQ_SET_TRANSCEIVER_MODE = 1;
    private static final int REQ_SAMPLE_RATE_SET = 6;
    private static final int REQ_BASEBAND_FILTER_SET = 7;
    private static final int REQ_BOARD_ID_READ = 14;
    private static final int REQ_VERSION_STRING_READ = 15;
    private static final int REQ_SET_FREQ = 16;
    private static final int REQ_AMP_ENABLE = 17;
    private static final int REQ_SET_LNA_GAIN = 19;
    private static final int REQ_SET_VGA_GAIN = 20;
    private static final int[] FILTERS = {1750000, 2500000, 3500000, 5000000, 5500000, 6000000, 7000000, 8000000,
            9000000, 10000000, 12000000, 14000000, 15000000, 20000000, 24000000, 28000000};

    private final Context ctx;
    private final UsbManager usb;
    private final Handler main = new Handler(Looper.getMainLooper());
    private EventChannel.EventSink sink;

    private UsbDeviceConnection conn;
    private UsbInterface iface;
    private UsbEndpoint epIn;
    private volatile boolean running;
    private Thread rxThread, dspThread;

    private volatile double rate = 20e6;
    private volatile double freqHz = 5.8e9;
    private volatile boolean color = true;
    private volatile double fsc = DirectDsp.FSC_PAL;
    private volatile double targetFs = 4e6;
    private volatile int maxFps = 25;
    private volatile boolean spectrumEveryField = false;
    private volatile long skipBytes = 0;
    private volatile int retuneGen = 0;

    private final Object lock = new Object();
    private byte[] ready;          // одне поле, що чекає обробки (новіше замінює старіше)
    private double readyFreq;
    private int fields, dropped;
    private long usbBytes;
    private long statsT = System.currentTimeMillis();
    private String board = "", version = "", lastError = null;

    public HackRfDirect(Context ctx, BinaryMessenger messenger) {
        this.ctx = ctx.getApplicationContext();
        this.usb = (UsbManager) ctx.getSystemService(Context.USB_SERVICE);
        new MethodChannel(messenger, "sdrwatch/hackrf").setMethodCallHandler(this);
        new EventChannel(messenger, "sdrwatch/hackrf/data").setStreamHandler(this);
    }

    @Override
    public void onListen(Object args, EventChannel.EventSink events) {
        sink = events;
    }

    @Override
    public void onCancel(Object args) {
        sink = null;
    }

    private UsbDevice find() {
        if (usb == null) return null;
        for (UsbDevice d : usb.getDeviceList().values()) {
            if (d.getVendorId() != VID) continue;
            for (int p : PIDS) if (d.getProductId() == p) return d;
        }
        return null;
    }

    @Override
    public void onMethodCall(MethodCall call, MethodChannel.Result result) {
        try {
            switch (call.method) {
                case "available": {
                    UsbDevice d = find();
                    result.success(d != null);
                    break;
                }
                case "open": {
                    Number r = call.argument("rate");
                    if (r != null) rate = r.doubleValue();
                    open(result);
                    break;
                }
                case "close":
                    close();
                    result.success(true);
                    break;
                case "tune": {
                    Number hz = call.argument("hz");
                    tune(hz.doubleValue());
                    result.success(true);
                    break;
                }
                case "gain": {
                    Number lna = call.argument("lna"), vga = call.argument("vga");
                    Boolean amp = call.argument("amp");
                    setGain(lna.intValue(), vga.intValue(), amp != null && amp);
                    result.success(true);
                    break;
                }
                case "config": {
                    Boolean c = call.argument("color");
                    if (c != null) color = c;
                    Number f = call.argument("fsc");
                    if (f != null) fsc = f.doubleValue();
                    Number t = call.argument("target_fs");
                    if (t != null) targetFs = t.doubleValue();
                    Number fps = call.argument("max_fps");
                    if (fps != null) maxFps = Math.max(1, fps.intValue());
                    Boolean se = call.argument("spectrum_every_field");
                    if (se != null) spectrumEveryField = se;
                    result.success(true);
                    break;
                }
                case "stats":
                    result.success(stats());
                    break;
                default:
                    result.notImplemented();
            }
        } catch (Exception e) {
            result.error("hackrf", e.getMessage(), null);
        }
    }

    // ---- відкриття: дозвіл USB, налаштування, потоки -------------------------------------------
    private void open(MethodChannel.Result result) {
        if (running) {
            result.success(info());
            return;
        }
        UsbDevice dev = find();
        if (dev == null) {
            result.error("hackrf", "HackRF не знайдено. Під'єднайте його через OTG-перехідник (USB-C → USB-A).", null);
            return;
        }
        if (!usb.hasPermission(dev)) {
            int flags = Build.VERSION.SDK_INT >= 31 ? PendingIntent.FLAG_IMMUTABLE : 0;
            Intent i = new Intent("ua.sdrwatch.sdrwatch.USB_PERMISSION").setPackage(ctx.getPackageName());
            usb.requestPermission(dev, PendingIntent.getBroadcast(ctx, 0, i, flags));
            // Дозвіл дає користувач у системному вікні — чекаємо (до 30 с), без приймача трансляцій
            final long until = System.currentTimeMillis() + 30000;
            main.postDelayed(new Runnable() {
                @Override
                public void run() {
                    if (usb.hasPermission(dev)) {
                        openGranted(dev, result);
                    } else if (System.currentTimeMillis() < until) {
                        main.postDelayed(this, 300);
                    } else {
                        result.error("hackrf", "Немає дозволу на USB-пристрій (натисніть «Дозволити»).", null);
                    }
                }
            }, 300);
            return;
        }
        openGranted(dev, result);
    }

    private void openGranted(UsbDevice dev, MethodChannel.Result result) {
        try {
            conn = usb.openDevice(dev);
            if (conn == null) throw new IllegalStateException("Не вдалося відкрити USB-пристрій");
            iface = dev.getInterface(0);
            if (!conn.claimInterface(iface, true)) throw new IllegalStateException("USB-інтерфейс HackRF зайнятий");
            epIn = null;
            for (int i = 0; i < iface.getEndpointCount(); i++) {
                UsbEndpoint ep = iface.getEndpoint(i);
                if (ep.getType() == UsbConstants.USB_ENDPOINT_XFER_BULK && ep.getDirection() == UsbConstants.USB_DIR_IN) {
                    epIn = ep;
                }
            }
            if (epIn == null) throw new IllegalStateException("Немає кінцевої точки приймання");
            byte[] id = ctrlIn(REQ_BOARD_ID_READ, 0, 0, 1);
            board = id != null ? boardName(id[0]) : "HackRF";
            byte[] ver = ctrlIn(REQ_VERSION_STRING_READ, 0, 0, 255);
            version = ver != null ? new String(ver, StandardCharsets.US_ASCII).trim() : "";
            ctrlOut(REQ_SET_TRANSCEIVER_MODE, 0, 0, null);
            applyRate();
            setFreq(freqHz);
            setGain(32, 30, false);
            if (!ctrlOut(REQ_SET_TRANSCEIVER_MODE, 1, 0, null)) throw new IllegalStateException("HackRF не перейшов у приймання");
            lastError = null;
            start();
            result.success(info());
        } catch (Exception e) {
            close();
            result.error("hackrf", e.getMessage(), null);
        }
    }

    private static String boardName(int id) {
        switch (id) {
            case 0: return "Jellybean";
            case 1: return "Jawbreaker";
            case 2: return "HackRF One";
            case 3: return "rad1o";
            case 4: return "HackRF One r9";
            default: return "HackRF";
        }
    }

    private Map<String, Object> info() {
        Map<String, Object> m = new HashMap<>();
        m.put("board", board);
        m.put("version", version);
        m.put("rate", rate);
        return m;
    }

    private Map<String, Object> stats() {
        Map<String, Object> m = info();
        long now = System.currentTimeMillis();
        double dt = Math.max(0.001, (now - statsT) / 1000.0);
        synchronized (lock) {
            m.put("fields_s", fields / dt);
            m.put("dropped", dropped);
            m.put("usb_mbs", usbBytes / dt / 1e6);
            fields = 0;
            usbBytes = 0;
        }
        statsT = now;
        m.put("running", running);
        m.put("error", lastError);
        m.put("freq_hz", freqHz);
        return m;
    }

    // ---- керування ----------------------------------------------------------------------------
    private boolean ctrlOut(int req, int value, int index, byte[] data) {
        if (conn == null) return false;
        int n = conn.controlTransfer(UsbConstants.USB_DIR_OUT | UsbConstants.USB_TYPE_VENDOR, req, value, index, data,
                data == null ? 0 : data.length, 1000);
        return n >= 0;
    }

    private byte[] ctrlIn(int req, int value, int index, int len) {
        if (conn == null) return null;
        byte[] b = new byte[len];
        int n = conn.controlTransfer(UsbConstants.USB_DIR_IN | UsbConstants.USB_TYPE_VENDOR, req, value, index, b, len, 1000);
        if (n < 0) return null;
        byte[] out = new byte[n];
        System.arraycopy(b, 0, out, 0, n);
        return out;
    }

    private static byte[] le32x2(long a, long b) {
        return ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN).putInt((int) a).putInt((int) b).array();
    }

    private void applyRate() {
        long hz = Math.round(rate);
        ctrlOut(REQ_SAMPLE_RATE_SET, 0, 0, le32x2(hz, 1));
        long want = (long) (rate * 0.75);
        int bw = FILTERS[0];
        for (int f : FILTERS) if (f <= want) bw = f;
        ctrlOut(REQ_BASEBAND_FILTER_SET, bw & 0xffff, bw >>> 16, null);
    }

    private void setFreq(double hz) {
        long f = Math.max(1_000_000L, Math.min(6_000_000_000L, Math.round(hz)));
        ctrlOut(REQ_SET_FREQ, 0, 0, le32x2(f / 1_000_000L, f % 1_000_000L));
    }

    private void tune(double hz) {
        if (Math.abs(hz - freqHz) < 1 && running) return;
        freqHz = hz;
        if (conn == null) return;
        setFreq(hz);
        // Відкинути те, що вже було «в дорозі» зі старої частоти (усі поставлені в чергу USB-запити) + ~2 мс PLL
        long inflight = (long) REQUESTS * requestSize() + ((long) (rate * 0.002) * 2);
        skipBytes = inflight & ~1L;
        retuneGen++;
    }

    private void setGain(int lna, int vga, boolean amp) {
        lna = Math.max(0, Math.min(40, lna)) & ~7;
        vga = Math.max(0, Math.min(62, vga)) & ~1;
        ctrlIn(REQ_SET_LNA_GAIN, 0, lna, 1);
        ctrlIn(REQ_SET_VGA_GAIN, 0, vga, 1);
        ctrlOut(REQ_AMP_ENABLE, amp ? 1 : 0, 0, null);
    }

    // ---- потоки -------------------------------------------------------------------------------
    private static final int REQUESTS = 8;

    private static int requestSize() {
        return Build.VERSION.SDK_INT >= 28 ? 131072 : 16384;   // до Android 9 — не більше 16 КБ на запит
    }

    private void start() {
        running = true;
        rxThread = new Thread(this::rxLoop, "hackrf-rx");
        dspThread = new Thread(this::dspLoop, "hackrf-dsp");
        rxThread.setPriority(Thread.MAX_PRIORITY);
        rxThread.start();
        dspThread.start();
    }

    private void close() {
        running = false;
        synchronized (lock) {
            lock.notifyAll();
        }
        try {
            if (rxThread != null) rxThread.join(1000);
            if (dspThread != null) dspThread.join(1000);
        } catch (InterruptedException ignored) {
        }
        rxThread = null;
        dspThread = null;
        if (conn != null) {
            ctrlOut(REQ_SET_TRANSCEIVER_MODE, 0, 0, null);
            try {
                if (iface != null) conn.releaseInterface(iface);
            } catch (Exception ignored) {
            }
            conn.close();
        }
        conn = null;
    }

    private void fail(String msg) {
        lastError = msg;
        running = false;
        main.post(() -> {
            if (sink != null) sink.success(prefixed((byte) 'E', msg.getBytes(StandardCharsets.UTF_8)));
        });
    }

    @SuppressWarnings("deprecation")
    private void rxLoop() {
        int size = requestSize();
        UsbRequest[] reqs = new UsbRequest[REQUESTS];
        try {
            for (int i = 0; i < REQUESTS; i++) {
                UsbRequest r = new UsbRequest();
                if (!r.initialize(conn, epIn)) throw new IllegalStateException("UsbRequest");
                ByteBuffer b = ByteBuffer.allocate(size);
                r.setClientData(b);
                queue(r, b, size);
                reqs[i] = r;
            }
        } catch (Exception e) {
            fail("Не вдалося запустити USB-потік: " + e.getMessage());
            return;
        }
        byte[] field = new byte[2 * (int) Math.round(rate * FIELD_S)];
        int fill = 0;
        long gap = 0;
        int gen = retuneGen;
        int errors = 0;
        while (running) {
            UsbRequest r = conn.requestWait();
            if (r == null) {
                if (++errors > 50) {
                    fail("HackRF від'єднано або USB-помилка");
                    break;
                }
                continue;
            }
            errors = 0;
            ByteBuffer b = (ByteBuffer) r.getClientData();
            int len = Build.VERSION.SDK_INT >= 26 ? b.position() : size;
            byte[] a = b.array();
            int off = 0;
            synchronized (lock) {
                usbBytes += len;
            }
            if (gen != retuneGen) {             // нова частота — недозібране поле вже не про те
                gen = retuneGen;
                fill = 0;
                gap = 0;
            }
            long sk = skipBytes;
            if (sk > 0) {
                int k = (int) Math.min(sk, len);
                skipBytes = sk - k;
                off = k;
            }
            if (gap > 0 && off < len) {
                int k = (int) Math.min(gap, len - off);
                gap -= k;
                off += k;
            }
            while (off < len) {
                int k = Math.min(len - off, field.length - fill);
                System.arraycopy(a, off, field, fill, k);
                fill += k;
                off += k;
                if (fill == field.length) {
                    synchronized (lock) {
                        if (ready != null) dropped++;
                        ready = field;
                        readyFreq = freqHz;
                        lock.notifyAll();
                    }
                    field = new byte[field.length];
                    fill = 0;
                    // не частіше maxFps: решту часу кадру пропускаємо (менше роботи телефону)
                    long period = 2L * (long) (rate / maxFps);
                    gap = Math.max(0, period - field.length) & ~1L;
                    int k2 = (int) Math.min(gap, len - off);
                    gap -= k2;
                    off += k2;
                }
            }
            b.clear();
            if (running && !queue(r, b, size)) {
                fail("USB: запит не прийнято");
                break;
            }
        }
        for (UsbRequest r : reqs) {
            if (r == null) continue;
            try {
                r.cancel();
                r.close();
            } catch (Exception ignored) {
            }
        }
    }

    @SuppressWarnings("deprecation")
    private static boolean queue(UsbRequest r, ByteBuffer b, int size) {
        if (Build.VERSION.SDK_INT >= 26) return r.queue(b);
        return r.queue(b, size);
    }

    private void dspLoop() {
        DirectDsp dsp = new DirectDsp();
        long lastSpec = 0;
        while (running) {
            byte[] f;
            double fr;
            synchronized (lock) {
                while (running && ready == null) {
                    try {
                        lock.wait(500);
                    } catch (InterruptedException e) {
                        return;
                    }
                }
                f = ready;
                fr = readyFreq;
                ready = null;
                if (f != null) fields++;
            }
            if (f == null) continue;
            int n = f.length / 2;
            byte[] pkt = dsp.packet(f, 0, n, rate, fr, targetFs, color, fsc);
            long now = System.currentTimeMillis();
            byte[] spec = null;
            if (spectrumEveryField || now - lastSpec >= 100) {
                lastSpec = now;
                float[] db = dsp.spectrum(f, 0, n, 2048, 8);
                ByteBuffer sb = ByteBuffer.allocate(1 + 8 + 4 + 4 + 4 * db.length).order(ByteOrder.LITTLE_ENDIAN);
                sb.put((byte) 'S').putDouble(fr).putFloat((float) rate).putInt(db.length);
                for (float v : db) sb.putFloat(v);
                spec = sb.array();
            }
            final byte[] p = prefixed((byte) 'B', pkt), s = spec;
            main.post(() -> {
                if (sink == null) return;
                sink.success(p);
                if (s != null) sink.success(s);
            });
        }
    }

    private static byte[] prefixed(byte tag, byte[] data) {
        byte[] out = new byte[data.length + 1];
        out[0] = tag;
        System.arraycopy(data, 0, out, 1, data.length);
        return out;
    }
}
