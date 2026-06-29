#include "autostart_channel.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>

#include <memory>
#include <string>
#include <variant>

namespace {

constexpr wchar_t kRunKeyPath[] =
    L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";
// Stable value name so isEnabled/setEnabled and the installer's uninstall
// cleanup all refer to the same entry.
constexpr wchar_t kValueName[] = L"Pointy";

std::wstring ExecutablePath() {
  wchar_t buffer[MAX_PATH];
  DWORD length = ::GetModuleFileNameW(nullptr, buffer, MAX_PATH);
  if (length == 0 || length >= MAX_PATH) {
    return std::wstring();
  }
  return std::wstring(buffer, length);
}

std::wstring QuotedExecutablePath() {
  std::wstring path = ExecutablePath();
  if (path.empty()) {
    return path;
  }
  return L"\"" + path + L"\"";
}

bool GetBoolArg(const flutter::EncodableMap& map, const char* key) {
  auto it = map.find(flutter::EncodableValue(std::string(key)));
  if (it == map.end()) {
    return false;
  }
  if (const auto* value = std::get_if<bool>(&it->second)) {
    return *value;
  }
  return false;
}

bool IsRegistered() {
  HKEY key = nullptr;
  if (::RegOpenKeyExW(HKEY_CURRENT_USER, kRunKeyPath, 0, KEY_QUERY_VALUE,
                      &key) != ERROR_SUCCESS) {
    return false;
  }
  DWORD type = 0;
  DWORD size = 0;
  LONG status =
      ::RegQueryValueExW(key, kValueName, nullptr, &type, nullptr, &size);
  ::RegCloseKey(key);
  return status == ERROR_SUCCESS && type == REG_SZ && size > 0;
}

bool SetRegistered(bool enabled) {
  HKEY key = nullptr;
  if (::RegCreateKeyExW(HKEY_CURRENT_USER, kRunKeyPath, 0, nullptr,
                        REG_OPTION_NON_VOLATILE, KEY_SET_VALUE, nullptr, &key,
                        nullptr) != ERROR_SUCCESS) {
    return false;
  }
  LONG status;
  if (enabled) {
    const std::wstring value = QuotedExecutablePath();
    if (value.empty()) {
      ::RegCloseKey(key);
      return false;
    }
    const DWORD bytes =
        static_cast<DWORD>((value.size() + 1) * sizeof(wchar_t));
    status = ::RegSetValueExW(key, kValueName, 0, REG_SZ,
                              reinterpret_cast<const BYTE*>(value.c_str()),
                              bytes);
  } else {
    status = ::RegDeleteValueW(key, kValueName);
    // Removing an entry that was never there is success for our purposes.
    if (status == ERROR_FILE_NOT_FOUND) {
      status = ERROR_SUCCESS;
    }
  }
  ::RegCloseKey(key);
  return status == ERROR_SUCCESS;
}

void HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (call.method_name() == "isEnabled") {
    result->Success(flutter::EncodableValue(IsRegistered()));
    return;
  }
  if (call.method_name() == "setEnabled") {
    const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
    if (args == nullptr) {
      result->Error("bad_args", "expected a map argument");
      return;
    }
    const bool enabled = GetBoolArg(*args, "enabled");
    if (!SetRegistered(enabled)) {
      result->Error("registry_failed", "could not update the startup entry");
      return;
    }
    result->Success(flutter::EncodableValue(enabled));
    return;
  }
  result->NotImplemented();
}

}  // namespace

void RegisterAutoStartChannel(flutter::FlutterEngine* engine) {
  static std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      channel;
  channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      engine->messenger(), "pointy/autostart",
      &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
             result) { HandleMethodCall(call, std::move(result)); });
}
