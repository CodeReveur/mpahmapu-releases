allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
// A plugin that asks for the newest Android SDK of the day drags the whole build
// to an SDK this Gradle plugin cannot name: 37 now ships as "android-37.0" and
// the resolver only knows how to look for "android-37". Everything compiles
// against the SDK Flutter itself targets instead, which is installed and is what
// the app is built against anyway.
//
// This has to be registered before the block below forces the subprojects to
// evaluate, or Gradle refuses the hook as too late.
subprojects {
    afterEvaluate {
        extensions.findByName("android")?.let { android ->
            val setCompileSdk = android.javaClass.methods.firstOrNull {
                it.name == "setCompileSdkVersion" && it.parameterTypes.size == 1 &&
                    it.parameterTypes[0] == Int::class.javaPrimitiveType
            }
            setCompileSdk?.invoke(android, 36)
        }
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
