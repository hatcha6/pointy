#include "server_host.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>
#include <shellapi.h>
#include <taskschd.h>

#include <fstream>
#include <iterator>
#include <memory>
#include <string>

#include "utils.h"

namespace {

// keep-pointy-running.ps1's $TaskName.
constexpr wchar_t kKeeperTaskName[] = L"PointyKeepAlive";
constexpr wchar_t kRunKeyPath[] =
    L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";
// Not "Pointy": that one is the till's own opt-in "run on startup" entry.
constexpr wchar_t kRunValueName[] = L"PointyServer";

template <typename T>
void SafeRelease(T*& pointer) {
  if (pointer != nullptr) {
    pointer->Release();
    pointer = nullptr;
  }
}

std::string OutcomeForError(HRESULT hr) {
  // A task this user may not read is reported as absent, not as denied.
  if (hr == HRESULT_FROM_WIN32(ERROR_FILE_NOT_FOUND) ||
      hr == HRESULT_FROM_WIN32(ERROR_PATH_NOT_FOUND)) {
    return "missing";
  }
  if (hr == E_ACCESSDENIED) {
    return "denied";
  }
  return "failed";
}

std::wstring ProgramDataPath() {
  wchar_t buffer[MAX_PATH];
  DWORD length = ::GetEnvironmentVariableW(L"ProgramData", buffer, MAX_PATH);
  if (length == 0 || length >= MAX_PATH) {
    return std::wstring();
  }
  return std::wstring(buffer, length);
}

// keep-pointy-running.ps1's -Distro default.
constexpr wchar_t kDistroName[] = L"Pointy";
constexpr wchar_t kLxssKeyPath[] =
    L"Software\\Microsoft\\Windows\\CurrentVersion\\Lxss";
// The keeper's "# pointy-keeper-revision: N" line. Whichever of the installed
// and the carried keeper has the higher one runs, so neither an older server
// nor an older till ever puts back a keeper the other has outgrown.
constexpr char kKeeperRevisionTag[] = "pointy-keeper-revision:";

bool FileExists(const std::wstring& path) {
  const DWORD attributes = ::GetFileAttributesW(path.c_str());
  return attributes != INVALID_FILE_ATTRIBUTES &&
         (attributes & FILE_ATTRIBUTE_DIRECTORY) == 0;
}

// 0 for a keeper without a revision (one older than revisions), or no file.
int KeeperRevision(const std::wstring& path) {
  std::ifstream file(path, std::ios::binary);
  if (!file) {
    return 0;
  }
  std::string line;
  while (std::getline(file, line)) {
    const size_t start = line.find_first_not_of(" \t");
    if (start == std::string::npos || line[start] != '#') {
      continue;
    }
    const size_t tag = line.find(kKeeperRevisionTag, start);
    if (tag == std::string::npos) {
      continue;
    }
    int revision = 0;
    for (size_t i = tag + sizeof(kKeeperRevisionTag) - 1; i < line.size();
         ++i) {
      const char c = line[i];
      if (c >= '0' && c <= '9') {
        revision = revision * 10 + (c - '0');
      } else if (c != ' ' && c != '\t' && c != '\r') {
        return 0;
      }
    }
    return revision;
  }
  return 0;
}

// The keeper this PC has installed, or the one this till carries
// (data\server, from the deploy tree at build time) when the PC has none or
// only a lower revision. Run from there, -Install copies the carried keeper
// into place. Empty when there is neither.
std::wstring ResolveKeeperScript() {
  const std::wstring program_data = ProgramDataPath();
  const std::wstring installed =
      program_data.empty()
          ? std::wstring()
          : program_data + L"\\Pointy\\keep-pointy-running.ps1";
  const bool has_installed = !installed.empty() && FileExists(installed);
  std::wstring carried;
  const std::wstring executable = ExecutablePath();
  const size_t slash = executable.find_last_of(L'\\');
  if (slash != std::wstring::npos) {
    carried = executable.substr(0, slash) +
              L"\\data\\server\\keep-pointy-running.ps1";
    if (!FileExists(carried)) {
      carried.clear();
    }
  }
  if (carried.empty()) {
    return has_installed ? installed : std::wstring();
  }
  if (has_installed && KeeperRevision(installed) >= KeeperRevision(carried)) {
    return installed;
  }
  return carried;
}

// Whether this Windows user has the Pointy distro: WSL's own per-user
// registration, read without starting wsl.exe.
bool HasPointyDistro() {
  HKEY lxss = nullptr;
  if (::RegOpenKeyExW(HKEY_CURRENT_USER, kLxssKeyPath, 0,
                      KEY_ENUMERATE_SUB_KEYS | KEY_QUERY_VALUE,
                      &lxss) != ERROR_SUCCESS) {
    return false;
  }
  bool found = false;
  wchar_t subkey[256];
  for (DWORD index = 0; !found; ++index) {
    DWORD subkey_length = static_cast<DWORD>(std::size(subkey));
    if (::RegEnumKeyExW(lxss, index, subkey, &subkey_length, nullptr, nullptr,
                        nullptr, nullptr) != ERROR_SUCCESS) {
      break;
    }
    wchar_t name[256];
    DWORD name_bytes = sizeof(name);
    if (::RegGetValueW(lxss, subkey, L"DistributionName", RRF_RT_REG_SZ,
                       nullptr, name, &name_bytes) == ERROR_SUCCESS) {
      found = ::_wcsicmp(name, kDistroName) == 0;
    }
  }
  ::RegCloseKey(lxss);
  return found;
}

// HKCU Run: what Windows starts at this user's sign-in. Rewritten every time,
// so an install that moved keeps pointing at the right executable.
bool RegisterSignInStart() {
  const std::wstring executable = QuotedExecutablePath();
  if (executable.empty()) {
    return false;
  }
  const std::wstring value =
      executable + L" " + std::wstring(kStartServerSwitch);
  HKEY key = nullptr;
  if (::RegCreateKeyExW(HKEY_CURRENT_USER, kRunKeyPath, 0, nullptr,
                        REG_OPTION_NON_VOLATILE, KEY_SET_VALUE, nullptr, &key,
                        nullptr) != ERROR_SUCCESS) {
    return false;
  }
  const DWORD bytes = static_cast<DWORD>((value.size() + 1) * sizeof(wchar_t));
  const LONG status =
      ::RegSetValueExW(key, kRunValueName, 0, REG_SZ,
                       reinterpret_cast<const BYTE*>(value.c_str()), bytes);
  ::RegCloseKey(key);
  return status == ERROR_SUCCESS;
}

// The keeper, elevated: one UAC prompt. Either way the client then waits on
// the keeper's heartbeat. One of "launched", "cancelled" (the prompt was
// refused), "missing" (no keeper, installed or carried), "failed".
enum class KeeperLaunch {
  // -Install, hidden: re-registers the task so signed-in users may start it,
  // and starts it. For a PC whose task is missing or predates that grant.
  kInstall,
  // The keeper itself with -Restart, in a minimised console of this session:
  // it stops a stuck keeper, shuts WSL down, and starts the task again - or,
  // when the task starts nothing, keeps running in that console itself. The
  // last resort when the task does not bring the server up; what staff did by
  // hand - an elevated PowerShell with wsl in it - as a button.
  kRun,
};

std::string LaunchKeeperElevated(KeeperLaunch mode) {
  const std::wstring script = ResolveKeeperScript();
  if (script.empty()) {
    return "missing";
  }
  wchar_t system_dir[MAX_PATH];
  const UINT length = ::GetSystemDirectoryW(system_dir, MAX_PATH);
  if (length == 0 || length >= MAX_PATH) {
    return "failed";
  }
  const std::wstring system32(system_dir, length);
  const std::wstring powershell =
      system32 + L"\\WindowsPowerShell\\v1.0\\powershell.exe";
  const std::wstring script_arguments =
      L"-NoProfile -ExecutionPolicy Bypass -File \"" + script + L"\"";

  std::wstring file;
  std::wstring parameters;
  int show;
  if (mode == KeeperLaunch::kInstall) {
    file = powershell;
    parameters = L"-WindowStyle Hidden " + script_arguments + L" -Install";
    show = SW_HIDE;
  } else {
    // Through the classic console host, as the keeper's task does: Windows
    // Terminal, the default on Windows 11, neither starts minimised reliably
    // nor lets the keeper take its close button away.
    file = system32 + L"\\conhost.exe";
    parameters = L"\"" + powershell + L"\" -WindowStyle Minimized " +
                 script_arguments + L" -Restart";
    show = SW_SHOWMINNOACTIVE;
  }

  SHELLEXECUTEINFOW info = {};
  info.cbSize = sizeof(info);
  info.fMask = SEE_MASK_NOASYNC;
  // Owned by the till's window: without an owner Windows may raise the
  // administrator prompt behind the till or only flash it in the taskbar,
  // and the button looks as if it did nothing.
  info.hwnd = ::GetActiveWindow();
  if (info.hwnd == nullptr) {
    info.hwnd = ::GetForegroundWindow();
  }
  info.lpVerb = L"runas";
  info.lpFile = file.c_str();
  info.lpParameters = parameters.c_str();
  info.nShow = show;
  if (!::ShellExecuteExW(&info)) {
    return ::GetLastError() == ERROR_CANCELLED ? "cancelled" : "failed";
  }
  return "launched";
}

void HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method = call.method_name();
  if (method == "start") {
    result->Success(flutter::EncodableValue(StartServerKeeper()));
    return;
  }
  if (method == "hasDistro") {
    result->Success(flutter::EncodableValue(HasPointyDistro()));
    return;
  }
  if (method == "registerSignInStart") {
    result->Success(flutter::EncodableValue(RegisterSignInStart()));
    return;
  }
  if (method == "repair") {
    result->Success(
        flutter::EncodableValue(LaunchKeeperElevated(KeeperLaunch::kInstall)));
    return;
  }
  if (method == "runElevated") {
    result->Success(
        flutter::EncodableValue(LaunchKeeperElevated(KeeperLaunch::kRun)));
    return;
  }
  result->NotImplemented();
}

}  // namespace

std::string StartServerKeeper() {
  // S_FALSE (this thread already had COM) needs balancing as well;
  // RPC_E_CHANGED_MODE means it had COM in another mode, which serves too.
  const HRESULT init = ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  const bool balance_init = SUCCEEDED(init);

  ITaskService* service = nullptr;
  ITaskFolder* folder = nullptr;
  IRegisteredTask* task = nullptr;
  IRunningTask* running = nullptr;
  std::string outcome = "failed";

  HRESULT hr = ::CoCreateInstance(CLSID_TaskScheduler, nullptr,
                                  CLSCTX_INPROC_SERVER, IID_ITaskService,
                                  reinterpret_cast<void**>(&service));
  if (SUCCEEDED(hr)) {
    VARIANT empty;
    ::VariantInit(&empty);
    hr = service->Connect(empty, empty, empty, empty);
  }
  if (SUCCEEDED(hr)) {
    BSTR root = ::SysAllocString(L"\\");
    hr = service->GetFolder(root, &folder);
    ::SysFreeString(root);
  }
  if (SUCCEEDED(hr)) {
    BSTR name = ::SysAllocString(kKeeperTaskName);
    hr = folder->GetTask(name, &task);
    ::SysFreeString(name);
  }
  if (SUCCEEDED(hr)) {
    VARIANT_BOOL enabled = VARIANT_TRUE;
    TASK_STATE state = TASK_STATE_UNKNOWN;
    task->get_Enabled(&enabled);
    task->get_State(&state);
    if (enabled == VARIANT_FALSE) {
      outcome = "disabled";
    } else if (state == TASK_STATE_RUNNING) {
      outcome = "running";
    } else {
      VARIANT no_parameters;
      ::VariantInit(&no_parameters);
      hr = task->Run(no_parameters, &running);
      outcome = SUCCEEDED(hr) ? "started" : OutcomeForError(hr);
    }
  } else {
    outcome = OutcomeForError(hr);
  }

  SafeRelease(running);
  SafeRelease(task);
  SafeRelease(folder);
  SafeRelease(service);
  if (balance_init) {
    ::CoUninitialize();
  }
  return outcome;
}

void RegisterServerHostChannel(flutter::FlutterEngine* engine) {
  static std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      channel;
  channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      engine->messenger(), "pointy/server_host",
      &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
             result) { HandleMethodCall(call, std::move(result)); });
}
