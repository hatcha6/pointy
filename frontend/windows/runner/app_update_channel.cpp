#include "app_update_channel.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>
#include <shellapi.h>

#include <memory>
#include <string>
#include <variant>

namespace {

std::wstring Utf8ToWide(const std::string& input) {
  if (input.empty()) {
    return std::wstring();
  }
  int length = ::MultiByteToWideChar(
      CP_UTF8, 0, input.c_str(), static_cast<int>(input.size()), nullptr, 0);
  std::wstring output(length, L'\0');
  ::MultiByteToWideChar(
      CP_UTF8, 0, input.c_str(), static_cast<int>(input.size()), &output[0],
      length);
  return output;
}

std::string GetStringArg(const flutter::EncodableMap& map, const char* key) {
  auto it = map.find(flutter::EncodableValue(std::string(key)));
  if (it == map.end()) {
    return std::string();
  }
  if (const auto* value = std::get_if<std::string>(&it->second)) {
    return *value;
  }
  return std::string();
}

void HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (call.method_name() == "runInstaller") {
    const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
    if (args == nullptr) {
      result->Error("bad_args", "expected a map argument");
      return;
    }
    const std::string path = GetStringArg(*args, "path");
    if (path.empty()) {
      result->Error("bad_args", "missing installer path");
      return;
    }
    const std::wstring widePath = Utf8ToWide(path);
    HINSTANCE rc = ::ShellExecuteW(
        nullptr, L"open", widePath.c_str(), nullptr, nullptr, SW_SHOWNORMAL);
    if (reinterpret_cast<INT_PTR>(rc) <= 32) {
      result->Error("launch_failed", "could not start the installer");
      return;
    }
    result->Success();
    // Quit so the installer can replace the running executable. The Inno Setup
    // installer (CloseApplications=yes) also closes us, but exiting promptly
    // avoids a "file in use" stall.
    ::PostQuitMessage(0);
    return;
  }
  result->NotImplemented();
}

}  // namespace

void RegisterAppUpdateChannel(flutter::FlutterEngine* engine) {
  static std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel;
  channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      engine->messenger(), "pointy/app_update",
      &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        HandleMethodCall(call, std::move(result));
      });
}
