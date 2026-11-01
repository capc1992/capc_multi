plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val capcKeystorePath = System.getenv("CAPC_ANDROID_KEYSTORE_PATH")
val capcStorePassword = System.getenv("CAPC_ANDROID_STORE_PASSWORD")
val capcKeyAlias = System.getenv("CAPC_ANDROID_KEY_ALIAS")
val capcKeyPassword = System.getenv("CAPC_ANDROID_KEY_PASSWORD")
val capcHasReleaseSigning = listOf(
    capcKeystorePath,
    capcStorePassword,
    capcKeyAlias,
    capcKeyPassword,
).all { !it.isNullOrBlank() }
val capcAllowDebugReleaseSigning =
    System.getenv("CAPC_ALLOW_DEBUG_RELEASE_SIGNING")?.equals("true", ignoreCase = true) == true

android {
    namespace = "site.capcmultiservicios.capc"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "site.capcmultiservicios.capc"
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

    signingConfigs {
        if (capcHasReleaseSigning) {
            create("capcRelease") {
                storeFile = file(capcKeystorePath!!)
                storePassword = capcStorePassword
                keyAlias = capcKeyAlias
                keyPassword = capcKeyPassword
            }
        }
    }

    buildTypes {
        release {
            signingConfig = when {
                capcHasReleaseSigning -> signingConfigs.getByName("capcRelease")
                capcAllowDebugReleaseSigning -> signingConfigs.getByName("debug")
                else -> null
            }
        }
    }
}

tasks.configureEach {
    if (name == "bundleRelease" || name == "assembleRelease") {
        doFirst {
            if (!capcHasReleaseSigning && !capcAllowDebugReleaseSigning) {
                throw GradleException(
                    "Falta la firma Android release. Configura CAPC_ANDROID_KEYSTORE_PATH, " +
                        "CAPC_ANDROID_STORE_PASSWORD, CAPC_ANDROID_KEY_ALIAS y CAPC_ANDROID_KEY_PASSWORD. " +
                        "CAPC_ALLOW_DEBUG_RELEASE_SIGNING=true se permite solo en dry_run y nunca para publicar.",
                )
            }
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
