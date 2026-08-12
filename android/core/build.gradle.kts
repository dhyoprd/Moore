// :core — pure Kotlin JVM parity engine (ticket #31 Stage A).
// Every engine is a mechanical port of the Swift sources in Sources/ with
// closed-form identical math; fixtures in src/test/resources/fixtures are the
// SAME byte-identical inputs the Node verifiers (Tests/*/Verify*.mjs) run.
plugins {
    id("org.jetbrains.kotlin.jvm")
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}

dependencies {
    // JSON fixtures are parsed with Gson (same documents the Node verifiers parse).
    implementation("com.google.code.gson:gson:2.11.+")
    // In-memory SQLite for the seam-2 persistence tests; the SAME .sql migration
    // files iOS applies via GRDB are executed verbatim (resources/migrations).
    implementation("org.xerial:sqlite-jdbc:3.46.+")

    testImplementation("junit:junit:4.13.2")
}

tasks.withType<Test> {
    testLogging {
        events("passed", "failed", "skipped")
        showStandardStreams = false
    }
}
