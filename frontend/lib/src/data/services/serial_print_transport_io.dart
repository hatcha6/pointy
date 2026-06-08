import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_libserialport/flutter_libserialport.dart';

import '../models/print_job.dart';
import '../models/printer_config.dart';
import 'esc_pos_receipt_encoder.dart';
import 'print_transport.dart';
import 'print_write_queue.dart';

class SerialPrintTransport extends PrintTransport {
  SerialPrintTransport({
    EscPosReceiptEncoder encoder = const EscPosReceiptEncoder(),
    PrintWriteQueue? queue,
  }) : _encoder = encoder,
       _queue = queue ?? PrintWriteQueue();

  final EscPosReceiptEncoder _encoder;
  final PrintWriteQueue _queue;

  @override
  Future<List<PrinterEndpoint>> discover() async {
    try {
      return SerialPort.availablePorts
          .map(
            (port) => PrinterEndpoint(
              kind: PrintTransportKind.serial,
              name: port.split('/').last,
              address: port,
            ),
          )
          .toList(growable: false);
    } on Object {
      return const [];
    }
  }

  @override
  Future<PrintTransportStatus> status(PrinterEndpoint endpoint) async {
    try {
      final ports = SerialPort.availablePorts;
      if (endpoint.address.trim().isEmpty) {
        return PrintTransportStatus(
          isAvailable: ports.isNotEmpty,
          message: ports.isEmpty ? 'no serial ports found' : ports.join(', '),
        );
      }
      final isAvailable = ports.contains(endpoint.address);
      return PrintTransportStatus(
        isAvailable: isAvailable,
        message: isAvailable ? 'serial port ready' : 'serial port not found',
      );
    } on Object catch (error) {
      return PrintTransportStatus(
        isAvailable: false,
        message: 'serial status failed: $error',
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
    return _queue.run(() => _write(endpoint, Uint8List.fromList(bytes)));
  }

  @override
  Future<PrintTransportResponse> sendAndReceiveBytes({
    required List<int> bytes,
    required PrinterEndpoint endpoint,
    Duration? readTimeout,
  }) async {
    return _queue.run(
      () => _sendAndReceive(
        endpoint,
        Uint8List.fromList(bytes),
        readTimeout: readTimeout,
      ),
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
      return const PrintTransportResult.failure('serial port is required');
    }

    final port = SerialPort(address);
    SerialPortConfig? config;
    try {
      if (!port.openWrite()) {
        return PrintTransportResult.failure(
          'failed to open serial port ${port.name ?? address}',
        );
      }
      config = SerialPortConfig()
        ..baudRate = endpoint.baudRate
        ..bits = 8
        ..stopBits = 1
        ..parity = SerialPortParity.none
        ..setFlowControl(SerialPortFlowControl.none);
      port.config = config;

      var written = 0;
      while (written < bytes.length) {
        final next = bytes.sublist(written);
        final count = port.write(next, timeout: endpoint.timeoutMs);
        if (count <= 0) {
          return PrintTransportResult.failure(
            'serial write stopped after $written of ${bytes.length} bytes',
          );
        }
        written += count;
      }
      port.drain();
      return PrintTransportResult.success('serial print sent: $written bytes');
    } on Object catch (error) {
      return PrintTransportResult.failure('serial print failed: $error');
    } finally {
      config?.dispose();
      if (port.isOpen) {
        port.close();
      }
      port.dispose();
    }
  }

  Future<PrintTransportResponse> _sendAndReceive(
    PrinterEndpoint endpoint,
    Uint8List bytes, {
    Duration? readTimeout,
  }) async {
    final address = endpoint.address.trim();
    if (address.isEmpty) {
      return const PrintTransportResponse.failure('serial port is required');
    }

    final port = SerialPort(address);
    SerialPortConfig? config;
    SerialPortReader? reader;
    StreamSubscription<Uint8List>? subscription;
    try {
      if (!port.openReadWrite()) {
        return PrintTransportResponse.failure(
          'failed to open serial port ${port.name ?? address}',
        );
      }
      config = SerialPortConfig()
        ..baudRate = endpoint.baudRate
        ..bits = 8
        ..stopBits = 1
        ..parity = SerialPortParity.none
        ..setFlowControl(SerialPortFlowControl.none);
      port.config = config;

      final response = <int>[];
      final firstData = Completer<void>();
      reader = SerialPortReader(port, timeout: endpoint.timeoutMs);
      subscription = reader.stream.listen(
        (data) {
          response.addAll(data);
          if (!firstData.isCompleted) {
            firstData.complete();
          }
        },
        onError: (Object error) {
          if (!firstData.isCompleted) {
            firstData.completeError(error);
          }
        },
        onDone: () {
          if (!firstData.isCompleted) {
            firstData.complete();
          }
        },
      );

      var written = 0;
      while (written < bytes.length) {
        final next = bytes.sublist(written);
        final count = port.write(next, timeout: endpoint.timeoutMs);
        if (count <= 0) {
          return PrintTransportResponse.failure(
            'serial probe stopped after $written of ${bytes.length} bytes',
          );
        }
        written += count;
      }
      port.drain();
      await firstData.future.timeout(
        readTimeout ?? Duration(milliseconds: endpoint.timeoutMs),
        onTimeout: () {},
      );

      if (response.isEmpty) {
        return const PrintTransportResponse.failure('printer did not respond');
      }
      return PrintTransportResponse.success(
        List<int>.unmodifiable(response),
        'printer response received',
      );
    } on Object catch (error) {
      return PrintTransportResponse.failure('serial probe failed: $error');
    } finally {
      await subscription?.cancel();
      reader?.close();
      config?.dispose();
      if (port.isOpen) {
        port.close();
      }
      port.dispose();
    }
  }
}
