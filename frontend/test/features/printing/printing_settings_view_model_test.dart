import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/device_printers.dart';
import 'package:pointy_frontend/src/data/models/prep_station.dart';
import 'package:pointy_frontend/src/data/models/print_job.dart';
import 'package:pointy_frontend/src/data/models/printer_config.dart';
import 'package:pointy_frontend/src/data/repositories/prep_station_repository.dart';
import 'package:pointy_frontend/src/data/repositories/printing_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/data/services/print_transport.dart';
import 'package:pointy_frontend/src/features/printing/view_models/printer_editor_view_model.dart';
import 'package:pointy_frontend/src/features/printing/view_models/printing_settings_view_model.dart';

import '../../support/key_value_store_testing.dart';

class _StatusTransport extends PrintTransport {
  bool isAvailable = true;
  int printed = 0;

  /// When set, the next status question waits for this answer.
  Completer<PrintTransportStatus>? gate;

  @override
  Future<List<PrinterEndpoint>> discover() async => const [
    PrinterEndpoint(
      kind: PrintTransportKind.wifi,
      name: 'Kitchen XP',
      address: '10.0.0.9',
    ),
  ];

  @override
  Future<PrintTransportStatus> status(PrinterEndpoint endpoint) {
    final pending = gate;
    if (pending != null) {
      gate = null;
      return pending.future;
    }
    return Future.value(
      PrintTransportStatus(isAvailable: isAvailable, message: 'status'),
    );
  }

  @override
  Future<PrintTransportResult> printJob({
    required PrintJob job,
    required PrinterEndpoint endpoint,
  }) async => const PrintTransportResult.success('printed');

  @override
  Future<PrintTransportResult> printBytes({
    required List<int> bytes,
    required PrinterEndpoint endpoint,
  }) async {
    printed += 1;
    return const PrintTransportResult.success('printed');
  }

  @override
  Future<PrintTransportResult> printTest(PrinterEndpoint endpoint) async {
    printed += 1;
    return const PrintTransportResult.success('printed');
  }
}

/// A repository whose saves can be made to fail, to prove the list on
/// screen is only ever the list on disk.
class _FlakyPrintingRepository extends PrintingRepository {
  _FlakyPrintingRepository(_StatusTransport transport)
    : super(
        PosApiService(),
        wifiTransport: transport,
        serialTransport: transport,
        bluetoothTransport: transport,
        usbTransport: transport,
        fakeTransport: transport,
      );

  bool failSaves = false;

  @override
  Future<Result<void>> saveDevicePrinters(DevicePrinters printers) {
    if (failSaves) {
      return Future.value(Error(Exception('disk full')));
    }
    return super.saveDevicePrinters(printers);
  }

  @override
  Future<Result<List<PrinterEndpoint>>> discoverPrinters() async {
    return const Ok([
      PrinterEndpoint(
        kind: PrintTransportKind.wifi,
        name: 'Kitchen XP',
        address: '10.0.0.9',
      ),
      PrinterEndpoint(
        kind: PrintTransportKind.system,
        name: 'HP LaserJet',
        address: 'ipp://hp',
        outputMode: PrinterOutputMode.pdfA4,
      ),
    ]);
  }
}

class _CountingPrepStations extends PrepStationRepository {
  _CountingPrepStations() : super(PosApiService());

  int loads = 0;

  @override
  Future<Result<List<PrepStation>>> loadStations() async {
    loads += 1;
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
        name: 'قديمة',
        printerProfileId: null,
        printerProfileName: '',
        categoryIds: [],
        categoryNames: [],
        isDefault: false,
        isActive: false,
        priority: 1,
      ),
    ]);
  }
}

const _counter = DevicePrinter(
  id: 'counter',
  config: PrinterConfig(
    endpoint: PrinterEndpoint(
      kind: PrintTransportKind.wifi,
      name: 'XP-80C',
      address: '192.168.1.50',
    ),
  ),
  roles: {PrinterRole.posReceipt, PrinterRole.barcodeLabels},
);

const _labels = DevicePrinter(
  id: 'labels',
  config: PrinterConfig(
    endpoint: PrinterEndpoint(
      kind: PrintTransportKind.usb,
      name: 'HPRT',
      address: 'printer:1:2',
    ),
  ),
);

void main() {
  late _StatusTransport transport;
  late _FlakyPrintingRepository repository;

  setUp(() {
    installMemoryKeyValueStore();
    transport = _StatusTransport();
    repository = _FlakyPrintingRepository(transport);
  });

  Future<PrintingSettingsViewModel> loadedViewModel({
    List<DevicePrinter> printers = const [_counter, _labels],
    PrepStationRepository? stations,
  }) async {
    await repository.saveDevicePrinters(DevicePrinters(printers));
    final viewModel = PrintingSettingsViewModel(
      repository,
      prepStationRepository: stations,
      autoLoad: false,
      statusCheckInterval: const Duration(hours: 1),
    );
    addTearDown(viewModel.dispose);
    await viewModel.load();
    return viewModel;
  }

  group('PrintingSettingsViewModel', () {
    test('reassigning a job saves it and moves it', () async {
      final viewModel = await loadedViewModel();

      expect(
        await viewModel.assignRole(PrinterRole.barcodeLabels, 'labels'),
        isTrue,
      );

      expect(viewModel.holderOf(PrinterRole.barcodeLabels)?.id, 'labels');
      expect(viewModel.printers.byId('counter')!.roles, {
        PrinterRole.posReceipt,
      });
      final onDisk = await repository.loadDevicePrinters();
      expect(
        (onDisk as Ok<DevicePrinters>).value
            .holderOf(PrinterRole.barcodeLabels)
            ?.id,
        'labels',
      );
    });

    test('a save that fails leaves the list as it was on disk', () async {
      final viewModel = await loadedViewModel();
      repository.failSaves = true;

      expect(await viewModel.removePrinter('counter'), isFalse);

      expect(viewModel.hasSaveError, isTrue);
      expect(viewModel.printers.byId('counter'), isNotNull);
      expect(viewModel.receiptPrinter?.id, 'counter');
    });

    test('two quick changes both land, in order', () async {
      final viewModel = await loadedViewModel();

      final first = viewModel.assignRole(PrinterRole.barcodeLabels, 'labels');
      final second = viewModel.assignRole(PrinterRole.posReceipt, 'labels');
      await Future.wait([first, second]);

      expect(viewModel.holderOf(PrinterRole.barcodeLabels)?.id, 'labels');
      expect(viewModel.holderOf(PrinterRole.posReceipt)?.id, 'labels');
      expect(viewModel.printers.byId('counter')!.roles, isEmpty);
    });

    test('watches the receipt printer for the app-wide warning', () async {
      transport.isAvailable = false;
      final viewModel = await loadedViewModel();
      await Future<void>.delayed(Duration.zero);

      expect(viewModel.connectionState, PrinterConnectionState.disconnected);
      expect(viewModel.shouldWarnPrinterDisconnected, isTrue);

      await viewModel.removePrinter('counter');
      expect(viewModel.connectionState, PrinterConnectionState.notConfigured);
      expect(viewModel.shouldWarnPrinterDisconnected, isFalse);
    });

    test('a card test prints the printer\'s most important job', () async {
      final viewModel = await loadedViewModel();

      await viewModel.testPrinter('counter');

      expect(transport.printed, 1);
      expect(viewModel.testResultOf('counter')?.kind, PrinterTestKind.receipt);
      expect(viewModel.testResultOf('counter')?.isSuccess, isTrue);
    });

    test(
      'kitchen stations load only for someone allowed to see them',
      () async {
        final stations = _CountingPrepStations();
        final viewModel = await loadedViewModel(stations: stations);

        await viewModel.loadKitchenStations(allowed: false);
        expect(stations.loads, 0);
        expect(
          viewModel.kitchenStationsState,
          KitchenStationsState.unavailable,
        );

        await viewModel.loadKitchenStations(allowed: true);
        expect(stations.loads, 1);
        // A stopped station is not a job anyone can print.
        expect(viewModel.kitchenStations.map((station) => station.name), [
          'الشواية',
        ]);
      },
    );
  });

  group('PrinterEditorViewModel', () {
    test('a till\'s first printer does receipts and labels', () async {
      final viewModel = await loadedViewModel(printers: const []);
      final editor = PrinterEditorViewModel(viewModel);
      addTearDown(editor.dispose);

      expect(editor.isNew, isTrue);
      expect(editor.draft.roles, {
        PrinterRole.posReceipt,
        PrinterRole.barcodeLabels,
      });
      expect(editor.hasDevice, isFalse);
      expect(editor.canSave, isFalse);
      expect(editor.isDirty, isFalse);
    });

    test('adding a label printer takes the job from the counter', () async {
      final viewModel = await loadedViewModel(printers: const [_counter]);
      final editor = PrinterEditorViewModel(viewModel);
      addTearDown(editor.dispose);
      // Later printers start with no job: which one they take is the point.
      expect(editor.draft.roles, isEmpty);

      await viewModel.discoverPrinters();
      editor.selectDevice(viewModel.discoveredPrinters.first);
      editor.setLabel('  الملصقات ');
      editor.setRole(PrinterRole.barcodeLabels, true);

      expect(editor.otherHolderOf(PrinterRole.barcodeLabels)?.id, 'counter');
      expect(editor.canSave, isTrue);
      expect(await editor.save(), isTrue);

      final added = viewModel.holderOf(PrinterRole.barcodeLabels)!;
      expect(added.id, editor.draft.id);
      expect(added.label, 'الملصقات');
      expect(added.endpoint.address, '10.0.0.9');
      expect(viewModel.printers.byId('counter')!.roles, {
        PrinterRole.posReceipt,
      });
    });

    test('pointing a printer elsewhere keeps its settings', () async {
      const calibrated = DevicePrinter(
        id: 'calibrated',
        config: PrinterConfig(
          endpoint: PrinterEndpoint(
            kind: PrintTransportKind.wifi,
            name: 'Old port',
            address: '10.0.0.1',
            paperWidthMm: 58,
            labelWidthMm: 38,
          ),
        ),
        roles: {PrinterRole.barcodeLabels},
      );
      final viewModel = await loadedViewModel(printers: const [calibrated]);
      final editor = PrinterEditorViewModel(
        viewModel,
        printer: viewModel.printers.byId('calibrated'),
      );
      addTearDown(editor.dispose);

      editor.useNetworkAddress('10.0.0.77', port: 9101);

      expect(editor.endpoint.address, '10.0.0.77');
      expect(editor.endpoint.port, 9101);
      expect(editor.endpoint.paperWidthMm, 58);
      expect(editor.endpoint.labelWidthMm, 38);
      expect(editor.isDirty, isTrue);
      expect(editor.deviceGeneration, 1);
    });

    test('a thermal device cannot keep the documents job', () async {
      final viewModel = await loadedViewModel(printers: const []);
      final editor = PrinterEditorViewModel(viewModel);
      addTearDown(editor.dispose);

      // Before a device is chosen every job is open.
      editor.setRole(PrinterRole.documents, true);
      expect(editor.draft.holds(PrinterRole.documents), isTrue);

      editor.useNetworkAddress('10.0.0.5');

      expect(editor.draft.holds(PrinterRole.documents), isFalse);
      expect(editor.canTake(PrinterRole.documents), isFalse);
      editor.setRole(PrinterRole.documents, true);
      expect(editor.draft.holds(PrinterRole.documents), isFalse);
    });

    test('warns when the device is already another printer', () async {
      final viewModel = await loadedViewModel(printers: const [_counter]);
      final editor = PrinterEditorViewModel(viewModel);
      addTearDown(editor.dispose);

      editor.useNetworkAddress('192.168.1.50');

      expect(editor.duplicateOf?.id, 'counter');
    });

    test('a failed save keeps the editor open with the draft', () async {
      final viewModel = await loadedViewModel(printers: const [_counter]);
      final editor = PrinterEditorViewModel(
        viewModel,
        printer: viewModel.printers.byId('counter'),
      );
      addTearDown(editor.dispose);
      editor.setLabel('الكاشير');
      repository.failSaves = true;

      expect(await editor.save(), isFalse);

      expect(editor.hasSaveError, isTrue);
      expect(editor.isDirty, isTrue);
      expect(viewModel.printers.byId('counter')!.label, isEmpty);
    });
  });

  test('a late answer about a printer\'s old device is not kept', () async {
    final viewModel = await loadedViewModel();
    await Future<void>.delayed(Duration.zero);
    transport.isAvailable = false;
    final oldDeviceAnswer = Completer<PrintTransportStatus>();
    transport.gate = oldDeviceAnswer;

    final checking = viewModel.checkConnection('labels');
    expect(viewModel.connectionOf('labels'), PrinterConnectionState.checking);

    // Pointed at another device while the old one is still being asked.
    final moved = viewModel.printers.byId('labels')!;
    await viewModel.savePrinter(
      moved.copyWith(
        config: moved.config.copyWith(
          endpoint: moved.endpoint.copyWith(address: 'printer:9:9'),
        ),
      ),
    );
    oldDeviceAnswer.complete(
      const PrintTransportStatus(isAvailable: true, message: 'old device'),
    );
    await checking;
    await Future<void>.delayed(Duration.zero);

    // The old device answered "ready"; the new one, asked in its own right,
    // is not answering — and that is what the printer shows.
    expect(
      viewModel.connectionOf('labels'),
      PrinterConnectionState.disconnected,
    );
  });
}
