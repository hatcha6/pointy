import 'package:flutter/widgets.dart';

import '../../../core/result.dart';
import '../../../data/repositories/catalog_repository.dart';

/// Fills in the SKU a new variant is going to be saved with.
///
/// The server numbers a blank SKU itself — 1000, 1001, 1002 — so the forms
/// could leave the field empty. But then the owner cannot see the code the
/// product will carry, nor copy it into the barcode. So the form asks what
/// comes next and writes it in, and only ever into a field the user has not
/// typed in: a SKU somebody chose is theirs, and an existing variant's code is
/// never filled at all.
///
/// Nothing is reserved by asking. A number another till takes while the form
/// is open is caught by [refresh] right before saving, which moves every field
/// still holding a filled-in number to the next free one.
class AutoSkuFiller {
  AutoSkuFiller(this.catalogRepository);

  final CatalogRepository catalogRepository;

  int? _next;
  final Map<TextEditingController, String> _filled = {};

  /// Whether the server has said which number comes next.
  bool get isReady => _next != null;

  /// Asks the server for the next number; true when it changed. A failed
  /// lookup keeps what the fields already show — the server still numbers a
  /// blank SKU, so the form never waits on this.
  Future<bool> refresh() async {
    final result = await catalogRepository.nextVariantSku();
    if (result is! Ok<String>) {
      return false;
    }
    final next = int.tryParse(result.value);
    if (next == null || next == _next) {
      return false;
    }
    _next = next;
    return true;
  }

  /// The number [offset] places after the next one — every number after it
  /// is free too, so several new variants count up from it. Empty until
  /// [refresh] has an answer.
  String numberAt(int offset) => _next == null ? '' : '${_next! + offset}';

  /// Writes [sku] into [controller] unless the user has typed their own code.
  ///
  /// A [barcode] still holding the number this filled in before — the
  /// one-click "barcode = SKU" — moves with it, so the two stay the same code.
  void fill(
    TextEditingController controller,
    String sku, {
    TextEditingController? barcode,
  }) {
    final previous = _filled[controller];
    final text = controller.text.trim();
    if (text.isNotEmpty && text != previous) {
      return;
    }
    if (barcode != null &&
        previous != null &&
        previous.isNotEmpty &&
        barcode.text.trim() == previous) {
      barcode.text = sku;
    }
    if (controller.text != sku) {
      controller.text = sku;
    }
    _filled[controller] = sku;
  }

  /// Whether [controller] holds exactly what [fill] put there — an untouched
  /// field, which the unsaved-changes guard must not count as the user's work.
  bool holdsFilledValue(TextEditingController controller) {
    final filled = _filled[controller];
    return filled != null && filled.isNotEmpty && controller.text == filled;
  }

  /// Stops tracking a controller that is about to be disposed.
  void forget(TextEditingController controller) => _filled.remove(controller);
}
