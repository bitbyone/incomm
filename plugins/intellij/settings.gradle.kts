rootProject.name = "incomm-intellij-plugin"

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
