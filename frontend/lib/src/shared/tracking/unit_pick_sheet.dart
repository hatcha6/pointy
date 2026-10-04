import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../core/result.dart';
import '../../data/models/stock_unit.dart';
import '../barcode/barcode_scan_listener.dart';
import '../components/components.dart';
import '../responsive/responsive.dart';

/// One document line whose articles somebody has to name before it can go.
class UnitPickLine {
  const UnitPickLine({
    required this.key,
    required this.title,
    required this.count,
    required this.variantId,
  });

  /// Echoed back as this line's key in [showUnitPickSheet]'s result.
  final int key;
  final String title;

  /// Exactly how many articles this line moves, in base units.
  final int count;
  final int variantId;
}

/// Loads the articles a line may pick from. [code] narrows the list to one
/// scanned identifier, for a handset that is not on the first page.
typedef UnitPickLoader =
    Future<Result<StockUnitPage>> Function(int variantId, {String code});

/// Which handsets are actually leaving — named, never guessed.
///
/// The transfer pick sheet's pattern for any document whose serialised lines
/// must name their articles: a section per line, exactly [UnitPickLine.count]
/// picks in each, and a scan field so a scanner pointed at the sheet ticks the
/// handset it reads. The server will not pick for the caller — guessing an
/// IMEI would put a made-up number in the ledger — so neither does this.
///
/// Returns `{line key: unit ids}`, or null when dismissed.
Future<Map<int, List<int>>?> showUnitPickSheet(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  required List<UnitPickLine> lines,
  required UnitPickLoader loadUnits,
}) {
  return showModalBottomSheet<Map<int, List<int>>>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (context) => _UnitPickSheet(
      title: title,
      message: message,
      confirmLabel: confirmLabel,
      lines: lines,
      loadUnits: loadUnits,
    ),
  );
}

class _UnitPickSheet extends StatefulWidget {
  const _UnitPickSheet({
    required this.title,
    required this.message,
    required this.confirmLabel,
    required this.lines,
    required this.loadUnits,
  });

  final String title;
  final String message;
  final String confirmLabel;
  final List<UnitPickLine> lines;
  final UnitPickLoader loadUnits;

  @override
  State<_UnitPickSheet> createState() => _UnitPickSheetState();
}

class _UnitPickSheetState extends State<_UnitPickSheet> {
  final TextEditingController _scan = TextEditingController();
  final FocusNode _scanFocus = FocusNode();
  final Map<int, List<StockUnit>> _available = {};
  final Map<int, Set<int>> _picked = {};
  bool _isLoading = true;
  bool _loadFailed = false;
  bool _notFound = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _scan.dispose();
    _scanFocus.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final results = await Future.wait([
      for (final line in widget.lines) widget.loadUnits(line.variantId),
    ]);
    if (!mounted) {
      return;
    }
    setState(() {
      for (final (index, line) in widget.lines.indexed) {
        switch (results[index]) {
          case Ok<StockUnitPage>(:final value):
            _available[line.key] = [...value.units];
          case Error<StockUnitPage>():
            _loadFailed = true;
        }
      }
      _isLoading = false;
    });
    // Focused once the lists land, so a scanner burst cannot arrive before
    // there is anything to tick.
    _scanFocus.requestFocus();
  }

  /// Either identifier, because a dual-SIM handset is scanned off whichever of
  /// its two numbers the box happens to show.
  static String _normalize(String value) =>
      value.toUpperCase().replaceAll(RegExp(r'[\s\-._/]'), '');

  bool _isExactly(StockUnit unit, String code) =>
      _normalize(unit.code) == code || _normalize(unit.secondaryCode) == code;

  bool _isPickedAnywhere(int unitId) =>
      _picked.values.any((chosen) => chosen.contains(unitId));

  bool _isFull(UnitPickLine line) =>
      (_picked[line.key]?.length ?? 0) >= line.count;

  bool get _isComplete => widget.lines.every(
    (line) => (_picked[line.key]?.length ?? 0) == line.count,
  );

  void _toggle(UnitPickLine line, StockUnit unit) {
    setState(() {
      final chosen = _picked.putIfAbsent(line.key, () => <int>{});
      if (chosen.remove(unit.id)) {
        return;
      }
      if (!_isFull(line) && !_isPickedAnywhere(unit.id)) {
        chosen.add(unit.id);
      }
    });
  }

  /// A scan ticks the handset it reads: from the lists already loaded, or —
  /// for one past the first page — by asking the server for that identifier.
  Future<void> _onScan(String raw) async {
    final code = _normalize(raw);
    if (code.isEmpty) {
      return;
    }
    for (final line in widget.lines) {
      for (final unit in _available[line.key] ?? const <StockUnit>[]) {
        if (!_isExactly(unit, code)) {
          continue;
        }
        // Scanned twice is still picked once.
        if (!_isPickedAnywhere(unit.id) && !_isFull(line)) {
          _picked.putIfAbsent(line.key, () => <int>{}).add(unit.id);
        }
        _clearScan(found: true);
        return;
      }
    }
    for (final line in widget.lines) {
      if (_isFull(line)) {
        continue;
      }
      final result = await widget.loadUnits(line.variantId, code: raw.trim());
      if (!mounted) {
        return;
      }
      if (result case Ok<StockUnitPage>(:final value)) {
        for (final unit in value.units) {
          if (_isExactly(unit, code) && !_isPickedAnywhere(unit.id)) {
            final list = _available.putIfAbsent(line.key, () => []);
            if (!list.any((known) => known.id == unit.id)) {
              list.insert(0, unit);
            }
            _picked.putIfAbsent(line.key, () => <int>{}).add(unit.id);
            _clearScan(found: true);
            return;
          }
        }
      }
    }
    _clearScan(found: false);
  }

  void _clearScan({required bool found}) {
    setState(() {
      _notFound = !found;
      if (found) {
        _scan.clear();
      }
    });
    _scanFocus.requestFocus();
  }

  List<StockUnit> _visible(UnitPickLine line) {
    final units = _available[line.key] ?? const <StockUnit>[];
    final term = _normalize(_scan.text);
    if (term.isEmpty) {
      return units;
    }
    return units
        .where(
          (unit) =>
              _normalize(unit.code).contains(term) ||
              _normalize(unit.secondaryCode).contains(term),
        )
        .toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

    return SafeArea(
      child: Padding(
        padding: spacing.pagePadding.copyWith(
          bottom:
              spacing.pagePadding.bottom +
              MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PointyDetailCallout(
              icon: Icons.qr_code_scanner_outlined,
              title: widget.title,
              message: widget.message,
            ),
            SizedBox(height: spacing.md),
            ScanWedgeTarget(
              child: TextField(
                controller: _scan,
                focusNode: _scanFocus,
                textInputAction: TextInputAction.done,
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search),
                  hintText: l10n.unitPickSearchHint,
                  isDense: true,
                ),
                onChanged: (_) => setState(() => _notFound = false),
                onSubmitted: _onScan,
              ),
            ),
            if (_notFound) ...[
              SizedBox(height: spacing.sm),
              PointyInlineMessage.warning(
                message: l10n.unitPickNotFound,
                compact: true,
              ),
            ],
            SizedBox(height: spacing.md),
            if (_isLoading)
              const Center(child: PointySpinner())
            else
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    if (_loadFailed)
                      PointyInlineMessage.error(
                        message: l10n.unitPickLoadFailed,
                        compact: true,
                      ),
                    for (final line in widget.lines) ..._section(l10n, line),
                  ],
                ),
              ),
            SizedBox(height: spacing.md),
            if (!_isComplete && !_isLoading) ...[
              PointyInlineMessage.warning(
                message: l10n.unitPickIncomplete,
                compact: true,
              ),
              SizedBox(height: spacing.sm),
            ],
            FilledButton(
              onPressed: _isComplete
                  ? () => Navigator.of(context).pop({
                      for (final line in widget.lines)
                        line.key: (_picked[line.key] ?? const <int>{}).toList(
                          growable: false,
                        ),
                    })
                  : null,
              child: Text(widget.confirmLabel),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _section(AppLocalizations l10n, UnitPickLine line) {
    final chosen = _picked[line.key] ?? const <int>{};
    final visible = _visible(line);
    return [
      PointySectionHeader(
        title: line.title,
        trailing: Text(l10n.unitPickProgress(chosen.length, line.count)),
      ),
      if (visible.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text(l10n.unitPickEmpty),
        ),
      for (final unit in visible)
        CheckboxListTile(
          dense: true,
          value: chosen.contains(unit.id),
          // A handset ticked on another line of the same product is already
          // going back there; it cannot leave twice.
          onChanged:
              chosen.contains(unit.id) ||
                  (!_isPickedAnywhere(unit.id) && !_isFull(line))
              ? (_) => _toggle(line, unit)
              : null,
          title: Text(unit.code),
          subtitle: unit.secondaryCode.isEmpty
              ? null
              : Text(unit.secondaryCode),
        ),
    ];
  }
}
