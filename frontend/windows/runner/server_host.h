#ifndef RUNNER_SERVER_HOST_H_
#define RUNNER_SERVER_HOST_H_

#include <flutter/flutter_engine.h>

#include <string>

// The PC that runs the shop's server inside WSL keeps it running through the
// keeper (deploy/onprem/wsl/keep-pointy-running.ps1), a scheduled task that
// runs elevated in the signed-in session. The client is what starts it: at
// sign-in (`--start-server`, from the "PointyServer" Run entry), when the till
// opens, and every minute while it is open. Starting a task this way needs no
// administrator and shows no prompt; -Install grants signed-in users that.

// Command-line switch for the sign-in start: start the keeper and exit,
// without a window or the single-instance lock.
constexpr const wchar_t kStartServerSwitch[] = L"--start-server";

// Starts the keeper's task. One of: "started", "running" (it already was),
// "missing" (not installed, or this user may not see it), "denied" (visible
// but this user may not run it), "disabled", "failed".
std::string StartServerKeeper();

// Registers the `pointy/server_host` method channel. See
// lib/src/data/services/local_server_host_io.dart.
void RegisterServerHostChannel(flutter::FlutterEngine* engine);

#endif  // RUNNER_SERVER_HOST_H_
