package ua.sdrwatch.sdrwatch;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.Arrays;

/**
 * Обробка сигналу HackRF прямо на телефоні (режим «без Raspberry Pi»).
 *
 * Робить те саме, що модуль (pi/sdrwatch/native/fastdsp.c fm_chroma + dsp/baseband.py make_packet):
 * ЧМ-детектор на повній частоті, яскравість (проріджена ~4 Мвідл/с) і кольорова складова
 * (×e^(−jωt) на піднесучій, проріджена ~1 Мвідл/с), пакет SDRB(+CHRM) — у ТОМУ Ж форматі, тож
 * далі його декодує той самий BasebandDecoder (Dart), що й відео з модуля.
 * Без залежностей від Android — перевіряється звичайним javac (див. mobile/test/java).
 */
final class DirectDsp {
    static final double FSC_PAL = 4.43361875e6;
    static final double FSC_NTSC = 3.579545e6;

    /** Прапорець SDRB: полярність невідома — телефон визначає сам (пробує обидві). */
    static final int FLAG_POLARITY_UNKNOWN = 8;
    static final int FLAG_CHROMA = 4;

    private float prevI = 1f, prevQ = 0f;

    private static float fastAtan2(float y, float x) {
        float ax = Math.abs(x), ay = Math.abs(y);
        float mx = Math.max(ax, ay) + 1e-30f, mn = Math.min(ax, ay);
        float a = mn / mx, s = a * a;
        float r = ((-0.0464964749f * s + 0.15931422f) * s - 0.327622764f) * s * a + a;
        if (ay > ax) r = 1.57079637f - r;
        if (x < 0f) r = 3.14159274f - r;
        return y < 0f ? -r : r;
    }

    /**
     * iq — int8 I,Q (рідний формат HackRF), n відліків від off.
     * Повертає пакет SDRB для телефона.
     */
    byte[] packet(byte[] iq, int off, int n, double fs, double freqHz, double targetFs, boolean color, double fsc) {
        int kl = Math.max(1, (int) Math.round(fs / targetFs));
        int kc = Math.max(1, (int) Math.round(fs / 1.0e6));
        color = color && fs >= 2.2 * fsc;
        int nl = n / kl, nc = color ? n / kc : 0;
        float[] luma = new float[nl];
        float[] chroma = new float[2 * nc];
        float scale = (float) (fs / (2 * Math.PI));
        double w = 2 * Math.PI * fsc / fs;
        float cr = (float) Math.cos(w), ci = (float) -Math.sin(w);
        float lr = 1f, li = 0f;
        float pI = prevI, pQ = prevQ;
        float acc = 0f, ar = 0f, ai = 0f;
        int k = 0, kk = 0, m = 0, mc = 0;
        for (int i = 0; i < n; i++) {
            float I = iq[off + 2 * i], Q = iq[off + 2 * i + 1];
            float re = I * pI + Q * pQ;
            float im = Q * pI - I * pQ;
            float v = fastAtan2(im, re);
            pI = I;
            pQ = Q;
            acc += v;
            if (++m == kl) {
                if (k < nl) luma[k++] = acc * scale / kl;
                acc = 0f;
                m = 0;
            }
            if (color) {
                ar += v * lr;
                ai += v * li;
                float nr = lr * cr - li * ci;
                li = lr * ci + li * cr;
                lr = nr;
                if (++mc == kc) {
                    if (kk < nc) {
                        chroma[2 * kk] = ar * scale / kc;
                        chroma[2 * kk + 1] = ai * scale / kc;
                        kk++;
                    }
                    ar = 0f;
                    ai = 0f;
                    mc = 0;
                    float g = 1.5f - 0.5f * (lr * lr + li * li);
                    lr *= g;
                    li *= g;
                }
            }
        }
        prevI = pI;
        prevQ = pQ;

        // Рівні: 0.5 і 99.5 перцентилі (за вибіркою) — як на модулі
        float[] sub = sample(luma, 8192, false);
        Arrays.sort(sub);
        float lo = sub.length > 0 ? sub[(int) (sub.length * 0.005)] : 0f;
        float hi = sub.length > 0 ? sub[Math.min(sub.length - 1, (int) (sub.length * 0.995))] : 1f;
        float span = Math.max(hi - lo, 1f);
        byte[] q = new byte[nl];
        float kq = 255f / span;
        for (int i = 0; i < nl; i++) {
            int x = (int) ((luma[i] - lo) * kq + 0.5f);
            q[i] = (byte) (x < 0 ? 0 : (x > 255 ? 255 : x));
        }

        int tail = nc > 0 ? 24 + 2 * nc : 0;
        ByteBuffer b = ByteBuffer.allocate(32 + nl + tail).order(ByteOrder.LITTLE_ENDIAN);
        b.put((byte) 'S').put((byte) 'D').put((byte) 'R').put((byte) 'B');
        b.put((byte) 1).put((byte) 8);
        b.putShort((short) (FLAG_POLARITY_UNKNOWN | (nc > 0 ? FLAG_CHROMA : 0)));
        b.putDouble(freqHz);
        b.putFloat((float) (fs / kl));
        b.putFloat(lo);
        b.putFloat(hi);
        b.putInt(nl);
        b.put(q);
        if (nc > 0) {
            float[] cs = sample(chroma, 8192, true);
            Arrays.sort(cs);
            float cscale = Math.max(cs.length > 0 ? cs[Math.min(cs.length - 1, (int) (cs.length * 0.998))] / 120f : 1f, 1f);
            b.put((byte) 'C').put((byte) 'H').put((byte) 'R').put((byte) 'M');
            b.putFloat((float) (fs / kc));
            b.putFloat((float) fsc);
            b.putFloat(cscale);
            b.putFloat((float) ((kl - kc) / (2 * fs)));
            b.putInt(nc);
            float inv = 1f / cscale;
            for (int i = 0; i < 2 * nc; i++) {
                int x = Math.round(chroma[i] * inv);
                b.put((byte) (x < -127 ? -127 : (x > 127 ? 127 : x)));
            }
        }
        return b.array();
    }

    private static float[] sample(float[] a, int max, boolean abs) {
        int step = Math.max(1, a.length / max);
        float[] out = new float[(a.length + step - 1) / step];
        for (int i = 0, j = 0; i < a.length && j < out.length; i += step, j++) {
            out[j] = abs ? Math.abs(a[i]) : a[i];
        }
        return out;
    }

    // ---- спектр -----------------------------------------------------------------------------
    private int fftN = 0;
    private float[] win, cosT, sinT;
    private int[] rev;

    private void prepare(int n) {
        if (n == fftN) return;
        fftN = n;
        win = new float[n];
        for (int i = 0; i < n; i++) win[i] = (float) (0.5 - 0.5 * Math.cos(2 * Math.PI * i / n));
        cosT = new float[n / 2];
        sinT = new float[n / 2];
        for (int i = 0; i < n / 2; i++) {
            cosT[i] = (float) Math.cos(-2 * Math.PI * i / n);
            sinT[i] = (float) Math.sin(-2 * Math.PI * i / n);
        }
        int bits = Integer.numberOfTrailingZeros(n);
        rev = new int[n];
        for (int i = 0; i < n; i++) rev[i] = Integer.reverse(i) >>> (32 - bits);
    }

    /**
     * Спектр потужності (дБ відносно повної шкали), середнє по avg блоках; нульова частота — посередині.
     * n — степінь двійки.
     */
    float[] spectrum(byte[] iq, int off, int avail, int n, int avg) {
        prepare(n);
        float[] pw = new float[n];
        float[] re = new float[n], im = new float[n];
        int blocks = Math.max(1, Math.min(avg, avail / n));
        for (int b = 0; b < blocks; b++) {
            int base = off + 2 * b * n;
            for (int i = 0; i < n; i++) {
                int j = rev[i];
                re[j] = iq[base + 2 * i] * win[i] / 128f;
                im[j] = iq[base + 2 * i + 1] * win[i] / 128f;
            }
            for (int size = 2; size <= n; size <<= 1) {
                int half = size >> 1, step = n / size;
                for (int s = 0; s < n; s += size) {
                    for (int t = 0; t < half; t++) {
                        float wr = cosT[t * step], wi = sinT[t * step];
                        int a = s + t, c = a + half;
                        float xr = re[c] * wr - im[c] * wi;
                        float xi = re[c] * wi + im[c] * wr;
                        re[c] = re[a] - xr;
                        im[c] = im[a] - xi;
                        re[a] += xr;
                        im[a] += xi;
                    }
                }
            }
            for (int i = 0; i < n; i++) pw[i] += re[i] * re[i] + im[i] * im[i];
        }
        float[] db = new float[n];
        float norm = 1f / (blocks * n * 0.375f * n);
        for (int i = 0; i < n; i++) {
            int src = (i + n / 2) % n;
            db[i] = (float) (10 * Math.log10(pw[src] * norm + 1e-20));
        }
        // пік нульової частоти HackRF — замінити сусідами
        int c = n / 2;
        db[c] = (db[c - 2] + db[c + 2]) / 2;
        db[c - 1] = db[c - 2];
        db[c + 1] = db[c + 2];
        return db;
    }
}
