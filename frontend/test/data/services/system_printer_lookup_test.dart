import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/models/printer_config.dart';
import 'package:pointy_frontend/src/data/services/system_printer_lookup.dart';
import 'package:printing/printing.dart';

PrinterEndpoint _driverPrinter(String address) {
  return PrinterEndpoint(
    kind: PrintTransportKind.system,
    name: address,
    address: address,
    outputMode: PrinterOutputMode.pdfA4,
  );
}

void main() {
  // What Windows reports on a till whose label printer has an error on it:
  // it is still there, and the spooler still takes jobs for it.
  const printers = [
    Printer(url: 'Microsoft Print to PDF', isDefault: true),
    Printer(url: 'HPRT LPQ80', isAvailable: false),
  ];

  test('a named printer is printed to even when Windows calls it '
      'unavailable, rather than behind a print dialog', () {
    expect(
      pickSystemPrinter(printers, _driverPrinter('HPRT LPQ80'))?.url,
      'HPRT LPQ80',
    );
  });

  test('a printer this machine does not have is not stood in for', () {
    expect(pickSystemPrinter(printers, _driverPrinter('XP-80C')), isNull);
  });

  test('an endpoint that names no printer means the default printer', () {
    expect(
      pickSystemPrinter(printers, _driverPrinter(''))?.url,
      'Microsoft Print to PDF',
    );
  });
}
