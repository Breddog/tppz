"""Імітація hackrf_sweep для тестів: той самий текстовий формат рядків, «сигнал» 8 МГц на 5800 МГц."""
import random
import sys
import time

args = sys.argv[1:]
lo, hi = map(float, args[args.index("-f") + 1].split(":"))
bw = float(args[args.index("-w") + 1])
rnd = random.Random(1)
while True:
    f = lo * 1e6
    while f < hi * 1e6:
        n = int(5e6 / bw)
        vals = []
        for k in range(n):
            fc = f + (k + 0.5) * bw
            v = -85 + rnd.uniform(-1.5, 1.5)
            if abs(fc - 5800e6) < 4e6:
                v = -45 + rnd.uniform(-1, 1)
            vals.append(f"{v:.2f}")
        print(f"2026-11-01, 12:00:00.000000, {int(f)}, {int(f + 5e6)}, {bw:.2f}, 20, " + ", ".join(vals))
        f += 5e6
    sys.stdout.flush()
    time.sleep(0.05)
