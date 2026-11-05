package ua.sdrwatch.sdrwatch;

import java.nio.file.Files;
import java.nio.file.Paths;

/** Перевірка DirectDsp без Android: IQ (int8) з симулятора модуля → пакет SDRB для тесту Dart. */
public class DirectDspCheck {
    public static void main(String[] a) throws Exception {
        byte[] iq = Files.readAllBytes(Paths.get(a[0]));
        DirectDsp d = new DirectDsp();
        int n = iq.length / 2;
        long t0 = System.nanoTime();
        byte[] p = null;
        for (int i = 0; i < 20; i++) p = d.packet(iq, 0, n, 20e6, 5800e6, 4e6, true, DirectDsp.FSC_PAL);
        long t1 = System.nanoTime();
        float[] sp = d.spectrum(iq, 0, n, 2048, 8);
        Files.write(Paths.get(a[1]), p);
        float mx = -999;
        for (float v : sp) mx = Math.max(mx, v);
        System.out.printf("packet %d bytes, %.2f ms/field, spectrum max %.1f dB%n", p.length, (t1 - t0) / 20 / 1e6, mx);
    }
}
