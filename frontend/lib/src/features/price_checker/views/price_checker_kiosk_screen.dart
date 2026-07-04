import 'dart:async';

import 'package:flutter/material.dart';
// compat/win8: mobile_scanner (camera scanning) is dropped. The kiosk was
// already camera-less on Windows (priceCheckerCameraScanningSupported is false
// there), so it runs entirely on the wedge scanner + manual entry here.
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../../core/result.dart';
import '../../../data/models/price_checker_config.dart';
import '../../../data/models/price_lookup_result.dart';
import '../../../data/repositories/price_checker_repository.dart';
import '../../../data/services/connection_profile_storage.dart';
import '../../../shared/barcode/barcode_scan_listener.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/price_checker/kiosk_speech_service.dart';
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
    this.speechService,
  });

  final PriceCheckerRepository repository;
  final PriceCheckerModeController controller;
  final ConnectionProfileStorage connectionProfileStorage;

  /// Speaks found products aloud. Injectable for tests; a real one is created
  /// on demand when the kiosk first needs to talk.
  final KioskSpeechService? speechService;

  @override
  State<PriceCheckerKioskScreen> createState() =>
      _PriceCheckerKioskScreenState();
}

class _PriceCheckerKioskScreenState extends State<PriceCheckerKioskScreen> {
  static const _notFoundDwell = Duration(seconds: 7);
  static const _errorDwell = Duration(seconds: 5);

  PriceCheckerKioskStatus _status = PriceCheckerKioskStatus.idle;
  PriceLookupResult? _result;
  String _barcode = '';
  String _shopName = '';
  Timer? _resetTimer;
  int _lookupSeq = 0;

  KioskSpeechService? _speech;
  bool _wakelockEnabled = false;

  /// How long a found product stays on screen (Device Settings, per device).
  Duration get _foundDwell =>
      Duration(seconds: widget.controller.config.foundDwellSeconds);

  @override
  void initState() {
    super.initState();
    // A shelf price checker must never sleep — the shopper should always meet a
    // live screen. Best-effort: a platform without a wakelock plugin just
    // stays on its normal timeout.
    unawaited(_enableWakelock());
    _resolveShopName();
    _announceToFleet();
  }

  @override
  void dispose() {
    _resetTimer?.cancel();
    unawaited(_speech?.dispose());
    if (_wakelockEnabled) {
      unawaited(WakelockPlus.disable());
    }
    super.dispose();
  }

  Future<void> _enableWakelock() async {
    try {
      await WakelockPlus.enable();
      _wakelockEnabled = true;
    } catch (_) {
      // No wakelock support on this platform — the kiosk still works.
    }
  }

  /// Announces the found product over TTS (name + price), honouring the
  /// per-device toggle. Silent when disabled or when no voice is available.
  void _speakResult(PriceLookupResult result) {
    if (!widget.controller.config.speakResults || !result.found) {
      return;
    }
    final l10n = AppLocalizations.of(context)!;
    final speech = _speech ??= widget.speechService ?? KioskSpeechService();
    unawaited(
      speech.speak(
        l10n.priceCheckerSpokenResult(
          result.productName,
          formatSpokenMoney(result.finalPrice),
        ),
      ),
    );
  }

  /// Shared entry point for the wedge-scanner and manual-entry scans (camera
  /// scanning is dropped on this build).
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
        // Announce the product aloud. Only reached on a genuine lookup (the
        // camera's same-product re-reports short-circuit in _handleScan before
        // here), so a product on the shelf isn't repeated every second.
        _speakResult(lookup);
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
          // compat/win8: no camera preview (mobile_scanner dropped).
          cameraPreview: null,
          onManualEntry: _manualEntry,
          onExitRequested: _requestExit,
        ),
      ),
    );
  }
}

// compat/win8: _CameraFeed / _CameraFeedMessage removed (mobile_scanner).

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
