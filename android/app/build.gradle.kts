plugins {
    id("com.android.application")
}

android {
    namespace = "local.snapsync.android"
    compileSdk = 36

    buildFeatures {
        buildConfig = true
    }

    defaultConfig {
        applicationId = "local.snapsync.android"
        minSdk = 29
        targetSdk = 36
        versionCode = 7
        versionName = "0.3.3"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies {
    implementation("androidx.work:work-runtime:2.11.2")
    implementation("com.journeyapps:zxing-android-embedded:4.3.0")
}
