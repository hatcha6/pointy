import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/device_printers.dart';
import '../../../data/models/printer_config.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../view_models/printing_settings_view_model.dart';

/// How printers and their jobs are named and drawn, in one place, so the
/// settings list, the job menu and the editor never describe the same printer
/// two ways.

String printerRoleTitle(AppLocalizations l10n, PrinterRole role) {
  return switch (role) {
    PrinterRole.posReceipt => l10n.printerRoleReceipts,
    PrinterRole.barcodeLabels => l10n.printerRoleLabels,
    PrinterRole.documents => l10n.printerRoleDocuments,
  };
}

String printerRoleDescription(AppLocalizations l10n, PrinterRole role) {
  return switch (role) {
    PrinterRole.posReceipt => l10n.printerRoleReceiptsDescription,
    PrinterRole.barcodeLabels => l10n.printerRoleLabelsDescription,
    PrinterRole.documents => l10n.printerRoleDocumentsDescription,
  };
}

/// What happens to [role]'s work while no printer here does it.
String printerRoleUnassigned(AppLocalizations l10n, PrinterRole role) {
  return switch (role) {
    PrinterRole.posReceipt => l10n.printerRoleReceiptsUnassigned,
    PrinterRole.barcodeLabels => l10n.printerRoleLabelsUnassigned,
    PrinterRole.documents => l10n.printerRoleDocumentsUnassigned,
  };
}

/// Whether [role] going unprinted is a problem, rather than a fallback: with
/// no documents printer the dialog opens, which is how documents always
/// printed.
bool printerRoleUnassignedIsWarning(PrinterRole role) =>
    role != PrinterRole.documents;

IconData printerRoleIcon(PrinterRole role) {
  return switch (role) {
    PrinterRole.posReceipt => Icons.receipt_long_outlined,
    PrinterRole.barcodeLabels => Icons.qr_code_2_outlined,
    PrinterRole.documents => Icons.description_outlined,
  };
}

const IconData kitchenStationIcon = Icons.soup_kitchen_outlined;

String printerTransportLabel(AppLocalizations l10n, PrintTransportKind kind) {
  return switch (kind) {
    PrintTransportKind.serial => l10n.printerTransportSerial,
    PrintTransportKind.bluetooth => l10n.printerTransportBluetooth,
    PrintTransportKind.wifi => l10n.printerTransportWifi,
    PrintTransportKind.system => l10n.printerTransportSystem,
    PrintTransportKind.usb => l10n.printerTransportUsb,
    PrintTransportKind.fake => l10n.printerTransportFake,
  };
}

IconData printerTransportIcon(PrintTransportKind kind) {
  return switch (kind) {
    PrintTransportKind.serial => Icons.cable_outlined,
    PrintTransportKind.bluetooth => Icons.bluetooth_outlined,
    PrintTransportKind.wifi => Icons.wifi_outlined,
    PrintTransportKind.system => Icons.print_outlined,
    PrintTransportKind.usb => Icons.usb,
    PrintTransportKind.fake => Icons.science_outlined,
  };
}

/// The device's own name: what the OS or the printer calls itself, else its
/// address.
String printerDeviceName(AppLocalizations l10n, PrinterEndpoint endpoint) {
  final name = endpoint.name.trim();
  if (name.isNotEmpty) {
    return _isolatedUnlessArabic(name);
  }
  final address = endpoint.address.trim();
  if (address.isNotEmpty) {
    return ltrIsolated(_addressText(endpoint));
  }
  return endpoint.kind == PrintTransportKind.system
      ? l10n.systemDefaultPrinterLabel
      : printerTransportLabel(l10n, endpoint.kind);
}

/// What the shop calls the printer, falling back to the device's own name.
String printerDisplayName(AppLocalizations l10n, DevicePrinter printer) {
  final label = printer.label.trim();
  return label.isNotEmpty ? label : printerDeviceName(l10n, printer.endpoint);
}

/// "USB · XP-80C", "شبكة · 192.168.1.50:9100": how the device is reached.
/// Without [withName] when the device's name is already the line above.
String printerConnectionLine(
  AppLocalizations l10n,
  PrinterEndpoint endpoint, {
  bool withName = true,
}) {
  final transport = printerTransportLabel(l10n, endpoint.kind);
  final name = withName ? endpoint.name.trim() : '';
  final address = endpoint.address.trim();
  final detail = switch (endpoint.kind) {
    // An OS printer's address is a queue URL, and a USB one a vendor and
    // product id: nobody needs to read either.
    PrintTransportKind.system =>
      name.isNotEmpty || !withName ? name : l10n.systemDefaultPrinterLabel,
    PrintTransportKind.usb => name.isNotEmpty ? name : '',
    PrintTransportKind.wifi => address.isEmpty ? name : _addressText(endpoint),
    _ => name.isNotEmpty ? name : address,
  };
  return detail.isEmpty
      ? transport
      : '$transport · ${_isolatedUnlessArabic(detail)}';
}

final _arabicLetter = RegExp(r'[\u0600-\u06FF]');

/// Latin names and addresses are isolated left-to-right: in an Arabic line
/// the bidi algorithm would otherwise reorder "XP-80C" or an address's dots
/// and digits around the Arabic. A name someone wrote in Arabic reads right
/// as it is.
String _isolatedUnlessArabic(String value) =>
    _arabicLetter.hasMatch(value) ? value : ltrIsolated(value);

/// What comes out of the printer: a thermal roll, a PDF page or a PDF roll.
String printerOutputSummary(AppLocalizations l10n, PrinterEndpoint endpoint) {
  if (!endpoint.usesDocumentInvoice) {
    return l10n.printerOutputThermalReceipt;
  }
  final rollWidth = pdfPageSizeReceiptWidthMm(endpoint.pdfPageSize);
  return rollWidth == null
      ? l10n.printerOutputA4Pdf
      : l10n.printerOutputPdfReceipt(rollWidth);
}

String _addressText(PrinterEndpoint endpoint) {
  final address = endpoint.address.trim();
  return endpoint.kind == PrintTransportKind.wifi
      ? '$address:${endpoint.port}'
      : address;
}

/// The job chips a printer card shows, in order of importance.
List<({String label, IconData icon})> printerJobBadges(
  AppLocalizations l10n,
  DevicePrinter printer,
  Map<int, String> stationNames,
) {
  return [
    for (final role in PrinterRole.values)
      if (printer.holds(role))
        (label: printerRoleTitle(l10n, role), icon: printerRoleIcon(role)),
    for (final stationId in printer.kitchenStationIds.toList()..sort())
      // A station this user cannot see, or one since removed, keeps its
      // assignment but is not drawn: there is no name to draw it with.
      if (stationNames[stationId] case final String name)
        (label: l10n.printerRoleKitchen(name), icon: kitchenStationIcon),
  ];
}

String printerConnectionLabel(
  AppLocalizations l10n,
  PrinterConnectionState state,
) {
  return switch (state) {
    PrinterConnectionState.connected => l10n.printerStateConnected,
    PrinterConnectionState.disconnected => l10n.printerStateDisconnected,
    PrinterConnectionState.checking => l10n.printerStateChecking,
    PrinterConnectionState.unknown ||
    PrinterConnectionState.notConfigured => l10n.printerStateUnknown,
  };
}

Color printerConnectionColor(
  PointySemanticColors colors,
  PrinterConnectionState state,
) {
  return switch (state) {
    PrinterConnectionState.connected => colors.success,
    PrinterConnectionState.disconnected => colors.danger,
    PrinterConnectionState.checking ||
    PrinterConnectionState.unknown ||
    PrinterConnectionState.notConfigured => colors.mutedInk,
  };
}

String printerTestButtonLabel(AppLocalizations l10n, PrinterTestKind kind) {
  return switch (kind) {
    PrinterTestKind.receipt => l10n.printerTestReceiptButton,
    PrinterTestKind.barcodeLabel => l10n.printerTestLabelButton,
    PrinterTestKind.document => l10n.printerTestDocumentButton,
    PrinterTestKind.kitchen => l10n.printerTestKitchenButton,
  };
}

IconData printerTestIcon(PrinterTestKind kind) {
  return switch (kind) {
    PrinterTestKind.receipt => printerRoleIcon(PrinterRole.posReceipt),
    PrinterTestKind.barcodeLabel => printerRoleIcon(PrinterRole.barcodeLabels),
    PrinterTestKind.document => printerRoleIcon(PrinterRole.documents),
    PrinterTestKind.kitchen => kitchenStationIcon,
  };
}

String printerTestResultMessage(
  AppLocalizations l10n,
  PrinterTestResult result,
) {
  if (!result.isSuccess) {
    return result.kind == PrinterTestKind.barcodeLabel
        ? l10n.barcodeLabelTestFailure
        : l10n.printerTestFailure;
  }
  return switch (result.kind) {
    PrinterTestKind.receipt => l10n.printerTestSuccess,
    PrinterTestKind.barcodeLabel => l10n.barcodeLabelTestSuccess,
    PrinterTestKind.document => l10n.printerTestDocumentSent,
    PrinterTestKind.kitchen => l10n.printerTestKitchenSent,
  };
}

/// A printer's icon with a dot for whether it is answering.
class PrinterAvatar extends StatelessWidget {
  const PrinterAvatar({super.key, required this.endpoint, required this.state});

  final PrinterEndpoint endpoint;
  final PrinterConnectionState state;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    return SizedBox.square(
      dimension: 44,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: colors.primaryStrong.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(PointyRadii.button),
              ),
              child: Icon(
                printerTransportIcon(endpoint.kind),
                color: colors.primaryStrong,
              ),
            ),
          ),
          PositionedDirectional(
            end: -2,
            bottom: -2,
            child: Container(
              width: 14,
              height: 14,
              decoration: BoxDecoration(
                color: printerConnectionColor(colors, state),
                shape: BoxShape.circle,
                border: Border.all(color: colors.surface, width: 2),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
