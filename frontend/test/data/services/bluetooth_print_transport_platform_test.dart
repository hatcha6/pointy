import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/models/printer_config.dart';
import 'package:pointy_frontend/src/data/services/bluetooth_print_transport_io.dart';

/// The `flutter_bluetooth_classic_serial` package declares a `linux` platform
/// in its pubspec but ships no native code behind it — its `linux/` directory
/// is only the example app's runner scaffolding. So on Linux the channel is
/// never registered and every call throws `MissingPluginException`.
///
/// That is what the shop's Linux back-office machine did **114 times in nine
/// days**, which was 114 of its 128 non-camera errors. The transport must not
/// call the plugin on a platform that has no implementation.
///
/// These tests run on the host, so they exercise the unsupported branch on
/// macOS and Linux and the supported branch on Windows.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const endpoint = PrinterEndpoint(
    kind: PrintTransportKind.bluetooth,
    name: 'HPRT LPQ80',
    address: '00:11:22:33:44:55',
  );

  final hasImplementation =
      Platform.isAndroid || Platform.isIOS || Platform.isWindows;

  setUp(BluetoothPrintTransport.resetPluginAvailability);
  tearDown(BluetoothPrintTransport.resetPluginAvailability);

  // First on purpose: the plugin is a per-process singleton that subscribes to
  // its channels once, in its constructor, so only the first construction in a
  // process could show the bug.
  test('building and using the transport never touches the plugin\'s '
      'channels on a platform with no implementation', () async {
    if (hasImplementation) {
      return;
    }
    // What the Linux back office logged on every launch: the plugin's
    // constructor asks its state, connection and data channels to `listen`,
    // and the failures go straight to FlutterError.onError, where no
    // try/catch of ours can reach them.
    const channels = [
      'com.flutter_bluetooth_classic.plugin/flutter_bluetooth_classic_state',
      'com.flutter_bluetooth_classic.plugin/flutter_bluetooth_classic_connection',
      'com.flutter_bluetooth_classic.plugin/flutter_bluetooth_classic_data',
    ];
    final calls = <String>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final name in channels) {
      messenger.setMockMethodCallHandler(MethodChannel(name), (call) async {
        calls.add('$name ${call.method}');
        return null;
      });
    }
    addTearDown(() {
      for (final name in channels) {
        messenger.setMockMethodCallHandler(MethodChannel(name), null);
      }
    });
    final reported = <FlutterErrorDetails>[];
    final previousOnError = FlutterError.onError;
    FlutterError.onError = reported.add;
    addTearDown(() => FlutterError.onError = previousOnError);

    final transport = BluetoothPrintTransport();
    await transport.discover();
    await transport.status(endpoint);
    await transport.printBytes(bytes: const [0x1b, 0x40], endpoint: endpoint);
    await pumpEventQueue();

    expect(calls, isEmpty);
    expect(reported, isEmpty);
  });

  test('discovery is silent on a platform with no implementation', () async {
    if (hasImplementation) {
      return;
    }
    // No plugin call means no MissingPluginException to swallow, log or report.
    // If this ever throws, the guard has been removed.
    expect(await BluetoothPrintTransport().discover(), isEmpty);
  });

  test('status says unsupported rather than failing', () async {
    if (hasImplementation) {
      return;
    }
    final status = await BluetoothPrintTransport().status(endpoint);
    expect(status.isAvailable, isFalse);
    expect(status.message, contains('not supported'));
  });

  test('printing refuses without dialling the plugin', () async {
    if (hasImplementation) {
      return;
    }
    final result = await BluetoothPrintTransport().printBytes(
      bytes: const [0x1b, 0x40],
      endpoint: endpoint,
    );
    expect(result.isSuccess, isFalse);
    expect(result.message, contains('not supported on this platform'));
  });

  test('an empty address is still rejected on its own terms', () async {
    if (!hasImplementation) {
      return;
    }
    final result = await BluetoothPrintTransport().printBytes(
      bytes: const [0x1b, 0x40],
      endpoint: const PrinterEndpoint(
        kind: PrintTransportKind.bluetooth,
        name: 'unpaired',
        address: '   ',
      ),
    );
    expect(result.isSuccess, isFalse);
    expect(result.message, contains('address is required'));
  });
}
