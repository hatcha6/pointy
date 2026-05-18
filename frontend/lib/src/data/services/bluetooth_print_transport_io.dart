import 'dart:async';

import 'package:flutter_bluetooth_classic_serial/flutter_bluetooth_classic.dart';

import '../models/print_job.dart';
import '../models/printer_config.dart';
import 'esc_pos_receipt_encoder.dart';
import 'print_transport.dart';
import 'print_write_queue.dart';

class BluetoothPrintTransport extends PrintTransport {
  BluetoothPrintTransport({
    EscPosReceiptEncoder encoder = const EscPosReceiptEncoder(),
    FlutterBluetoothClassic? bluetooth,
    PrintWriteQueue? queue,
  }) : _encoder = encoder,
       _bluetooth = bluetooth ?? FlutterBluetoothClassic(),
       _queue = queue ?? PrintWriteQueue();

  final EscPosReceiptEncoder _encoder;
  final FlutterBluetoothClassic _bluetooth;
  final PrintWriteQueue _queue;

  @override
  Future<List<PrinterEndpoint>> discover() async {
    try {
      final supported = await _bluetooth.isBluetoothSupported();
      if (!supported) {
        return const [];
      }
      final enabled = await _bluetooth.isBluetoothEnabled();
      if (!enabled) {
        return const [];
      }

      final endpoints = <String, PrinterEndpoint>{};
      final pairedDevices = await _bluetooth.getPairedDevices();
      for (final device in pairedDevices) {
        endpoints[device.address] = PrinterEndpoint(
          kind: PrintTransportKind.bluetooth,
          name: device.name,
          address: device.address,
        );
      }

      await _discoverNearbyDevices(endpoints);
      return endpoints.values.toList(growable: false);
    } on Object {
      return const [];
    }
  }

  @override
  Future<PrintTransportStatus> status(PrinterEndpoint endpoint) async {
    try {
      final supported = await _bluetooth.isBluetoothSupported();
      if (!supported) {
        return const PrintTransportStatus(
          isAvailable: false,
          message: 'bluetooth not supported',
        );
      }
      final enabled = await _bluetooth.isBluetoothEnabled();
      if (!enabled) {
        return const PrintTransportStatus(
          isAvailable: false,
          message: 'bluetooth disabled',
        );
      }
      if (endpoint.address.trim().isEmpty) {
        return const PrintTransportStatus(
          isAvailable: true,
          message: 'bluetooth ready',
        );
      }
      final devices = await _bluetooth.getPairedDevices();
      final paired = devices.any(
        (device) => device.address == endpoint.address,
      );
      return PrintTransportStatus(
        isAvailable: paired,
        message: paired
            ? 'paired bluetooth printer ready'
            : 'printer not paired',
      );
    } on Object catch (error) {
      return PrintTransportStatus(
        isAvailable: false,
        message: 'bluetooth status failed: $error',
      );
    }
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
    return _queue.run(() => _write(endpoint, bytes));
  }

  @override
  Future<PrintTransportResult> printTest(PrinterEndpoint endpoint) async {
    final bytes = await _encoder.encodeTest(endpoint);
    return printBytes(bytes: bytes, endpoint: endpoint);
  }

  Future<PrintTransportResult> _write(
    PrinterEndpoint endpoint,
    List<int> bytes,
  ) async {
    final address = endpoint.address.trim();
    if (address.isEmpty) {
      return const PrintTransportResult.failure(
        'bluetooth device address is required',
      );
    }

    try {
      final connected = await _bluetooth
          .connect(address)
          .timeout(Duration(milliseconds: endpoint.timeoutMs));
      if (!connected) {
        return const PrintTransportResult.failure(
          'bluetooth connection failed',
        );
      }

      for (final chunk in byteChunks(bytes, 512)) {
        final sent = await _bluetooth
            .sendData(chunk)
            .timeout(Duration(milliseconds: endpoint.timeoutMs));
        if (!sent) {
          return const PrintTransportResult.failure('bluetooth write failed');
        }
      }
      return PrintTransportResult.success(
        'bluetooth print sent: ${bytes.length} bytes',
      );
    } on Object catch (error) {
      return PrintTransportResult.failure('bluetooth print failed: $error');
    } finally {
      unawaited(_bluetooth.disconnect());
    }
  }

  Future<void> _discoverNearbyDevices(
    Map<String, PrinterEndpoint> endpoints,
  ) async {
    StreamSubscription<BluetoothDevice>? subscription;
    try {
      subscription = _bluetooth.onDeviceDiscovered.listen((device) {
        endpoints[device.address] = PrinterEndpoint(
          kind: PrintTransportKind.bluetooth,
          name: device.name,
          address: device.address,
        );
      });
      final started = await _bluetooth.startDiscovery();
      if (started) {
        await Future<void>.delayed(const Duration(seconds: 4));
        await _bluetooth.stopDiscovery();
      }
    } on Object {
      // Paired devices are still useful when active discovery is unavailable.
    } finally {
      await subscription?.cancel();
    }
  }
}
