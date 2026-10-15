import 'dart:io';

import 'package:flutter/services.dart';

import 'local_server_host.dart';

LocalServerHostPlatform createLocalServerHostPlatform() =>
    Platform.isWindows ? WindowsLocalServerHost() : const NoLocalServerHost();

/// The keeper's files under `%ProgramData%\Pointy` (see
/// `deploy/onprem/wsl/keep-pointy-running.ps1`), and the runner's
/// `pointy/server_host` channel for what needs Win32.
class WindowsLocalServerHost implements LocalServerHostPlatform {
  WindowsLocalServerHost({String? programData, MethodChannel? channel})
    : _root =
          '${programData ?? Platform.environment['ProgramData'] ?? r'C:\ProgramData'}'
          '${Platform.pathSeparator}Pointy',
      _channel = channel ?? const MethodChannel('pointy/server_host');

  final String _root;
  final MethodChannel _channel;

  File _file(String name) => File('$_root${Platform.pathSeparator}$name');

  /// The server PC, whether or not its keeper was ever installed: the till
  /// carries one and can install it. Moved to Linux, it is not one any more.
  @override
  Future<bool> isServerPc() async {
    try {
      if (await _file('MOVED-TO-LINUX.txt').exists()) {
        return false;
      }
      // What the installer leaves behind, keeper or not.
      if (await _file('keep-pointy-running.ps1').exists() ||
          await _file('bootstrap-wsl.ps1').exists()) {
        return true;
      }
    } on FileSystemException {
      return false;
    }
    // WSL's own registration of the distro, for this Windows user.
    return await _call<bool>('hasDistro') ?? false;
  }

  @override
  String get logPath =>
      _file('logs${Platform.pathSeparator}keepalive.log').path;

  @override
  Future<KeeperHeartbeat?> readHeartbeat() async {
    try {
      return KeeperHeartbeat.parse(
        await _file('keepalive-state.json').readAsString(),
      );
    } on FileSystemException {
      return null;
    }
  }

  @override
  Future<KeeperStartOutcome> startKeeper() async =>
      KeeperStartOutcome.parse(await _call('start'));

  @override
  Future<bool> registerSignInStart() async =>
      await _call<bool>('registerSignInStart') ?? false;

  @override
  Future<KeeperSetupOutcome> runSetup() async =>
      KeeperSetupOutcome.parse(await _call('repair'));

  @override
  Future<KeeperSetupOutcome> runKeeperElevated() async =>
      KeeperSetupOutcome.parse(await _call('runElevated'));

  Future<T?> _call<T>(String method) async {
    try {
      return await _channel.invokeMethod<T>(method);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }
}
