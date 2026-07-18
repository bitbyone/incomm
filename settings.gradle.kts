rootProject.name = "incomm"

pluginManagement {
    repositories {
        gradlePluginPortal()
        mavenCentral()
    }
}

plugins {
    // Lets Gradle auto-provision a JDK 21 toolchain if one isn't already installed.
    id("org.gradle.toolchains.foojay-resolver-convention") version "0.9.0"
}

// The IntelliJ plugin lives in :plugin. The Go CLI (./cli) is a standalone
// module and is intentionally NOT part of the Gradle build.
include(":plugin")
