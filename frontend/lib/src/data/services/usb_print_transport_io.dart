import 'dart:async';

import 'package:flutter/services.dart';
import 'package:usb_serial/usb_serial.dart';

import '../models/print_job.dart';
import '../models/printer_config.dart';
import 'esc_pos_receipt_encoder.dart';
import 'print_transport.dart';
import 'print_write_queue.dart';

/// USB printing transport.
///
/// The device family is selected by a route prefix carried in
/// [PrinterEndpoint.address] (the native [discover] call supplies it):
///
///  * `printer:<vid>:<pid>` (Android) or a Windows printer-queue name — handled
///    natively over the `pointy/usb_print` method channel. On Android this is a
///    raw bulk transfer to a USB printer-class (0x07) device; on Windows it is a
///    RAW spooler passthrough (`WritePrinter`).
///  * `serial:<vid>:<pid>` (Android) — an FTDI/CH340/CP210x/CDC serial-bridge
///    chip, driven through the `usb_serial` plugin.
///
/// On platforms with no native handler (macOS/iOS) every call degrades to a
/// graceful "unsupported" result instead of throwing.
class UsbPrintTransport extends PrintTransport {
  UsbPrintTransport({
    EscPosReceiptEncoder encoder = const EscPosReceiptEncoder(),
    PrintWriteQueue? queue,
    MethodChannel channel = const MethodChannel('pointy/usb_print'),
  }) : _encoder = encoder,
       _queue = queue ?? PrintWriteQueue(),
       _channel = channel;

  final EscPosReceiptEncoder _encoder;
  final PrintWriteQueue _queue;
  final MethodChannel _channel;

  static const String _serialPrefix = 'serial:';
  static const String _printerPrefix = 'printer:';

  @override
  Future<List<PrinterEndpoint>> discover() async {
    try {
      final raw = await _channel.invokeListMethod<Map<Object?, Object?>>(
        'listDevices',
      );
      if (raw == null) {
        return const [];
      }
      final endpoints = <PrinterEndpoint>[];
      for (final entry in raw) {
        final address = entry['address']?.toString() ?? '';
        if (address.isEmpty) {
          continue;
        }
        final name = entry['name']?.toString();
        endpoints.add(
          PrinterEndpoint(
            kind: PrintTransportKind.usb,
            name: (name == null || name.isEmpty) ? address : name,
            address: address,
          ),
        );
      }
      return endpoints;
    } on MissingPluginException {
      return const [];
    } on Object {
      return const [];
    }
  }

  @override
  Future<PrintTransportStatus> status(PrinterEndpoint endpoint) async {
    final devices = await discover();
    final address = endpoint.address.trim();
    if (address.isEmpty) {
      return PrintTransportStatus(
        isAvailable: devices.isNotEmpty,
        message: devices.isEmpty
            ? 'no usb printers found'
            : devices.map((device) => device.name).join(', '),
      );
    }
    final isAvailable = devices.any((device) => device.address == address);
    return PrintTransportStatus(
      isAvailable: isAvailable,
      message: isAvailable ? 'usb device ready' : 'usb device not found',
    );
  }

  @override
  Future<PrintTransportResult> printJob({
    required PrintJob job,
    required PrinterEndpoint endpoint,
  }) async {
    final bytes = await _encoder.encodeJob(job: job, endpoint: endpoint);
    return printBytes(bytes: bytes, endpoint: endpoint);
  }

  @override
  Future<PrintTransportResult> printBytes({
    required List<int> bytes,
    required PrinterEndpoint endpoint,
  }) async {
    return _queue.run(() => _write(endpoint, Uint8List.fromList(bytes)));
  }

  @override
  Future<PrintTransportResponse> sendAndReceiveBytes({
    required List<int> bytes,
    required PrinterEndpoint endpoint,
    Duration? readTimeout,
  }) async {
    if (endpoint.address.trim().startsWith(_serialPrefix)) {
      // Serial-bridge probes aren't implemented; the label-language detector
      // falls back to name-based detection / the configured language.
      return const PrintTransportResponse.failure(
        'usb serial probes unsupported',
      );
    }
    return _queue.run(
      () => _transceiveNative(endpoint, Uint8List.fromList(bytes), readTimeout),
    );
  }

  @override
  Future<PrintTransportResult> printTest(PrinterEndpoint endpoint) async {
    final bytes = await _encoder.encodeTest(endpoint);
    return printBytes(bytes: bytes, endpoint: endpoint);
  }

  Future<PrintTransportResult> _write(
    PrinterEndpoint endpoint,
    Uint8List bytes,
  ) async {
    final address = endpoint.address.trim();
    if (address.isEmpty) {
      return const PrintTransportResult.failure('usb device is required');
    }
    if (address.startsWith(_serialPrefix)) {
      return _writeSerialBridge(
        address.substring(_serialPrefix.length),
        bytes,
        endpoint,
      );
    }
    return _writeNative(_nativeAddress(address), bytes, endpoint);
  }

  String _nativeAddress(String address) {
    return address.startsWith(_printerPrefix)
        ? address.substring(_printerPrefix.length)
        : address;
  }

  Future<PrintTransportResult> _writeNative(
    String address,
    Uint8List bytes,
    PrinterEndpoint endpoint,
  ) async {
    try {
      final result = await _channel.invokeMapMethod<String, Object?>('write', {
        'address': address,
        'bytes': bytes,
        'timeoutMs': endpoint.timeoutMs,
      });
      final success = result?['success'] == true;
      final message = result?['message']?.toString();
      return success
          ? PrintTransportResult.success(message ?? 'usb print sent')
          : PrintTransportResult.failure(message ?? 'usb print failed');
    } on MissingPluginException {
      return const PrintTransportResult.failure(
        'usb printing is not supported on this platform',
      );
    } on PlatformException catch (error) {
      return PrintTransportResult.failure(
        'usb print failed: ${error.message ?? error.code}',
      );
    } on Object catch (error) {
      return PrintTransportResult.failure('usb print failed: $error');
    }
  }

  Future<PrintTransportResult> _writeSerialBridge(
    String vidPid,
    Uint8List bytes,
    PrinterEndpoint endpoint,
  ) async {
    UsbPort? port;
    try {
      final device = await _findSerialDevice(vidPid);
      if (device == null) {
        return PrintTransportResult.failure(
          'usb serial device $vidPid not found',
        );
      }
      port = await device.create();
      if (port == null || !await port.open()) {
        return const PrintTransportResult.failure(
          'failed to open usb serial device',
        );
      }
      await port.setPortParameters(
        endpoint.baudRate,
        UsbPort.DATABITS_8,
        UsbPort.STOPBITS_1,
        UsbPort.PARITY_NONE,
      );
      await port.write(bytes);
      return PrintTransportResult.success(
        'usb serial print sent: ${bytes.length} bytes',
      );
    } on MissingPluginException {
      return const PrintTransportResult.failure(
        'usb printing is not supported on this platform',
      );
    } on Object catch (error) {
      return PrintTransportResult.failure('usb serial print failed: $error');
    } finally {
      await port?.close();
    }
  }

  Future<UsbDevice?> _findSerialDevice(String vidPid) async {
    final devices = await UsbSerial.listDevices();
    for (final device in devices) {
      if (_vidPid(device) == vidPid) {
        return device;
      }
    }
    return null;
  }

  String _vidPid(UsbDevice device) {
    final vid = (device.vid ?? 0).toRadixString(16).padLeft(4, '0');
    final pid = (device.pid ?? 0).toRadixString(16).padLeft(4, '0');
    return '$vid:$pid';
  }

  Future<PrintTransportResponse> _transceiveNative(
    PrinterEndpoint endpoint,
    Uint8List bytes,
    Duration? readTimeout,
  ) async {
    final address = endpoint.address.trim();
    if (address.isEmpty) {
      return const PrintTransportResponse.failure('usb device is required');
    }
    try {
      final result = await _channel.invokeMapMethod<String, Object?>(
        'transceive',
        {
          'address': _nativeAddress(address),
          'bytes': bytes,
          'timeoutMs':
              (readTimeout ?? Duration(milliseconds: endpoint.timeoutMs))
                  .inMilliseconds,
        },
      );
      final success = result?['success'] == true;
      if (!success) {
        return PrintTransportResponse.failure(
          result?['message']?.toString() ?? 'printer did not respond',
        );
      }
      final response = result?['bytes'];
      final responseBytes = response is List
          ? response.whereType<int>().toList(growable: false)
          : const <int>[];
      if (responseBytes.isEmpty) {
        return const PrintTransportResponse.failure('printer did not respond');
      }
      return PrintTransportResponse.success(
        responseBytes,
        'printer response received',
      );
    } on MissingPluginException {
      return const PrintTransportResponse.failure(
        'printer response probes unsupported',
      );
    } on PlatformException catch (error) {
      return PrintTransportResponse.failure(
        'usb probe failed: ${error.message ?? error.code}',
      );
    } on Object catch (error) {
      return PrintTransportResponse.failure('usb probe failed: $error');
    }
  }
}
