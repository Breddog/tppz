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
