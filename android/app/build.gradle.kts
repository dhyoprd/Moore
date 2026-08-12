// :app — Android scaffold (ticket #31 Stage B).
// AGP 8.5.2, compileSdk 35, minSdk 26, Kotlin + Compose (BOM), Room 2.6.1.
plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
    id("com.google.devtools.ksp")
}

android {
    namespace = "com.moore.app"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.moore.app"
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "1.0"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        compose = true
    }

    // The shared .sql migrations ship as assets and are applied verbatim by
    // MooreDatabase's migration chain (byte-identical with iOS's GRDB chain).
    sourceSets {
        getByName("main") {
            assets.srcDirs("src/main/assets")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

dependencies {
    // The pure parity engine (ported Swift logic; fixtures-verified).
    implementation(project(":core"))

    val composeBom = platform("androidx.compose:compose-bom:2024.09.03")
    implementation(composeBom)
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.activity:activity-compose:1.9.2")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.ui:ui-tooling-preview")
    debugImplementation("androidx.compose.ui:ui-tooling")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.6")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.6")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1")

    // Room over the SAME schema the shared .sql migrations create.
    implementation("androidx.room:room-runtime:2.6.1")
    implementation("androidx.room:room-ktx:2.6.1")
    ksp("androidx.room:room-compiler:2.6.1")

    // Rest-end notification dispatch when backgrounded (SC-cues BR-005, #13).
    implementation("androidx.work:work-runtime-ktx:2.9.1")
}
