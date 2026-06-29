#ifndef RUNNER_AUTOSTART_CHANNEL_H_
#define RUNNER_AUTOSTART_CHANNEL_H_

#include <flutter/flutter_engine.h>

// Registers the `pointy/autostart` method channel.
//
// Controls whether the app launches automatically at user login by writing a
// value to `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` pointing at the
// current executable. Used for price-checker kiosks (and anyone who wants the
// client to come back up after a reboot). The matching Dart side is
// `AutoStartService`.
//
//   isEnabled()            -> bool   (is the Run value present?)
//   setEnabled({enabled})  -> bool   (write/remove the Run value)
//
// Per-user (HKCU), so it needs no elevation. The channel is kept alive for the
// lifetime of the engine.
void RegisterAutoStartChannel(flutter::FlutterEngine* engine);

#endif  // RUNNER_AUTOSTART_CHANNEL_H_
