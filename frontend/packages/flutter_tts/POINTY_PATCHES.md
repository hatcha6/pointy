# Pointy's copy of `flutter_tts` 4.2.5

This is `flutter_tts` 4.2.5 from pub.dev, its latest release. Only
`android/build.gradle` differs from upstream; every change there is marked
`POINTY PATCH`. The pub.dev example, tests, changelog, code of conduct and
the unused Gradle wrapper settings were left out.

## Why it is vendored

The app moved to Android Gradle Plugin 9 with Flutter 3.47 and turned on
built-in Kotlin (`android.builtInKotlin=true` in `android/gradle.properties`),
which AGP 9 requires every module to accept: AGP compiles the Kotlin itself
and fails the build of any module that applies the Kotlin Gradle plugin.
Upstream's script applies it.

The script no longer applies it. With built-in Kotlin off, Flutter applies the
plugin itself to plugins that leave it out, so the copy builds either way;
`kotlinOptions`, which only that plugin provides, is set only in that case.

## Dropping this copy

When a release of `flutter_tts` drops the Kotlin Gradle plugin (or applies it
only below AGP 9), go back to it in `frontend/pubspec.yaml` and delete this
directory.
