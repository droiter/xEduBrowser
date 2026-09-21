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

/** compileSdk used by the app and by every Android subproject; see below. */
val appCompileSdk = 36

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)

    // Some Flutter plugin subprojects (e.g. `jni`, `jni_flutter`) pin their own
    // `compileSdk 35`, which this environment does not ship: only android-36 is
    // installed and the SDK root is not writable, so AGP's auto-install fails.
    // Normalise every Android subproject to the app's compileSdk. The hook has
    // to be registered here, before `evaluationDependsOn(":app")` below forces
    // project evaluation.
    afterEvaluate {
        val androidExtension = extensions.findByName("android") ?: return@afterEvaluate
        val setter = androidExtension.javaClass.methods.firstOrNull { method ->
            method.name == "compileSdkVersion" &&
                method.parameterTypes.size == 1 &&
                method.parameterTypes[0] == Int::class.javaPrimitiveType
        } ?: return@afterEvaluate
        try {
            setter.invoke(androidExtension, appCompileSdk)
        } catch (_: Throwable) {
            // Leave the plugin's own value in place if AGP refuses the change.
        }
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
