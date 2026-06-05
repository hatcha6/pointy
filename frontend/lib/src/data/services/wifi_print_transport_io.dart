import 'dart:io';

import 'package:multicast_dns/multicast_dns.dart';

import '../models/print_job.dart';
import '../models/printer_config.dart';
import 'esc_pos_receipt_encoder.dart';
import 'print_transport.dart';
import 'print_write_queue.dart';

class WifiPrintTransport extends PrintTransport {
  WifiPrintTransport({
    EscPosReceiptEncoder encoder = const EscPosReceiptEncoder(),
    PrintWriteQueue? queue,
  }) : _encoder = encoder,
       _queue = queue ?? PrintWriteQueue();

  final EscPosReceiptEncoder _encoder;
  final PrintWriteQueue _queue;
  static const _serviceTypes = [
    '_pdl-datastream._tcp.local',
    '_printer._tcp.local',
    '_ipp._tcp.local',
    '_ipps._tcp.local',
  ];

  @override
  Future<List<PrinterEndpoint>> discover() async {
    final endpoints = <String, PrinterEndpoint>{};
    final client = MDnsClient();
    try {
      await client.start();
      for (final serviceType in _serviceTypes) {
        await _discoverServiceType(client, serviceType, endpoints);
      }
    } on Object {
      return endpoints.values.toList(growable: false);
    } finally {
      client.stop();
    }
    return endpoints.values.toList(growable: false);
  }

  @override
  Future<PrintTransportStatus> status(PrinterEndpoint endpoint) async {
    final host = endpoint.address.trim();
    if (host.isEmpty) {
      return const PrintTransportStatus(
        isAvailable: false,
        message: 'printer host is required',
      );
    }
    Socket? socket;
    try {
      socket = await Socket.connect(
        host,
        endpoint.port,
        timeout: Duration(milliseconds: endpoint.timeoutMs),
      );
      return const PrintTransportStatus(
        isAvailable: true,
        message: 'network printer ready',
      );
    } on Object catch (error) {
      return PrintTransportStatus(
        isAvailable: false,
        message: 'network printer unavailable: $error',
      );
    } finally {
      socket?.destroy();
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
    final host = endpoint.address.trim();
    if (host.isEmpty) {
      return const PrintTransportResult.failure('printer host is required');
    }

    Socket? socket;
    try {
      socket = await Socket.connect(
        host,
        endpoint.port,
        timeout: Duration(milliseconds: endpoint.timeoutMs),
      );
      for (final chunk in byteChunks(bytes, 1024)) {
        socket.add(chunk);
        await socket.flush();
      }
      await socket.close();
      return PrintTransportResult.success(
        'network print sent: ${bytes.length} bytes',
      );
    } on Object catch (error) {
      return PrintTransportResult.failure('network print failed: $error');
    } finally {
      socket?.destroy();
    }
  }

  Future<void> _discoverServiceType(
    MDnsClient client,
    String serviceType,
    Map<String, PrinterEndpoint> endpoints,
  ) async {
    await for (final ptr in client.lookup<PtrResourceRecord>(
      ResourceRecordQuery.serverPointer(serviceType),
      timeout: const Duration(seconds: 2),
    )) {
      await for (final srv in client.lookup<SrvResourceRecord>(
        ResourceRecordQuery.service(ptr.domainName),
        timeout: const Duration(seconds: 2),
      )) {
        final addresses = await _resolveHost(client, srv.target);
        if (addresses.isEmpty) {
          endpoints['${srv.target}:${srv.port}'] = _endpointFromService(
            serviceType: serviceType,
            name: ptr.domainName,
            host: srv.target,
            port: _printerPort(srv.port),
          );
        } else {
          for (final address in addresses) {
            endpoints['${address.address}:${srv.port}'] = _endpointFromService(
              serviceType: serviceType,
              name: ptr.domainName,
              host: address.address,
              port: _printerPort(srv.port),
            );
          }
        }
      }
    }
  }

  Future<List<InternetAddress>> _resolveHost(
    MDnsClient client,
    String target,
  ) async {
    final addresses = <InternetAddress>[];
    await for (final record in client.lookup<IPAddressResourceRecord>(
      ResourceRecordQuery.addressIPv4(target),
      timeout: const Duration(seconds: 2),
    )) {
      addresses.add(record.address);
    }
    return addresses;
  }

  PrinterEndpoint _endpointFromService({
    required String serviceType,
    required String name,
    required String host,
    required int port,
  }) {
    final isDocumentPrinter =
        serviceType.contains('_ipp') || serviceType.contains('_printer');
    return PrinterEndpoint(
      kind: PrintTransportKind.wifi,
      name: _cleanServiceName(name),
      address: host,
      port: port,
      outputMode: isDocumentPrinter
          ? PrinterOutputMode.pdfA4
          : PrinterOutputMode.escPos,
    );
  }

  int _printerPort(int advertisedPort) {
    return advertisedPort == 0 ? 9100 : advertisedPort;
  }

  String _cleanServiceName(String name) {
    return name
        .replaceAll(RegExp(r'\._pdl-datastream\._tcp\.local\.?$'), '')
        .replaceAll(RegExp(r'\._printer\._tcp\.local\.?$'), '')
        .replaceAll(RegExp(r'\._ipps?\._tcp\.local\.?$'), '')
        .replaceAll(r'\032', ' ')
        .trim();
  }
}
