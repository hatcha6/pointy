#ifndef RUNNER_APP_UPDATE_CHANNEL_H_
#define RUNNER_APP_UPDATE_CHANNEL_H_

#include <flutter/flutter_engine.h>

// Registers the `pointy/app_update` method channel.
//
// `runInstaller(path)` launches a downloaded Windows installer (the Inno Setup
// `-setup.exe`) and quits the app so the installer can upgrade it in place. The
// matching Dart side is `ClientUpdateService` / `AppInstaller`.
//
// The channel is kept alive for the lifetime of the engine.
void RegisterAppUpdateChannel(flutter::FlutterEngine* engine);

#endif  // RUNNER_APP_UPDATE_CHANNEL_H_
