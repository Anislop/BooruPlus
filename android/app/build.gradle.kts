import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing from android/key.properties (written by CD from repository
// secrets, never committed). Without it, release builds use the debug key.
val keystoreProperties =
    Properties().apply {
        val file = rootProject.file("key.properties")
        if (file.exists()) file.inputStream().use { load(it) }
    }
val hasReleaseKey = keystoreProperties.getProperty("storeFile") != null

// The Play edition's upload key, from android/key.play.properties (same
// fields, never committed). Play release builds fail without it rather
// than fall back to the debug key; setting the Gradle property
// playDebugSigning=true (for example ORG_GRADLE_PROJECT_playDebugSigning)
// signs a local Play release with the debug key for testing only.
val playKeystoreProperties =
    Properties().apply {
        val file = rootProject.file("key.play.properties")
        if (file.exists()) file.inputStream().use { load(it) }
    }
val hasPlayKey = playKeystoreProperties.getProperty("storeFile") != null
val playDebugSigning = (findProperty("playDebugSigning") as String?) == "true"

// Google's sample AdMob app ID unless the build passes the real one
// (Gradle property admobAppId). The Full edition never starts the ads SDK
// but still declares an ID, which the SDK checks when the process starts.
val testAdmobAppId = "ca-app-pub-3940256099942544~3347511713"

android {
    namespace = "com.booruplus.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    val launcherResDir = layout.buildDirectory.dir("generated/res/launcher/main").get().asFile
    val copyLauncherIcon by tasks.registering(Copy::class) {
        duplicatesStrategy = DuplicatesStrategy.INCLUDE
        from(rootProject.file("../assets")) {
            include("AppIcon.png")
            include("LogoFullColor.png")
            include("LogoFullColorWhite.png")
        }
        into(launcherResDir.resolve("drawable"))
        rename { name ->
            when (name) {
                "AppIcon.png" -> "app_icon.png"
                "LogoFullColorWhite.png" -> "logo_full_color_white.png"
                "LogoFullColor.png" -> "logo_full_color.png"
                else -> name.lowercase()
            }
        }
    }
    sourceSets["main"].res.srcDir(launcherResDir)
    tasks.named("preBuild").configure { dependsOn(copyLauncherIcon) }

    buildFeatures {
        buildConfig = true
    }

    // Two editions from one source tree: "full" (com.booruplus.app, GitHub
    // releases, every website and the updater) and "play" (Google Play,
    // its own application ID, fixed content policy, ads and Premium).
    // Flutter passes the flavor to Dart as FLUTTER_APP_FLAVOR (see
    // lib/core/edition.dart); src/full and src/play hold each edition's
    // manifest entries and native code.
    flavorDimensions += "distribution"
    productFlavors {
        create("full") {
            dimension = "distribution"
            isDefault = true
            applicationId = "com.booruplus.app"
            manifestPlaceholders["admobAppId"] = testAdmobAppId
        }
        create("play") {
            dimension = "distribution"
            applicationId = "com.booruplus.play"
            manifestPlaceholders["admobAppId"] =
                (findProperty("admobAppId") as String?) ?: testAdmobAppId
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.booruplus.app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // Jackson 3.1.x, required by the exact imageboard-api 3.0.0 source,
        // uses MethodHandle.invoke* instructions which D8 supports from API 26.
        minSdk = maxOf(flutter.minSdkVersion, 26)
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseKey) {
            create("release") {
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
        if (hasPlayKey) {
            create("playRelease") {
                storeFile = file(playKeystoreProperties.getProperty("storeFile"))
                storePassword = playKeystoreProperties.getProperty("storePassword")
                keyAlias = playKeystoreProperties.getProperty("keyAlias")
                keyPassword = playKeystoreProperties.getProperty("keyPassword")
            }
        }
    }

    // Release signing per edition; debug builds keep the debug key, since
    // the debug build type's signing config wins over the flavor's.
    productFlavors.getByName("full").signingConfig =
        signingConfigs.getByName(if (hasReleaseKey) "release" else "debug")
    productFlavors.getByName("play").signingConfig = when {
        hasPlayKey -> signingConfigs.getByName("playRelease")
        playDebugSigning -> signingConfigs.getByName("debug")
        else -> null
    }

    buildTypes {
        release {
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
}

// A Play release must never be built without its upload key.
tasks.configureEach {
    if (!hasPlayKey && !playDebugSigning &&
        Regex("^(assemble|bundle|package)PlayRelease$").matches(name)) {
        doFirst {
            throw GradleException(
                "Play release builds need android/key.play.properties (the Play upload key)."
            )
        }
    }
}

dependencies {
    implementation(project(":imageboard-api"))
    implementation("com.squareup.okhttp3:okhttp:5.3.2")
    testImplementation("junit:junit:4.13.2")
    // Local JVM tests need a real JSON implementation instead of android.jar stubs.
    testImplementation("org.json:json:20240303")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
