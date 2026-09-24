// Dev-only preview harness for the device printers settings.
//
// Renders the printers section and its editor with fake repositories and no
// backend/auth. Pick the surface with a `?screen=` query param and resize the
// browser to test responsiveness. Run with:
//
//   flutter run -d web-server --web-port 8080 -t lib/dev/printers_preview.dart
//
// Screens: board | settings | migrated | empty | add | edit-receipt
//          | edit-labels
//
// `?screen=board` lays the settings out at phone and wide widths at once, for
// a single overview screenshot (size the viewport large so Flutter paints it
// all). See AGENTS.md ("UI preview harness"). Not part of the shipping app.
// Safe to delete.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/device_printers.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/models/prep_station.dart';
import 'package:pointy_frontend/src/data/models/printer_config.dart';
import 'package:pointy_frontend/src/data/repositories/prep_station_repository.dart';
import 'package:pointy_frontend/src/data/repositories/printing_repository.dart';
import 'package:pointy_frontend/src/data/services/fake_print_transport.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/data/services/print_transport.dart';
import 'package:pointy_frontend/src/features/printing/view_models/printing_settings_view_model.dart';
import 'package:pointy_frontend/src/features/printing/views/printer_editor_sheet.dart';
import 'package:pointy_frontend/src/features/printing/views/printers_panel.dart';
import 'package:pointy_frontend/src/shared/components/components.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/responsive/responsive.dart';
import 'package:pointy_frontend/src/shared/shell/shell.dart';

void main() => runApp(const _PreviewApp());

class _PreviewApp extends StatelessWidget {
  const _PreviewApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      locale: const Locale('ar'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: PointyTheme.light(),
      builder: (context, child) => PointyNavigationRailScope(
        isActive: false,
        controller: PointyNavigationRailController(),
        child: child ?? const SizedBox.shrink(),
      ),
      home: printersPreviewSurface(_selectedScreen()),
    );
  }
}

String _selectedScreen() {
  final uri = Uri.base;
  final direct = uri.queryParameters['screen'];
  if (direct != null) {
    return direct;
  }
  final fragment = uri.fragment;
  final parsed = Uri.tryParse(
    fragment.startsWith('/') ? fragment.substring(1) : fragment,
  );
  return parsed?.queryParameters['screen'] ?? 'settings';
}

/// One preview surface by name. Public so a headless capture test can render
/// the same states the browser shows.
Widget printersPreviewSurface(String screen) {
  return switch (screen) {
    'board' => const _DesignBoard(),
    'empty' => const _SettingsPage(printers: []),
    'migrated' => const _SettingsPage(printers: [_migrated]),
    'add' => const _SettingsPage(printers: _shopPrinters, openEditor: true),
    'edit-receipt' => const _SettingsPage(
      printers: _shopPrinters,
      openEditor: true,
      editPrinterId: 'counter',
    ),
    'edit-labels' => const _SettingsPage(
      printers: _shopPrinters,
      openEditor: true,
      editPrinterId: 'labels',
    ),
    _ => const _SettingsPage(printers: _shopPrinters),
  };
}

/// The printers section as it sits on the device settings screen, optionally
/// with the editor opened over it — for a new printer, or for
/// [editPrinterId].
class _SettingsPage extends StatefulWidget {
  const _SettingsPage({
    required this.printers,
    this.openEditor = false,
    this.editPrinterId,
  });

  final List<DevicePrinter> printers;
  final bool openEditor;
  final String? editPrinterId;

  @override
  State<_SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<_SettingsPage> {
  late final PrintingSettingsViewModel _viewModel;

  @override
  void initState() {
    super.initState();
    _viewModel = PrintingSettingsViewModel(
      _FakePrintingRepository(DevicePrinters(widget.printers)),
      prepStationRepository: _FakePrepStations(),
      statusCheckInterval: const Duration(hours: 1),
    );
    if (!widget.openEditor) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _viewModel.load();
      await _viewModel.discoverPrinters();
      if (!mounted) {
        return;
      }
      final printerId = widget.editPrinterId;
      showPrinterEditor(
        context,
        settings: _viewModel,
        printer: printerId == null ? null : _viewModel.printers.byId(printerId),
      );
    });
  }

  @override
  void dispose() {
    _viewModel.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    return Scaffold(
      backgroundColor: context.pointyColors.page,
      appBar: PointyAppBar(title: Text(l10n.deviceSettingsTitle)),
      body: ListView(
        padding: spacing.pagePadding,
        children: [
          AdaptiveMaxWidth(
            width: AppContentWidth.form,
            child: PointyDetailSection(
              icon: Icons.print_outlined,
              title: l10n.devicePrinterSectionTitle,
              child: PrintersPanel(
                viewModel: _viewModel,
                capabilities: _managerCaps,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DesignBoard extends StatelessWidget {
  const _DesignBoard();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFE9E7E1),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Wrap(
          spacing: 28,
          runSpacing: 28,
          children: [
            _Frame(
              label: 'Printers',
              width: 390,
              child: _SettingsPage(printers: _shopPrinters),
            ),
            _Frame(
              label: 'Printers',
              width: 900,
              child: _SettingsPage(printers: _shopPrinters),
            ),
            _Frame(
              label: 'Right after the update',
              width: 390,
              child: _SettingsPage(printers: [_migrated]),
            ),
            _Frame(
              label: 'No printers',
              width: 390,
              child: _SettingsPage(printers: []),
            ),
          ],
        ),
      ),
    );
  }
}

class _Frame extends StatelessWidget {
  const _Frame({required this.label, required this.width, required this.child});

  static const _height = 1500.0;

  final String label;
  final double width;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('$label · ${width.toInt()}'),
        const SizedBox(height: 8),
        SizedBox(
          width: width,
          height: _height,
          child: MediaQuery(
            data: MediaQuery.of(context).copyWith(
              size: Size(width, _height),
              padding: EdgeInsets.zero,
              viewInsets: EdgeInsets.zero,
            ),
            child: ClipRect(child: child),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

final PosUser _managerUser = PosUser.fromJson(const {
  'id': 1,
  'username': 'manager',
  'role': 'manager',
  'permissions': <String>[],
});

final AuthorizationCapabilities _managerCaps =
    AuthorizationCapabilities.forUser(_managerUser);

const _counter = DevicePrinter(
  id: 'counter',
  label: 'الكاشير',
  config: PrinterConfig(
    endpoint: PrinterEndpoint(
      kind: PrintTransportKind.usb,
      name: 'XP-80C',
      address: 'printer:1155:22339',
    ),
  ),
  roles: {PrinterRole.posReceipt},
  kitchenStationIds: {1},
);

const _labels = DevicePrinter(
  id: 'labels',
  label: 'الملصقات',
  config: PrinterConfig(
    endpoint: PrinterEndpoint(
      kind: PrintTransportKind.system,
      name: 'HPRT LPQ80',
      address: 'ipp://localhost/printers/HPRT_LPQ80',
      outputMode: PrinterOutputMode.pdfA4,
      labelWidthMm: 38,
      labelHeightMm: 26,
      labelPdfOffsetXMm: 20,
      labelPdfPitchMm: 27.28,
    ),
  ),
  roles: {PrinterRole.barcodeLabels},
);

const _office = DevicePrinter(
  id: 'office',
  config: PrinterConfig(
    endpoint: PrinterEndpoint(
      kind: PrintTransportKind.system,
      name: 'HP LaserJet M111w',
      address: 'ipp://localhost/printers/HP_LaserJet',
      outputMode: PrinterOutputMode.pdfA4,
    ),
  ),
  roles: {PrinterRole.documents},
);

const _migrated = DevicePrinter(
  id: 'legacy-receipt',
  config: PrinterConfig(
    endpoint: PrinterEndpoint(
      kind: PrintTransportKind.wifi,
      name: 'Xprinter XP-N160II',
      address: '192.168.1.50',
    ),
  ),
  roles: {PrinterRole.posReceipt, PrinterRole.barcodeLabels},
);

const _shopPrinters = [_counter, _labels, _office];

/// Printing without printers: every device answers except the office laser,
/// so the preview shows both states.
class _FakePrintingRepository extends PrintingRepository {
  _FakePrintingRepository(this._printers)
    : super(
        PosApiService(),
        serialTransport: const FakePrintTransport(),
        bluetoothTransport: const FakePrintTransport(),
        wifiTransport: const FakePrintTransport(),
        usbTransport: const FakePrintTransport(),
      );

  DevicePrinters _printers;

  @override
  Future<Result<DevicePrinters>> loadDevicePrinters() async => Ok(_printers);

  @override
  Future<Result<void>> saveDevicePrinters(DevicePrinters printers) async {
    _printers = printers;
    return const Ok(null);
  }

  @override
  Future<Result<List<PrinterEndpoint>>> discoverPrinters() async {
    return const Ok([
      PrinterEndpoint(
        kind: PrintTransportKind.system,
        name: '',
        outputMode: PrinterOutputMode.pdfA4,
      ),
      PrinterEndpoint(
        kind: PrintTransportKind.usb,
        name: 'XP-80C',
        address: 'printer:1155:22339',
      ),
      PrinterEndpoint(
        kind: PrintTransportKind.system,
        name: 'HPRT LPQ80',
        address: 'ipp://localhost/printers/HPRT_LPQ80',
        outputMode: PrinterOutputMode.pdfA4,
      ),
      PrinterEndpoint(
        kind: PrintTransportKind.wifi,
        name: 'Kitchen XP-58',
        address: '192.168.1.61',
      ),
    ]);
  }

  @override
  Future<PrintTransportStatus> printerStatus(PrinterConfig config) async {
    final available = !config.endpoint.address.contains('LaserJet');
    return PrintTransportStatus(isAvailable: available, message: 'preview');
  }

  @override
  Future<PrintTransportResult> testPrinter(PrinterConfig config) async =>
      const PrintTransportResult.success('preview');

  @override
  Future<PrintTransportResult> printBarcodeLabelTest(
    PrinterConfig config,
  ) async => const PrintTransportResult.success('preview');

  @override
  Future<PrintTransportResult> printDocumentTest(PrinterConfig config) async =>
      const PrintTransportResult.success('preview');

  @override
  Future<PrintTransportResult> printKitchenTest(PrinterConfig config) async =>
      const PrintTransportResult.success('preview');
}

class _FakePrepStations extends PrepStationRepository {
  _FakePrepStations() : super(PosApiService());

  @override
  Future<Result<List<PrepStation>>> loadStations() async {
    return const Ok([
      PrepStation(
        id: 1,
        name: 'الشواية',
        printerProfileId: null,
        printerProfileName: '',
        categoryIds: [],
        categoryNames: [],
        isDefault: true,
        isActive: true,
        priority: 0,
      ),
      PrepStation(
        id: 2,
        name: 'المشروبات',
        printerProfileId: null,
        printerProfileName: '',
        categoryIds: [],
        categoryNames: [],
        isDefault: false,
        isActive: true,
        priority: 1,
      ),
    ]);
  }
}
