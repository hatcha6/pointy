# Pointy's copy of `flutter_libserialport` 0.6.0

This is `flutter_libserialport` 0.6.0 from pub.dev, its latest release. Only
`android/build.gradle` differs from upstream; every change there is marked
`POINTY PATCH`. The pub.dev example, docs, changelog and the unused Gradle
wrapper settings were left out.

## Why it is vendored

The app moved to Android Gradle Plugin 9 and Gradle 9 with Flutter 3.47.
Upstream's Android build script cannot build under either, and the package
has had no release since August 2025:

1. It lists `jcenter()` as a repository. Gradle 9 removed that method, so the
   script fails before anything compiles. JCenter itself shut down in 2021;
   it is `mavenCentral()` now.
2. It applies the Kotlin Gradle plugin, which AGP 9 refuses once built-in
   Kotlin is on (`android.builtInKotlin=true` in `android/gradle.properties`).
   The script no longer applies it: AGP compiles the Kotlin, and with built-in
   Kotlin off Flutter applies the plugin itself. `kotlinOptions` is set only
   in that case.
3. It builds the bundled libserialport C library with AGP's default NDK rather
   than Flutter's, which made a build download a second NDK (2.4 GB). It now
   uses `flutter.ndkVersion` like the app.

## Dropping this copy

When a release of `flutter_libserialport` builds under AGP 9 with built-in
Kotlin, go back to it in `frontend/pubspec.yaml` and delete this directory.
