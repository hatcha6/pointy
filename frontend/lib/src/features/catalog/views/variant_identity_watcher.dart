import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/result.dart';
import '../../../data/models/catalog_identity_conflict.dart';
import '../../../data/repositories/catalog_repository.dart';

/// What the form knows about one code right now.
enum IdentityStatus {
  /// Nothing typed yet, or the value changed and the answer is stale.
  idle,

  /// A lookup is in flight.
  checking,

  /// Confirmed free.
  free,

  /// Already owned by another product — [IdentityFieldState.conflict] says by
  /// which.
  taken,

  /// The lookup itself failed. Never blocks the save: the server still has the
  /// final word, and an offline shop must be able to add products.
  unavailable,
}

class IdentityFieldState {
  const IdentityFieldState({
    this.status = IdentityStatus.idle,
    this.conflict,
    this.value = '',
  });

  final IdentityStatus status;
  final CatalogIdentityConflict? conflict;

  /// The value the state describes; a later edit makes it stale.
  final String value;

  bool get isTaken => status == IdentityStatus.taken;
  bool get isFree => status == IdentityStatus.free;
  bool get isChecking => status == IdentityStatus.checking;
}

/// Answers "is this SKU / barcode already taken?" while the user is still
/// typing, and holds whatever the server said when a save was rejected.
///
/// A duplicate barcode used to fail only at save time — and, on the product
/// endpoints, as an opaque 500. Watching the two inputs turns that into a
/// per-field answer that names the product already using the code, so the
/// cashier fixes it before pressing save.
///
/// Deliberately advisory: a failed or slow lookup never blocks submitting. The
/// backend re-checks every write and answers with the same conflict shape, so
/// the worst case is the old behaviour (an error after save), not a stuck form.
class VariantIdentityWatcher extends ChangeNotifier {
  VariantIdentityWatcher({
    required this.catalogRepository,
    required this.skuController,
    required this.barcodeController,
    this.excludeVariantId,
    this.debounce = const Duration(milliseconds: 450),
  }) {
    _skuState = IdentityFieldState(value: skuController.text.trim());
    _barcodeState = IdentityFieldState(value: barcodeController.text.trim());
    skuController.addListener(_onChanged);
    barcodeController.addListener(_onChanged);
    // A form opened on a scanned code (or on an existing variant) checks
    // straight away, without waiting for a keystroke that may never come.
    if (_hasSomethingToCheck) {
      _schedule();
    }
  }

  final CatalogRepository catalogRepository;
  final TextEditingController skuController;
  final TextEditingController barcodeController;

  /// The variant being edited — its own SKU/barcode are not a conflict.
  final int? excludeVariantId;
  final Duration debounce;

  Timer? _timer;
  int _requestId = 0;
  var _disposed = false;
  var _enabled = true;
  late IdentityFieldState _skuState;
  late IdentityFieldState _barcodeState;

  IdentityFieldState get skuState => _skuState;
  IdentityFieldState get barcodeState => _barcodeState;

  /// Turns watching off when the two controllers stop being one variant's
  /// codes — the product form reuses them as a SKU *prefix* and a base price
  /// once the product generates variants, and a prefix is not a code to check.
  set enabled(bool value) {
    if (_enabled == value) {
      return;
    }
    _enabled = value;
    _timer?.cancel();
    // Drop any answer about the old meaning of these fields.
    _requestId += 1;
    _skuState = IdentityFieldState(value: skuController.text.trim());
    _barcodeState = IdentityFieldState(value: barcodeController.text.trim());
    if (_enabled) {
      _schedule();
    }
    notifyListeners();
  }

  bool get enabled => _enabled;

  IdentityFieldState stateFor(CatalogIdentityField field) {
    return field == CatalogIdentityField.sku ? _skuState : _barcodeState;
  }

  /// True when either code is known to be taken — the form uses this to keep a
  /// known-bad save from being attempted at all.
  bool get hasConflict => _skuState.isTaken || _barcodeState.isTaken;

  bool get _hasSomethingToCheck =>
      skuController.text.trim().isNotEmpty ||
      barcodeController.text.trim().isNotEmpty;

  /// Records what the server said about a rejected save.
  void applyConflicts(Iterable<CatalogIdentityConflict> conflicts) {
    for (final conflict in conflicts) {
      final state = IdentityFieldState(
        status: IdentityStatus.taken,
        conflict: conflict,
        value: conflict.value.isEmpty
            ? _controllerFor(conflict.field).text.trim()
            : conflict.value,
      );
      if (conflict.field == CatalogIdentityField.sku) {
        _skuState = state;
      } else {
        _barcodeState = state;
      }
    }
    if (conflicts.isNotEmpty) {
      notifyListeners();
    }
  }

  /// Re-checks both codes now — used right before a save so a conflict typed in
  /// the last few hundred milliseconds is still caught client-side.
  Future<void> refresh() async {
    _timer?.cancel();
    await _check();
  }

  TextEditingController _controllerFor(CatalogIdentityField field) {
    return field == CatalogIdentityField.sku
        ? skuController
        : barcodeController;
  }

  void _onChanged() {
    if (!_enabled) {
      return;
    }
    var changed = false;
    final sku = skuController.text.trim();
    if (sku != _skuState.value) {
      _skuState = IdentityFieldState(value: sku);
      changed = true;
    }
    final barcode = barcodeController.text.trim();
    if (barcode != _barcodeState.value) {
      _barcodeState = IdentityFieldState(value: barcode);
      changed = true;
    }
    if (!changed) {
      return;
    }
    notifyListeners();
    _schedule();
  }

  void _schedule() {
    _timer?.cancel();
    if (!_enabled || !_hasSomethingToCheck) {
      return;
    }
    _timer = Timer(debounce, _check);
  }

  Future<void> _check() async {
    if (!_enabled) {
      return;
    }
    final sku = skuController.text.trim();
    final barcode = barcodeController.text.trim();
    if (sku.isEmpty && barcode.isEmpty) {
      return;
    }

    final requestId = ++_requestId;
    _markChecking(sku: sku, barcode: barcode);

    final result = await catalogRepository.checkVariantIdentity(
      sku: sku,
      barcode: barcode,
      excludeVariantId: excludeVariantId,
    );
    // A newer keystroke already started its own lookup — this answer describes
    // a value the user has moved on from.
    if (_disposed || requestId != _requestId) {
      return;
    }

    switch (result) {
      case Ok<CatalogIdentityCheck>():
        _apply(
          CatalogIdentityField.sku,
          value: sku,
          conflict: result.value.sku,
        );
        _apply(
          CatalogIdentityField.barcode,
          value: barcode,
          conflict: result.value.barcode,
        );
      case Error<CatalogIdentityCheck>():
        _markUnavailable(sku: sku, barcode: barcode);
    }
    notifyListeners();
  }

  void _markChecking({required String sku, required String barcode}) {
    if (sku.isNotEmpty) {
      _skuState = IdentityFieldState(
        status: IdentityStatus.checking,
        value: sku,
      );
    }
    if (barcode.isNotEmpty) {
      _barcodeState = IdentityFieldState(
        status: IdentityStatus.checking,
        value: barcode,
      );
    }
    notifyListeners();
  }

  void _markUnavailable({required String sku, required String barcode}) {
    if (sku.isNotEmpty) {
      _skuState = IdentityFieldState(
        status: IdentityStatus.unavailable,
        value: sku,
      );
    }
    if (barcode.isNotEmpty) {
      _barcodeState = IdentityFieldState(
        status: IdentityStatus.unavailable,
        value: barcode,
      );
    }
  }

  void _apply(
    CatalogIdentityField field, {
    required String value,
    required CatalogIdentityConflict? conflict,
  }) {
    final state = value.isEmpty
        ? IdentityFieldState(value: value)
        : IdentityFieldState(
            status: conflict == null
                ? IdentityStatus.free
                : IdentityStatus.taken,
            conflict: conflict,
            value: value,
          );
    if (field == CatalogIdentityField.sku) {
      _skuState = state;
    } else {
      _barcodeState = state;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    skuController.removeListener(_onChanged);
    barcodeController.removeListener(_onChanged);
    super.dispose();
  }
}

/// The localized sentence for a conflict.
///
/// Built from the conflict's structured fields rather than its `message`: the
/// backend writes English, and this text sits under an Arabic input.
String identityConflictMessage(
  AppLocalizations l10n,
  CatalogIdentityConflict conflict,
) {
  final isBarcode = conflict.field == CatalogIdentityField.barcode;
  switch (conflict.kind) {
    case CatalogIdentityConflictKind.race:
      return l10n.identityCodeClaimedDuringSave;
    case CatalogIdentityConflictKind.payload:
      return isBarcode
          ? l10n.barcodeDuplicateInFormError
          : l10n.skuDuplicateInFormError;
    case CatalogIdentityConflictKind.unit:
      return l10n.barcodeTakenByUnitError(
        conflict.unitCode,
        conflict.ownerLabel,
      );
    case CatalogIdentityConflictKind.variant:
    case CatalogIdentityConflictKind.unknown:
      final owner = conflict.ownerLabel;
      if (owner.isEmpty) {
        return isBarcode
            ? l10n.barcodeTakenUnknownOwner
            : l10n.skuTakenUnknownOwner;
      }
      final base = isBarcode
          ? l10n.barcodeTakenError(owner)
          : l10n.skuTakenError(owner);
      return conflict.isArchived
          ? '$base ${l10n.identityArchivedOwnerSuffix}'
          : base;
  }
}

/// The inline error a field should show, or null when it has none.
String? identityErrorText(AppLocalizations l10n, IdentityFieldState state) {
  final conflict = state.conflict;
  if (!state.isTaken || conflict == null) {
    return null;
  }
  return identityConflictMessage(l10n, conflict);
}
