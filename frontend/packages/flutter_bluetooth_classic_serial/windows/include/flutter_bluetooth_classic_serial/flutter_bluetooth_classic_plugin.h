#ifndef FLUTTER_PLUGIN_FLUTTER_BLUETOOTH_CLASSIC_PLUGIN_H_
#define FLUTTER_PLUGIN_FLUTTER_BLUETOOTH_CLASSIC_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <flutter_plugin_registrar.h>

#include <memory>
#include <map>
#include <string>
#include <set>
#include <mutex>
#include <thread>

#ifdef FLUTTER_PLUGIN_IMPL
#define FLUTTER_PLUGIN_EXPORT __declspec(dllexport)
#else
#define FLUTTER_PLUGIN_EXPORT __declspec(dllimport)
#endif

namespace flutter_bluetooth_classic {

class FlutterBluetoothClassicPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

  FlutterBluetoothClassicPlugin();

  virtual ~FlutterBluetoothClassicPlugin();

  // Disallow copy and assign.
  FlutterBluetoothClassicPlugin(const FlutterBluetoothClassicPlugin&) = delete;
  FlutterBluetoothClassicPlugin& operator=(const FlutterBluetoothClassicPlugin&) = delete;

 private:
  // Called when a method is called on this plugin's channel from Dart.
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
      
  // Bluetooth helper methods
  bool IsBluetoothAvailable();
  bool IsBluetoothEnabled();
  void OpenBluetoothSettings();
  flutter::EncodableList GetPairedDevices();
  flutter::EncodableList StartDiscovery();
  bool ConnectToDevice(const flutter::EncodableValue* arguments);
  bool DisconnectDevice(const flutter::EncodableValue* arguments);
  bool IsDeviceConnected(const flutter::EncodableValue* arguments);
  bool WriteData(const flutter::EncodableValue* arguments);
  std::string ReadData(const flutter::EncodableValue* arguments);
  flutter::EncodableList GetConnectedDevices();
  
  // Data streaming methods
  void StartDataListening(const std::string& device_address);
  void DataListeningThread(const std::string& device_address, SOCKET sock);
  int GetAvailableBytes(const flutter::EncodableValue* arguments);
  bool FlushData(const flutter::EncodableValue* arguments);
  
  // Connection state management
  void NotifyConnectionStateChange(const flutter::EncodableValue* arguments, bool connected);
  
  // Data channel management
  void CleanupDataChannels(const flutter::EncodableValue* arguments);
  void CancelDataChannel(const flutter::EncodableValue* arguments);
  void CloseDataChannel(const flutter::EncodableValue* arguments);
  
  // Store connected sockets and data
  std::map<std::string, SOCKET> connected_sockets_;
  std::set<std::string> listening_devices_;
  std::map<std::string, std::string> received_data_;
  std::mutex data_mutex_;
};

}  // namespace flutter_bluetooth_classic

// Add this C function declaration before last endif
#if defined(__cplusplus)
extern "C" {
#endif

FLUTTER_PLUGIN_EXPORT void FlutterBluetoothClassicPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar);

#if defined(__cplusplus)
}  // extern "C"
#endif

#endif  // FLUTTER_PLUGIN_FLUTTER_BLUETOOTH_CLASSIC_PLUGIN_H_
