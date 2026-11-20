import groovy.json.JsonSlurper
import java.io.File
import java.net.URI
import java.net.http.HttpClient
import java.net.http.HttpRequest
import java.net.http.HttpResponse
import java.nio.file.Files
import javax.inject.Inject

plugins {
    id("com.android.library")
}

abstract class StageEmbeddedDaemonAssetsTask @Inject constructor(
    private val execOperations: ExecOperations,
) : DefaultTask() {
    @get:Input
    abstract val appVersion: Property<String>

    @get:OutputDirectory
    abstract val outputDir: DirectoryProperty

    @TaskAction
    fun stage() {
        val outDir = outputDir.get().asFile.apply { mkdirs() }
        val client = HttpClient.newBuilder().followRedirects(HttpClient.Redirect.NORMAL).build()
        fun download(url: String, dest: File) {
            val res = client.send(
                HttpRequest.newBuilder(URI.create(url)).build(),
                HttpResponse.BodyHandlers.ofFile(dest.toPath()),
            )
            check(res.statusCode() in 200..299) { "Failed to download $url: HTTP ${res.statusCode()}" }
        }

        download(
            "https://github.com/Genymobile/scrcpy/releases/download/v3.1/scrcpy-server-v3.1",
            File(outDir, "scrcpy-server.jar"),
        )

        val tempRoot = Files.createTempDirectory("deskfleet-android-daemon-").toFile()
        try {
            val rawArchive = File(tempRoot, "deskfleet-linux-arm64.tar.gz")
            val versioned = "https://github.com/yet-another-ai/deskfleet/releases/download/v${appVersion.get()}/deskfleet-linux-arm64.tar.gz"
            val latest = "https://github.com/yet-another-ai/deskfleet/releases/latest/download/deskfleet-linux-arm64.tar.gz"
            runCatching { download(versioned, rawArchive) }.onFailure { download(latest, rawArchive) }

            val extractDir = File(tempRoot, "extract").apply { mkdirs() }
            execOperations.exec { commandLine("tar", "-xzf", rawArchive.absolutePath, "-C", extractDir.absolutePath) }
            File(extractDir, "deskfleet-server").delete()
            check(File(extractDir, "deskfleet-daemon").isFile) { "Archive is missing deskfleet-daemon" }
            execOperations.exec {
                commandLine("tar", "-czf", File(outDir, "deskfleet-daemon-linux-arm64.tgz").absolutePath, "-C", extractDir.absolutePath, ".")
            }
        } finally {
            tempRoot.deleteRecursively()
        }
    }
}

android {
    namespace = "io.github.yet_another_ai.deskfleet.nativedesktop"
    compileSdk = 37

    defaultConfig {
        minSdk = 34
        consumerProguardFiles("consumer-rules.pro")
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_21
        targetCompatibility = JavaVersion.VERSION_21
    }
}

val repoRoot = rootProject.projectDir.resolve("../../..").canonicalFile
val webVersion = (JsonSlurper().parse(File(repoRoot, "apps/web/package.json")) as Map<*, *>)["version"] as String

androidComponents {
    onVariants { variant ->
        val capName = variant.name.replaceFirstChar { it.uppercaseChar() }
        val stageTask = tasks.register<StageEmbeddedDaemonAssetsTask>("stage${capName}EmbeddedDaemonAssets") {
            appVersion.set(webVersion)
        }
        variant.sources.assets?.addGeneratedSourceDirectory(stageTask, StageEmbeddedDaemonAssetsTask::outputDir)
    }
}

dependencies {
    implementation(project(":capacitor-android"))
    implementation("androidx.appcompat:appcompat:1.8.0")
    implementation("androidx.activity:activity-ktx:1.13.0")
    implementation("androidx.core:core-ktx:1.19.1")
    implementation("com.google.firebase:firebase-analytics:24.0.0")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20260814")
}
