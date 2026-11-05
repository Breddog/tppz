/* Швидкі ділянки обробки сигналу SDR Watch (компілюється при встановленні; без нього — numpy).
 *
 * fm_baseband: ЧМ-детектор + проріджування «в один прохід» — без проміжних масивів numpy
 * (x*conj(x), angle, reshape/mean створювали по кілька десятків МБ на кожне поле відео).
 */
#include <math.h>
#include <stddef.h>
#include <stdint.h>

/* Швидкий atan2 (поліном 7-го порядку, похибка < 0.0001 рад) — як «-A fast» у rtl_fm.
 * Без розгалужень, тож компілятор векторизує цикл (NEON на Raspberry Pi). */
static inline float fast_atan2f(float y, float x)
{
    float ax = fabsf(x), ay = fabsf(y);
    float mx = fmaxf(ax, ay) + 1e-30f, mn = fminf(ax, ay);
    float a = mn / mx, s = a * a;
    float r = ((-0.0464964749f * s + 0.15931422f) * s - 0.327622764f) * s * a + a;
    r = (ay > ax) ? 1.57079637f - r : r;
    r = (x < 0.0f) ? 3.14159274f - r : r;
    return (y < 0.0f) ? -r : r;
}

/* iq: complex64 як пари float (I,Q), n відліків; prev: попередній відлік (I,Q) для неперервності.
 * out: n/decim значень — середня миттєва частота, Гц (scale = fs / 2π).  Повертає кількість виходів. */
long fm_baseband(const float *iq, long n, long decim, float scale, float *prev, float *out)
{
    float pi_ = prev[0], pq = prev[1];
    long k = 0, m = 0;
    float acc = 0.0f;
    for (long i = 0; i < n; i++) {
        float I = iq[2 * i], Q = iq[2 * i + 1];
        /* arg(x[i] * conj(x[i-1])) */
        float re = I * pi_ + Q * pq;
        float im = Q * pi_ - I * pq;
        acc += fast_atan2f(im, re);
        pi_ = I;
        pq = Q;
        if (++m == decim) {
            out[k++] = acc * scale / (float)decim;
            acc = 0.0f;
            m = 0;
        }
    }
    prev[0] = pi_;
    prev[1] = pq;
    return k;
}

/* Те саме для 8-бітного CS8 (рідний формат HackRF) — без перетворення у float32 цілого буфера. */
long fm_baseband_cs8(const int8_t *iq, long n, long decim, float scale, float *prev, float *out)
{
    float pi_ = prev[0], pq = prev[1];
    long k = 0, m = 0;
    float acc = 0.0f;
    for (long i = 0; i < n; i++) {
        float I = (float)iq[2 * i], Q = (float)iq[2 * i + 1];
        float re = I * pi_ + Q * pq;
        float im = Q * pi_ - I * pq;
        acc += fast_atan2f(im, re);
        pi_ = I;
        pq = Q;
        if (++m == decim) {
            out[k++] = acc * scale / (float)decim;
            acc = 0.0f;
            m = 0;
        }
    }
    prev[0] = pi_;
    prev[1] = pq;
    return k;
}

/* Колір для телефона: ЧМ-детектор на повній частоті + два виходи за один прохід:
 *   luma   — середнє по kl відліків (яскравість, як fm_baseband);
 *   chroma — композит × e^(−jωt) на піднесучій (w = 2π·fsc/fs), середнє по kc → комплексні (U,V)
 *            у системі координат генератора; фазу кожного рядка телефон бере зі сплеску.
 * Генератор — обертовий вектор із перенормуванням (без sin/cos на кожен відлік).
 * Повертає кількість luma-виходів; chroma — n/kc пар (re, im). */
long fm_chroma(const float *iq, long n, long kl, long kc, float scale, float w, float *prev,
               float *luma, float *chroma)
{
    float pi_ = prev[0], pq = prev[1];
    float lr = 1.0f, li = 0.0f;                 /* e^(−jωt) */
    const float cr = cosf(w), ci = -sinf(w);
    long k = 0, kk = 0, m = 0, mc = 0;
    float acc = 0.0f, ar = 0.0f, ai = 0.0f;
    for (long i = 0; i < n; i++) {
        float I = iq[2 * i], Q = iq[2 * i + 1];
        float re = I * pi_ + Q * pq;
        float im = Q * pi_ - I * pq;
        float v = fast_atan2f(im, re);
        pi_ = I;
        pq = Q;
        acc += v;
        ar += v * lr;
        ai += v * li;
        float nr = lr * cr - li * ci;
        li = lr * ci + li * cr;
        lr = nr;
        if (++m == kl) {
            luma[k++] = acc * scale / (float)kl;
            acc = 0.0f;
            m = 0;
        }
        if (++mc == kc) {
            chroma[2 * kk] = ar * scale / (float)kc;
            chroma[2 * kk + 1] = ai * scale / (float)kc;
            kk++;
            ar = ai = 0.0f;
            mc = 0;
            float g = 1.5f - 0.5f * (lr * lr + li * li);   /* перенормування вектора генератора */
            lr *= g;
            li *= g;
        }
    }
    prev[0] = pi_;
    prev[1] = pq;
    return k;
}
