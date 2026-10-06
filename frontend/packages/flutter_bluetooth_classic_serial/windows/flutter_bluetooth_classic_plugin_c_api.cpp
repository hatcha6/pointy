#include "include/flutter_bluetooth_classic_serial/flutter_bluetooth_classic_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "include/flutter_bluetooth_classic_serial/flutter_bluetooth_classic_plugin.h"

void FlutterBluetoothClassicPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  flutter_bluetooth_classic::FlutterBluetoothClassicPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
