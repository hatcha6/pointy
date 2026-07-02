import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/result.dart';
import '../../../data/models/price_checker_config.dart';
import '../../../data/models/price_lookup_result.dart';
import '../../../data/repositories/price_checker_repository.dart';
import '../../../data/services/connection_profile_storage.dart';
import '../../../shared/barcode/barcode_scan_listener.dart';
import '../../../shared/design/design.dart';
import '../../../shared/price_checker/price_checker_mode_controller.dart';
import '../price_checker_mode_actions.dart';
import 'price_checker_kiosk_view.dart';
import 'price_checker_pin_pad.dart';

/// The live customer-facing kiosk: wires the barcode inputs (device camera,
/// wedge scanner, manual entry) and the LAN lookup endpoint to
/// [PriceCheckerKioskView], auto-resets between shoppers, and gates the exit
/// behind the configured PIN.
///
/// Boots without a logged-in user — the lookup endpoint is LAN-allowed — so a
/// price-checker device can sit on a shelf and just work.
class PriceCheckerKioskScreen extends StatefulWidget {
  const PriceCheckerKioskScreen({
    super.key,
    required this.repository,
    required this.controller,
    this.connectionProfileStorage =
        const SharedPreferencesConnectionProfileStorage(),
  });

  final PriceCheckerRepository repository;
  final PriceCheckerModeController controller;
  final ConnectionProfileStorage connectionProfileStorage;

  @override
  State<PriceCheckerKioskScreen> createState() =>
      _PriceCheckerKioskScreenState();
}

class _PriceCheckerKioskScreenState extends State<PriceCheckerKioskScreen>
    with WidgetsBindingObserver {
  static const _notFoundDwell = Duration(seconds: 7);
  static const _errorDwell = Duration(seconds: 5);

  PriceCheckerKioskStatus _status = PriceCheckerKioskStatus.idle;
  PriceLookupResult? _result;
  String _barcode = '';
  String _shopName = '';
  Timer? _resetTimer;
  int _lookupSeq = 0;

  MobileScannerController? _camera;
  StreamSubscription<BarcodeCapture>? _detections;

  /// How long a found product stays on screen (Device Settings, per device).
  Duration get _foundDwell =>
      Duration(seconds: widget.controller.config.foundDwellSeconds);

  @override
  void initState() {
    super.initState();
    _resolveShopName();
    _announceToFleet();
    if (priceCheckerCameraScanningSupported &&
        widget.controller.config.cameraEnabled) {
      _setUpCamera();
    }
  }

  @override
  void dispose() {
    _resetTimer?.cancel();
    if (_camera != null) {
      WidgetsBinding.instance.removeObserver(this);
      unawaited(_detections?.cancel());
      unawaited(_camera!.dispose());
    }
    super.dispose();
  }

  /// The screen owns the camera lifecycle (`autoStart: false`): the preview
  /// widget unmounts while a result is on screen, but detection must keep
  /// running so the next product can be scanned hands-free at any moment.
  void _setUpCamera() {
    final camera = MobileScannerController(
      autoStart: false,
      facing: switch (widget.controller.config.cameraFacing) {
        PriceCheckerCameraFacing.front => CameraFacing.front,
        PriceCheckerCameraFacing.back => CameraFacing.back,
      },
      // `noDuplicates` would swallow a re-scan of the same product forever;
      // throttle instead and dedupe in [_handleScan].
      detectionSpeed: DetectionSpeed.normal,
      detectionTimeoutMs: 900,
      formats: const [],
    );
    _camera = camera;
    _detections = camera.barcodes.listen(_onCameraDetection, onError: (_) {});
    WidgetsBinding.instance.addObserver(this);
    unawaited(_startCamera());
  }

  Future<void> _startCamera() async {
    final camera = _camera;
    if (camera == null) {
      return;
    }
    try {
      await camera.start();
    } on Exception {
      // Permission/hardware failures surface through controller.value.error,
      // which the preview's errorBuilder renders. A kiosk with a broken
      // camera must keep serving wedge-scanner lookups, so never rethrow.
    }
  }

  /// Kiosks run unattended around the clock: release the camera when the app
  /// goes inactive and reclaim it on resume, whatever state the kiosk is in
  /// (the preview widget's own handling only covers while it is mounted).
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final camera = _camera;
    if (camera == null || !camera.value.hasCameraPermission) {
      return;
    }
    switch (state) {
      case AppLifecycleState.resumed:
        unawaited(_startCamera());
      case AppLifecycleState.inactive:
        unawaited(camera.stop());
      case AppLifecycleState.detached:
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        break;
    }
  }

  void _onCameraDetection(BarcodeCapture capture) {
    if (!mounted) {
      return;
    }
    // Match the wedge listener: ignore scans while a dialog (PIN pad, manual
    // entry) sits on top of the kiosk.
    if (ModalRoute.of(context)?.isCurrent == false) {
      return;
    }
    for (final barcode in capture.barcodes) {
      final code = barcode.rawValue?.trim() ?? '';
      if (code.isNotEmpty) {
        _handleScan(code);
        return;
      }
    }
  }

  /// Shared entry point for camera, wedge-scanner, and manual-entry scans.
  void _handleScan(String code) {
    final barcode = code.trim();
    if (barcode.isEmpty) {
      return;
    }
    // The camera re-reports a product that stays in front of it about once a
    // second. Keep its result on screen (fresh dwell) instead of re-hitting
    // the lookup endpoint and flooding the fleet's scan-event log.
    if (barcode == _barcode) {
      switch (_status) {
        case PriceCheckerKioskStatus.found:
          _scheduleReset(_foundDwell);
          return;
        case PriceCheckerKioskStatus.notFound:
          _scheduleReset(_notFoundDwell);
          return;
        case PriceCheckerKioskStatus.loading:
          return; // Lookup already in flight.
        case PriceCheckerKioskStatus.idle:
        case PriceCheckerKioskStatus.disconnected:
          break; // Disconnected: a retry may now succeed.
      }
    }
    unawaited(_onBarcode(barcode));
  }

  Future<void> _resolveShopName() async {
    String name = widget.controller.config.deviceName;
    try {
      final profile = await widget.connectionProfileStorage.loadProfile();
      if ((profile?.shopName ?? '').isNotEmpty) {
        name = profile!.shopName;
      }
    } catch (_) {
      // Best effort — the logo carries the brand regardless.
    }
    if (mounted && name != _shopName) {
      setState(() => _shopName = name);
    }
  }

  /// Best-effort: refresh this kiosk's fleet entry (last-seen, name) on launch.
  void _announceToFleet() {
    final config = widget.controller.config;
    if (config.identifier.isEmpty) {
      return;
    }
    unawaited(
      widget.repository.selfRegister(
        identifier: config.identifier,
        name: config.deviceName,
        location: config.location,
      ),
    );
  }

  Future<void> _onBarcode(String code) async {
    final barcode = code.trim();
    if (barcode.isEmpty) {
      return;
    }
    _resetTimer?.cancel();
    final seq = ++_lookupSeq;
    setState(() {
      _status = PriceCheckerKioskStatus.loading;
      _barcode = barcode;
      _result = null;
    });

    final result = await widget.repository.lookup(
      barcode: barcode,
      deviceIdentifier: widget.controller.config.identifier,
    );
    if (!mounted || seq != _lookupSeq) {
      return;
    }

    switch (result) {
      case Ok<PriceLookupResult>(value: final lookup):
        setState(() {
          _result = lookup;
          _status = lookup.found
              ? PriceCheckerKioskStatus.found
              : PriceCheckerKioskStatus.notFound;
        });
        _scheduleReset(lookup.found ? _foundDwell : _notFoundDwell);
      case Error<PriceLookupResult>():
        setState(() => _status = PriceCheckerKioskStatus.disconnected);
        _scheduleReset(_errorDwell);
    }
  }

  void _scheduleReset(Duration dwell) {
    _resetTimer?.cancel();
    _resetTimer = Timer(dwell, () {
      if (!mounted) return;
      setState(() {
        _status = PriceCheckerKioskStatus.idle;
        _result = null;
        _barcode = '';
      });
    });
  }

  Future<void> _requestExit() async {
    _resetTimer?.cancel();
    final unlocked = await showPriceCheckerExitDialog(
      context,
      verify: widget.controller.verifyPin,
    );
    if (unlocked) {
      // Fully leave kiosk mode → app routing falls back to the login screen,
      // where a "Price Checker mode" button can send it back in.
      await widget.controller.exit();
      return;
    }
    _resumeResetIfFrozen();
  }

  Future<void> _manualEntry() async {
    _resetTimer?.cancel();
    final code = await showDialog<String>(
      context: context,
      builder: (context) => const _ManualEntryDialog(),
    );
    if (code != null && code.isNotEmpty) {
      _handleScan(code);
      return;
    }
    _resumeResetIfFrozen();
  }

  /// Dialogs pause the auto-reset; if one closes with a result still frozen on
  /// screen, restart it — an unattended kiosk must always find its way back to
  /// the scan screen on its own.
  void _resumeResetIfFrozen() {
    if (!mounted || _status == PriceCheckerKioskStatus.idle) {
      return;
    }
    _scheduleReset(switch (_status) {
      PriceCheckerKioskStatus.found => _foundDwell,
      PriceCheckerKioskStatus.notFound => _notFoundDwell,
      _ => _errorDwell,
    });
  }

  @override
  Widget build(BuildContext context) {
    final camera = _camera;
    return PopScope(
      // A kiosk must not be dismissable with the Android back button.
      canPop: false,
      child: BarcodeScanListener(
        onBarcodeScanned: _handleScan,
        child: PriceCheckerKioskView(
          status: _status,
          result: _result,
          barcode: _barcode,
          shopName: _shopName,
          cameraPreview: camera == null ? null : _CameraFeed(camera: camera),
          onManualEntry: _manualEntry,
          onExitRequested: _requestExit,
        ),
      ),
    );
  }
}

/// The raw camera feed handed to the view's viewfinder card. Failures (no
/// permission, no camera) render as a quiet in-card message — the kiosk keeps
/// serving wedge-scanner and manual lookups regardless.
class _CameraFeed extends StatelessWidget {
  const _CameraFeed({required this.camera});

  final MobileScannerController camera;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return MobileScanner(
      controller: camera,
      fit: BoxFit.cover,
      // The kiosk screen owns lifecycle for every kiosk state; the widget's
      // own handling would fight it (and stops covering when unmounted).
      useAppLifecycleState: false,
      errorBuilder: (context, error) => _CameraFeedMessage(
        icon: Icons.videocam_off_outlined,
        message: l10n.priceCheckerCameraUnavailable,
      ),
      placeholderBuilder: (context) => _CameraFeedMessage(
        icon: Icons.photo_camera_outlined,
        message: l10n.priceCheckerCameraStarting,
      ),
    );
  }
}

/// Icon + line shown on the viewfinder's black backdrop while the camera is
/// starting or unavailable.
class _CameraFeedMessage extends StatelessWidget {
  const _CameraFeedMessage({required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white70, size: 34),
            const SizedBox(height: 10),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 15),
            ),
          ],
        ),
      ),
    );
  }
}

/// Numeric manual entry for touch devices without a wedge scanner.
class _ManualEntryDialog extends StatefulWidget {
  const _ManualEntryDialog();

  @override
  State<_ManualEntryDialog> createState() => _ManualEntryDialogState();
}

class _ManualEntryDialogState extends State<_ManualEntryDialog> {
  String _code = '';

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final l10n = AppLocalizations.of(context)!;
    return Dialog(
      backgroundColor: colors.surface,
      insetPadding: const EdgeInsets.all(24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                l10n.priceCheckerManualEntryTitle,
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: colors.ink,
                ),
              ),
              const SizedBox(height: 20),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 14,
                ),
                decoration: BoxDecoration(
                  color: colors.subtleFill,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: colors.line),
                ),
                child: Text(
                  _code.isEmpty ? '—' : _code,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 2,
                    color: _code.isEmpty ? colors.mutedInk : colors.ink,
                  ),
                ),
              ),
              const SizedBox(height: 20),
              PriceCheckerKeypad(
                onDigit: (digit) {
                  if (_code.length >= 24) return;
                  setState(() => _code += digit);
                },
                onBackspace: () {
                  if (_code.isEmpty) return;
                  setState(() => _code = _code.substring(0, _code.length - 1));
                },
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: Text(l10n.cancelButton),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: _code.isEmpty
                          ? null
                          : () => Navigator.of(context).pop(_code),
                      child: Text(l10n.confirmButton),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
