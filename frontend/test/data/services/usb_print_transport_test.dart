import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/models/printer_config.dart';
import 'package:pointy_frontend/src/data/services/usb_print_transport_io.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('pointy/usb_print');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  UsbPrintTransport buildTransport() => UsbPrintTransport(channel: channel);

  const printerEndpoint = PrinterEndpoint(
    kind: PrintTransportKind.usb,
    name: 'Epson TM-T20',
    address: 'printer:04b8:0202',
  );

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('discover maps native devices to usb endpoints', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'listDevices');
      return <Object?>[
        <Object?, Object?>{
          'address': 'printer:04b8:0202',
          'name': 'Epson TM-T20',
        },
        <Object?, Object?>{'address': 'serial:1a86:7523', 'name': ''},
      ];
    });

    final endpoints = await buildTransport().discover();

    expect(endpoints, hasLength(2));
    expect(endpoints.first.kind, PrintTransportKind.usb);
    expect(endpoints.first.address, 'printer:04b8:0202');
    expect(endpoints.first.name, 'Epson TM-T20');
    // Falls back to the address when the native name is blank.
    expect(endpoints[1].name, 'serial:1a86:7523');
  });

  test(
    'printBytes routes printer-class devices to the native channel',
    () async {
      MethodCall? received;
      messenger.setMockMethodCallHandler(channel, (call) async {
        received = call;
        return <Object?, Object?>{'success': true, 'message': 'ok'};
      });

      final result = await buildTransport().printBytes(
        bytes: const [1, 2, 3],
        endpoint: printerEndpoint,
      );

      expect(result.isSuccess, isTrue);
      expect(received?.method, 'write');
      final args = received!.arguments as Map;
      // The route prefix is stripped before the address reaches native code.
      expect(args['address'], '04b8:0202');
      expect(args['bytes'], isA<Uint8List>());
    },
  );

  test(
    'printBytes fails gracefully when no native handler is registered',
    () async {
      // No mock handler → MissingPluginException, surfaced as a failure result
      // rather than an exception (the inert macOS/iOS case).
      final result = await buildTransport().printBytes(
        bytes: const [1, 2, 3],
        endpoint: printerEndpoint,
      );

      expect(result.isSuccess, isFalse);
      expect(result.message.toLowerCase(), contains('not supported'));
    },
  );

  test('discover returns empty when the platform has no handler', () async {
    expect(await buildTransport().discover(), isEmpty);
  });
}
