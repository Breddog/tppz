plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "ua.sdrwatch.sdrwatch"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // Потрібно для flutter_local_notifications
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "ua.sdrwatch.sdrwatch"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // ПОСТІЙНИЙ ключ підпису. Раніше кожна збірка CI підписувалася випадковим debug-ключем,
    // тож Android відмовлявся оновлювати встановлений застосунок і лишалася стара версія.
    // Ключ дає CI (секрет або збережений кеш) через змінні SDRWATCH_KEYSTORE / _PASS / _ALIAS.
    // Локально без цих змінних — звичайний debug-підпис.
    val ks = System.getenv("SDRWATCH_KEYSTORE")?.let { file(it) }?.takeIf { it.exists() }
    signingConfigs {
        if (ks != null) {
            create("release") {
                storeFile = ks
                storePassword = System.getenv("SDRWATCH_KEYSTORE_PASS")
                keyAlias = System.getenv("SDRWATCH_KEY_ALIAS") ?: "sdrwatch"
                keyPassword = System.getenv("SDRWATCH_KEYSTORE_PASS")
                storeType = "PKCS12"
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName(if (ks != null) "release" else "debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    // FileProvider — для встановлення оновлення застосунку
    implementation("androidx.core:core-ktx:1.13.1")
}
