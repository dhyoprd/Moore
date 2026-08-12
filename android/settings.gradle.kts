// Moore Android port (ticket #31 / #13) — Gradle settings.
// Two modules:
//   :core — pure Kotlin JVM parity engine (Swift sources in Sources/ ported 1:1).
//   :app  — Android scaffold (Room/Compose) bound to :core.
pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "Moore"
include(":core")
include(":app")
