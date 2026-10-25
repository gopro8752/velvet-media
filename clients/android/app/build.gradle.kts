plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
    alias(libs.plugins.ksp)
}

android {
    namespace = "tv.velvet"
    compileSdk = 37
    compileSdkMinor = 2

    defaultConfig {
        applicationId = "tv.velvet"
        minSdk = 26
        targetSdk = 35
        versionCode = 36
        versionName = "1.13.3"
        // Recovery is production functionality; the flavor only isolates install identity.
        buildConfigField("boolean", "EXACT_RECOVERY", "true")
    }

    flavorDimensions += "channel"
    productFlavors {
        create("stable") {
            dimension = "channel"
            buildConfigField("boolean", "RECOVERY_BETA", "false")
        }
        create("beta") {
            dimension = "channel"
            applicationIdSuffix = ".beta"
            versionNameSuffix = "-beta"
            buildConfigField("boolean", "RECOVERY_BETA", "true")
        }
    }

    // Keep supported TV architectures without shipping every browser binary to each device.
    splits {
        abi {
            isEnable = true
            reset()
            include(*providers.gradleProperty("velvetAbis").orElse("arm64-v8a,armeabi-v7a,x86_64")
                .get().split(",").map(String::trim).toTypedArray())
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            // Release artifacts are unsigned. Sign both apps with your own shared key.
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    buildFeatures {
        compose = true
        buildConfig = true
    }
    packaging {
        resources.merges += "/META-INF/AL2.0"
        resources.merges += "/META-INF/LGPL2.1"
    }
}

kotlin {
    compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) }
}

dependencies {
    implementation("org.mozilla.geckoview:geckoview:158.0.20261007201254")
    implementation(libs.androidx.core.ktx)
    implementation(platform(libs.compose.bom))
    // Gecko's lifecycle dependency already requires UI 1.11 at runtime. Compile
    // against that same API so focus restoration does not call removed overloads.
    implementation("androidx.compose.ui:ui:1.11.0")
    implementation(libs.compose.foundation)
    implementation(libs.compose.material3)
    implementation(libs.compose.material.icons)
    implementation(libs.tv.material)
    implementation(libs.activity.compose)
    implementation(libs.lifecycle.runtime.ktx)
    implementation(libs.lifecycle.viewmodel.compose)
    implementation(libs.lifecycle.runtime.compose)
    implementation(libs.navigation.compose)
    implementation(libs.media3.exoplayer)
    implementation(libs.media3.exoplayer.hls)
    implementation(libs.media3.exoplayer.dash)
    implementation(libs.media3.ui)
    implementation(libs.media3.datasource.okhttp)
    implementation(libs.coil.compose)
    implementation(libs.okhttp)
    implementation(libs.kotlinx.serialization.json)
    implementation(libs.kotlinx.coroutines.android)
    implementation(libs.room.runtime)
    implementation(libs.room.ktx)
    ksp(libs.room.compiler)
    implementation(libs.datastore.preferences)
    testImplementation(libs.junit)
}
