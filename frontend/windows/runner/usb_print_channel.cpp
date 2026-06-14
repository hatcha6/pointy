#include "usb_print_channel.h"

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <windows.h>
#include <winspool.h>
#include <wchar.h>

#include <memory>
#include <string>
#include <vector>

namespace {

std::string Utf8FromWide(const wchar_t* wide) {
  if (wide == nullptr) {
    return std::string();
  }
  int len = WideCharToMultiByte(CP_UTF8, 0, wide, -1, nullptr, 0, nullptr, nullptr);
  if (len <= 1) {
    return std::string();
  }
  std::string out(static_cast<size_t>(len - 1), '\0');
  WideCharToMultiByte(CP_UTF8, 0, wide, -1, out.data(), len, nullptr, nullptr);
  return out;
}

std::wstring WideFromUtf8(const std::string& utf8) {
  if (utf8.empty()) {
    return std::wstring();
  }
  int len = MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), -1, nullptr, 0);
  if (len <= 1) {
    return std::wstring();
  }
  std::wstring out(static_cast<size_t>(len - 1), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), -1, out.data(), len);
  return out;
}

std::string GetString(const flutter::EncodableMap& map, const char* key) {
  auto it = map.find(flutter::EncodableValue(std::string(key)));
  if (it != map.end()) {
    if (const auto* value = std::get_if<std::string>(&it->second)) {
      return *value;
    }
  }
  return std::string();
}

std::vector<uint8_t> GetBytes(const flutter::EncodableMap& map, const char* key) {
  auto it = map.find(flutter::EncodableValue(std::string(key)));
  if (it != map.end()) {
    if (const auto* value = std::get_if<std::vector<uint8_t>>(&it->second)) {
      return *value;
    }
  }
  return std::vector<uint8_t>();
}

flutter::EncodableValue ListPrinters() {
  flutter::EncodableList devices;
  DWORD needed = 0;
  DWORD count = 0;
  const DWORD flags = PRINTER_ENUM_LOCAL | PRINTER_ENUM_CONNECTIONS;
  EnumPrintersW(flags, nullptr, 2, nullptr, 0, &needed, &count);
  if (needed == 0) {
    return flutter::EncodableValue(devices);
  }
  std::vector<BYTE> buffer(needed);
  if (!EnumPrintersW(flags, nullptr, 2, buffer.data(), needed, &needed, &count)) {
    return flutter::EncodableValue(devices);
  }
  auto* printers = reinterpret_cast<PRINTER_INFO_2W*>(buffer.data());
  for (DWORD i = 0; i < count; i++) {
    const wchar_t* port = printers[i].pPortName;
    // Default-filter to USB-attached queues.
    if (port == nullptr || _wcsnicmp(port, L"USB", 3) != 0) {
      continue;
    }
    std::string name = Utf8FromWide(printers[i].pPrinterName);
    if (name.empty()) {
      continue;
    }
    flutter::EncodableMap device;
    device[flutter::EncodableValue("address")] = flutter::EncodableValue(name);
    device[flutter::EncodableValue("name")] = flutter::EncodableValue(name);
    device[flutter::EncodableValue("route")] = flutter::EncodableValue("printer");
    device[flutter::EncodableValue("port")] =
        flutter::EncodableValue(Utf8FromWide(port));
    devices.push_back(flutter::EncodableValue(device));
  }
  return flutter::EncodableValue(devices);
}

flutter::EncodableValue WriteRaw(const std::string& printer_name,
                                 const std::vector<uint8_t>& bytes) {
  flutter::EncodableMap out;
  auto reply = [&out](bool success, const std::string& message) {
    out[flutter::EncodableValue("success")] = flutter::EncodableValue(success);
    out[flutter::EncodableValue("message")] = flutter::EncodableValue(message);
    return flutter::EncodableValue(out);
  };

  if (printer_name.empty()) {
    return reply(false, "printer name is required");
  }
  std::wstring wname = WideFromUtf8(printer_name);
  HANDLE printer = nullptr;
  if (!OpenPrinterW(const_cast<LPWSTR>(wname.c_str()), &printer, nullptr)) {
    return reply(false, "failed to open printer");
  }

  DOC_INFO_1W doc_info;
  doc_info.pDocName = const_cast<LPWSTR>(L"Pointy");
  doc_info.pOutputFile = nullptr;
  doc_info.pDatatype = const_cast<LPWSTR>(L"RAW");

  bool ok = false;
  std::string message = "usb print failed";
  DWORD job = StartDocPrinterW(printer, 1, reinterpret_cast<LPBYTE>(&doc_info));
  if (job != 0) {
    if (StartPagePrinter(printer)) {
      DWORD written = 0;
      BOOL wrote = WritePrinter(
          printer,
          const_cast<uint8_t*>(bytes.data()),
          static_cast<DWORD>(bytes.size()),
          &written);
      EndPagePrinter(printer);
      ok = wrote && written == bytes.size();
      message = ok ? "usb print sent" : "WritePrinter failed";
    } else {
      message = "StartPagePrinter failed";
    }
    EndDocPrinter(printer);
  } else {
    message = "StartDocPrinter failed";
  }
  ClosePrinter(printer);
  return reply(ok, message);
}

void HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method = call.method_name();
  if (method == "listDevices") {
    result->Success(ListPrinters());
    return;
  }
  if (method == "write") {
    const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
    if (args == nullptr) {
      result->Error("bad_args", "expected a map argument");
      return;
    }
    result->Success(WriteRaw(GetString(*args, "address"), GetBytes(*args, "bytes")));
    return;
  }
  if (method == "transceive") {
    // RAW spooler printing is one-way; the label-language detector falls back
    // to name-based detection / the configured language.
    flutter::EncodableMap out;
    out[flutter::EncodableValue("success")] = flutter::EncodableValue(false);
    out[flutter::EncodableValue("message")] =
        flutter::EncodableValue("usb probes unsupported on windows");
    result->Success(flutter::EncodableValue(out));
    return;
  }
  result->NotImplemented();
}

}  // namespace

void RegisterUsbPrintChannel(flutter::FlutterEngine* engine) {
  static std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel;
  channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      engine->messenger(),
      "pointy/usb_print",
      &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        HandleMethodCall(call, std::move(result));
      });
}
