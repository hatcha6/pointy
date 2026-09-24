import 'package:printing/printing.dart';

import '../models/printer_config.dart';

/// The operating-system printer [endpoint] names, to print straight to; null
/// when this machine has no such printer, and the caller falls back to the
/// print dialog.
Future<Printer?> findSystemPrinter(PrinterEndpoint endpoint) async {
  final info = await Printing.info();
  if (!info.canListPrinters) {
    return null;
  }
  return pickSystemPrinter(await Printing.listPrinters(), endpoint);
}

/// The printer in [printers] that [endpoint] names, or the default printer
/// when it names none.
///
/// A named printer is taken whatever state the system reports it in. Windows
/// calls a queue that is offline, paused or in error "not available", and a
/// USB receipt printer reads "offline" routinely while it prints perfectly
/// well; the spooler still takes the job and prints it once the printer
/// answers. Skipping such a printer used to send the print to the print
/// dialog instead — which on a full-screen till opens out of sight, showing
/// only in the taskbar, and holds the print until someone finds it. Whether
/// the printer is healthy is for the status check to say, not for this.
Printer? pickSystemPrinter(List<Printer> printers, PrinterEndpoint endpoint) {
  final address = endpoint.address.trim();
  if (address.isEmpty) {
    return printers.where((printer) => printer.isDefault).firstOrNull;
  }
  return printers.where((printer) => printer.url == address).firstOrNull;
}
