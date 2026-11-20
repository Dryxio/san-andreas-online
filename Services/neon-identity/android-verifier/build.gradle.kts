plugins {
    kotlin("jvm") version "2.2.0"
    application
}

repositories {
    google {
        content {
            includeGroup("com.android.keyattestation")
            includeGroupByRegex("androidx[.].*")
        }
    }
    mavenCentral()
}

dependencies {
    implementation("com.android.keyattestation:keyattestation:0.4")
    implementation("com.google.code.gson:gson:2.11.0")
}

kotlin { compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_21) } }
tasks.withType<JavaCompile>().configureEach { options.release.set(21) }
application {
    mainClass.set("AdmissionKt")
    applicationDefaultJvmArgs = listOf("-Xmx128m", "-XX:ActiveProcessorCount=2")
}
