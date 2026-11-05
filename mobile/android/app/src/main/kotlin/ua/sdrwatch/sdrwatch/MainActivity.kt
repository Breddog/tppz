package ua.sdrwatch.sdrwatch

import android.content.Intent
import android.net.ConnectivityManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import java.io.File
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
        // HackRF напряму через USB OTG (режим без Raspberry Pi)
        HackRfDirect(this, flutterEngine.dartExecutor.binaryMessenger)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "sdrwatch/net").setMethodCallHandler { call, result ->
            val cm = getSystemService(ConnectivityManager::class.java)
            try {
                when (call.method) {
                    "bindWifi" -> {
                        @Suppress("DEPRECATION")
                        val nets = cm.allNetworks
                        // Кабель Ethernet до модуля (USB-Ethernet перехідник) — найнадійніший канал: першим
                        val eth = nets.firstOrNull { n ->
                            val c = cm.getNetworkCapabilities(n)
                            c?.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) == true &&
                                c.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED) != true
                        }
                        if (eth != null) {
                            result.success(cm.bindProcessToNetwork(eth))
                            return@setMethodCallHandler
                        }
                        val wifi = nets.firstOrNull { n ->
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
                    "cacheDir" -> result.success(File(cacheDir, "updates").apply { mkdirs() }.absolutePath)
                    "canInstall" -> result.success(
                        Build.VERSION.SDK_INT < Build.VERSION_CODES.O || packageManager.canRequestPackageInstalls()
                    )
                    "allowInstall" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startActivity(
                                Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName"))
                                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            )
                        }
                        result.success(true)
                    }
                    "installApk" -> {
                        val f = File(call.argument<String>("path")!!)
                        val uri = FileProvider.getUriForFile(this, "$packageName.updates", f)
                        startActivity(
                            Intent(Intent.ACTION_VIEW)
                                .setDataAndType(uri, "application/vnd.android.package-archive")
                                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
                        )
                        result.success(true)
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
