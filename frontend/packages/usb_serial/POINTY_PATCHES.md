# Pointy's copy of `usb_serial` 0.5.2

This is `usb_serial` 0.5.2 from pub.dev, its latest release (July 2024). Only
`android/build.gradle` differs from upstream; every change there is marked
`POINTY PATCH`. The pub.dev example, tests, changelog and the unused Gradle
wrapper (a binary jar; Flutter builds the plugin inside the app's Gradle
project) were left out.

## Why it is vendored

The app moved to Android Gradle Plugin 9 and Gradle 9 with Flutter 3.47, and
upstream's Android build script cannot build under them:

1. It lists `jcenter()` as a repository. Gradle 9 removed that method, so the
   script fails before anything compiles. It is `mavenCentral()` now (JCenter
   shut down in 2021; the plugin's own dependency comes from JitPack, which is
   still listed).
2. It compiles against Android API 33. Its AndroidX dependencies require 34 or
   later, which AGP 9 enforces for libraries too. It now compiles against
   `flutter.compileSdkVersion`, as every other module does.

The plugin's Java code is unchanged.

## Dropping this copy

When a release of `usb_serial` builds under AGP 9 and Gradle 9, go back to it
in `frontend/pubspec.yaml` and delete this directory.
