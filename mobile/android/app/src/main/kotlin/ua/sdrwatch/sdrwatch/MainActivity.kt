package ua.sdrwatch.sdrwatch

import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Android відправляє трафік через «мережу за замовчуванням». Якщо Wi-Fi без інтернету
 * (модуль, роутер без провайдера), за замовчуванням лишається мобільний інтернет — і запити
 * до модуля (192.168.x.x) йдуть у мобільну мережу й губляться, хоча пошук по UDP працює.
 * Тому прив'язуємо застосунок до Wi-Fi, коли в ньому немає інтернету.
 */
class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "sdrwatch/net").setMethodCallHandler { call, result ->
            val cm = getSystemService(ConnectivityManager::class.java)
            try {
                when (call.method) {
                    "bindWifi" -> {
                        @Suppress("DEPRECATION")
                        val wifi = cm.allNetworks.firstOrNull { n ->
                            cm.getNetworkCapabilities(n)?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true
                        }
                        val caps = wifi?.let { cm.getNetworkCapabilities(it) }
                        val validated = caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED) == true
                        if (wifi != null && !validated) {
                            result.success(cm.bindProcessToNetwork(wifi))
                        } else {
                            cm.bindProcessToNetwork(null)
                            result.success(false)
                        }
                    }
                    "unbind" -> {
                        cm.bindProcessToNetwork(null)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("net", e.message, null)
            }
        }
    }
}
