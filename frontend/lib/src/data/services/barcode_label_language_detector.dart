import 'dart:convert';

import '../models/printer_config.dart';
import 'print_transport.dart';

class BarcodeLabelLanguageDetectionResult {
  const BarcodeLabelLanguageDetectionResult.detected({
    required this.language,
    required this.message,
    this.isInferred = false,
  }) : isSuccess = true;

  const BarcodeLabelLanguageDetectionResult.unavailable(this.message)
    : isSuccess = false,
      language = null,
      isInferred = false;

  final bool isSuccess;
  final BarcodeLabelPrinterLanguage? language;
  final String message;
  final bool isInferred;
}

class BarcodeLabelLanguageDetector {
  const BarcodeLabelLanguageDetector();

  static final _zebraLanguageProbe = utf8.encode(
    '! U1 getvar "device.languages"\r\n',
  );
  static final _zebraAppNameProbe = utf8.encode('! U1 getvar "appl.name"\r\n');
  static final _tsplStatusProbe = <int>[27, 33, 63];
  static final _eplStatusProbe = ascii.encode('UQ\r\n');

  Future<BarcodeLabelLanguageDetectionResult> detect({
    required PrinterEndpoint endpoint,
    required PrintTransport transport,
  }) async {
    final zebraLanguage = await _probe(
      transport: transport,
      endpoint: endpoint,
      bytes: _zebraLanguageProbe,
    );
    final zebraLanguageResult = _languageFromZebraResponse(zebraLanguage.text);
    if (zebraLanguageResult != null) {
      return BarcodeLabelLanguageDetectionResult.detected(
        language: zebraLanguageResult,
        message: 'detected from Zebra device.languages',
      );
    }

    final zebraAppName = await _probe(
      transport: transport,
      endpoint: endpoint,
      bytes: _zebraAppNameProbe,
    );
    final appNameResult = _languageFromZebraResponse(zebraAppName.text);
    if (appNameResult != null) {
      return BarcodeLabelLanguageDetectionResult.detected(
        language: appNameResult,
        message: 'detected from Zebra appl.name',
      );
    }

    final tsplStatus = await _probe(
      transport: transport,
      endpoint: endpoint,
      bytes: _tsplStatusProbe,
    );
    if (_looksLikeTsplStatus(tsplStatus.bytes)) {
      return const BarcodeLabelLanguageDetectionResult.detected(
        language: BarcodeLabelPrinterLanguage.tspl,
        message: 'detected from TSPL status response',
      );
    }

    final eplStatus = await _probe(
      transport: transport,
      endpoint: endpoint,
      bytes: _eplStatusProbe,
    );
    if (eplStatus.bytes.isNotEmpty) {
      return const BarcodeLabelLanguageDetectionResult.detected(
        language: BarcodeLabelPrinterLanguage.epl,
        message: 'detected from EPL status response',
      );
    }

    final inferred = inferFromEndpoint(endpoint);
    if (inferred != null) {
      return BarcodeLabelLanguageDetectionResult.detected(
        language: inferred,
        message: 'inferred from printer name',
        isInferred: true,
      );
    }

    return const BarcodeLabelLanguageDetectionResult.unavailable(
      'barcode label language detection unavailable',
    );
  }

  BarcodeLabelPrinterLanguage? inferFromEndpoint(PrinterEndpoint endpoint) {
    final value = [endpoint.name, endpoint.address].join(' ').toLowerCase();
    if (value.contains('tspl') ||
        value.contains('tspl2') ||
        value.contains('tsc') ||
        value.contains('ttp-') ||
        value.contains('tdp-') ||
        value.contains('da210') ||
        value.contains('da220')) {
      return BarcodeLabelPrinterLanguage.tspl;
    }
    if (value.contains('cpcl') ||
        value.contains('qln') ||
        value.contains('rw ') ||
        value.contains('rw-') ||
        value.contains('mz ') ||
        value.contains('mz-')) {
      return BarcodeLabelPrinterLanguage.cpcl;
    }
    if (value.contains('epl') ||
        value.contains('eltron') ||
        value.contains('lp 28') ||
        value.contains('lp-28') ||
        value.contains('tlp 28') ||
        value.contains('tlp-28')) {
      return BarcodeLabelPrinterLanguage.epl;
    }
    if (value.contains('zpl') ||
        value.contains('zebra') ||
        value.contains('zdesigner') ||
        value.contains('zd4') ||
        value.contains('zd6') ||
        value.contains('zt2') ||
        value.contains('zt4') ||
        value.contains('gk4') ||
        value.contains('gx4')) {
      return BarcodeLabelPrinterLanguage.zpl;
    }
    return null;
  }

  Future<PrintTransportResponse> _probe({
    required PrintTransport transport,
    required PrinterEndpoint endpoint,
    required List<int> bytes,
  }) {
    return transport.sendAndReceiveBytes(
      bytes: bytes,
      endpoint: endpoint,
      readTimeout: const Duration(milliseconds: 900),
    );
  }

  BarcodeLabelPrinterLanguage? _languageFromZebraResponse(String value) {
    final normalized = value.toLowerCase();
    if (normalized.contains('zpl')) {
      return BarcodeLabelPrinterLanguage.zpl;
    }
    if (normalized.contains('tspl')) {
      return BarcodeLabelPrinterLanguage.tspl;
    }
    if (normalized.contains('epl')) {
      return BarcodeLabelPrinterLanguage.epl;
    }
    if (normalized.contains('cpcl')) {
      return BarcodeLabelPrinterLanguage.cpcl;
    }
    return null;
  }

  bool _looksLikeTsplStatus(List<int> bytes) {
    if (bytes.length != 1) {
      return false;
    }
    return const {
      0x00,
      0x01,
      0x02,
      0x03,
      0x04,
      0x05,
      0x08,
      0x09,
      0x0A,
      0x0B,
      0x0C,
      0x0D,
      0x10,
      0x20,
      0x80,
    }.contains(bytes.single);
  }
}
