#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

// One running copy per machine. The till's operators launch the app by
// double-clicking, and a second copy started seconds after the first opens
// the same local SQLite store — field telemetry showed both "database is
// locked" crashes landing 90 ms after a second app start. A named mutex held
// for the process lifetime makes the second copy hand over to the first
// (bringing its window forward) instead of racing it.
namespace {

constexpr const wchar_t kSingleInstanceMutexName[] =
    L"Local\\PointyPosSingleInstance";
constexpr const wchar_t kWindowTitle[] = L"pointy_frontend";

// Owned for the whole process; released by the OS on exit.
HANDLE g_single_instance_mutex = nullptr;

bool AcquireSingleInstance() {
  g_single_instance_mutex =
      ::CreateMutexW(nullptr, TRUE, kSingleInstanceMutexName);
  return g_single_instance_mutex != nullptr &&
         ::GetLastError() != ERROR_ALREADY_EXISTS;
}

void ActivateRunningInstance() {
  HWND existing =
      ::FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", kWindowTitle);
  if (existing == nullptr) {
    // The app may have renamed its window; any window of our runner class
    // on this desktop is ours.
    existing = ::FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", nullptr);
  }
  if (existing == nullptr) {
    return;
  }
  if (::IsIconic(existing)) {
    ::ShowWindow(existing, SW_RESTORE);
  }
  ::SetForegroundWindow(existing);
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  if (!AcquireSingleInstance()) {
    ActivateRunningInstance();
    return EXIT_SUCCESS;
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(kWindowTitle, origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
