# Pointy's copy of `flutter_bluetooth_classic_serial` 1.3.2

This is `flutter_bluetooth_classic_serial` 1.3.2 from pub.dev, its latest
release (October 2025). Only `android/build.gradle` and `pubspec.yaml` differ
from upstream; every change there is marked `POINTY PATCH`. The pub.dev example, tests,
changelog, IDE files and the unused Gradle wrapper settings were left out.

## Why it is vendored

The app moved to Android Gradle Plugin 9 with Flutter 3.47, and upstream's
Android build script cannot build under it:

1. It applies the Kotlin Gradle plugin, which AGP 9 refuses once built-in
   Kotlin is on (`android.builtInKotlin=true` in `android/gradle.properties`).
   The script no longer applies it: AGP compiles the Kotlin, and with built-in
   Kotlin off Flutter applies the plugin itself. `kotlinOptions` is set only
   in that case.
2. It compiles against Android API 33. Its AndroidX dependencies require 34 or
   later, which AGP 9 enforces for libraries too. It now compiles against
   `flutter.compileSdkVersion`, as every other module does.

It also declares Linux support it does not have: its `linux/` directory is an
example *app* (it defines the `flutter` and `flutter_assemble` targets), with
no plugin target, so `flutter build linux` fails at CMake configure. The
`linux:` platform is removed from `pubspec.yaml`, so Flutter skips the plugin
on Linux; the directory is left as upstream shipped it. That is safe at run
time: `BluetoothPrintTransport` never constructs the plugin on Linux and just
offers no Bluetooth printers there (serial, USB and Wi-Fi printing work).
Before this copy, CI made the same edit to the pub cache before each Linux
build.

## Dropping this copy

When a release builds under AGP 9 with built-in Kotlin, go back to it in
`frontend/pubspec.yaml` and delete this directory.
