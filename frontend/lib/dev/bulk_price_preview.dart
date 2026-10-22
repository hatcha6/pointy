// Dev-only preview harness for the rule-driven bulk price editor.
//
// Renders the editor with a fake catalog repository (no backend, no auth). The
// fake plans prices in Dart closely enough to show real-looking previews.
//
//   make frontend-bulk-price-preview
//
// Screens: editor (default) | filtered | selection | history | board
//
// `?screen=board` lays a phone frame and a wide frame side by side (size the
// viewport large, e.g. 1900x1000). See AGENTS.md ("UI preview harness").
// Not part of the shipping app. Safe to delete.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/bulk_price_preview.dart';
import 'package:pointy_frontend/src/data/models/bulk_price_rule.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/catalog/view_models/bulk_price_editor_view_model.dart';
import 'package:pointy_frontend/src/features/catalog/views/bulk_price/bulk_price_editor_screen.dart';
import 'package:pointy_frontend/src/features/catalog/views/bulk_price/bulk_price_history_sheet.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
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
      darkTheme: PointyTheme.dark(),
      themeMode: Uri.base.queryParameters['dark'] == '1'
          ? ThemeMode.dark
          : ThemeMode.light,
      builder: (context, child) => PointyNavigationRailScope(
        isActive: false,
        controller: PointyNavigationRailController(),
        child: child ?? const SizedBox.shrink(),
      ),
      home: const _PreviewRouter(),
    );
  }
}

class _PreviewRouter extends StatelessWidget {
  const _PreviewRouter();

  @override
  Widget build(BuildContext context) {
    final screen = Uri.base.queryParameters['screen'] ?? 'editor';
    return switch (screen) {
      'board' => const _Board(),
      'history' => const _HistoryHost(),
      _ => _editorFor(screen),
    };
  }
}

Widget _editorFor(String screen) {
  final repository = _FakeCatalogRepository();
  final viewModel = BulkPriceEditorViewModel(
    catalogRepository: repository,
    previewDebounce: const Duration(milliseconds: 200),
    selectedProducts: screen == 'selection'
        ? const [
            BulkPriceRef(id: 1, label: 'كوكاكولا 330مل'),
            BulkPriceRef(id: 2, label: 'بيبسي 330مل'),
            BulkPriceRef(id: 5, label: 'مياه 1.5 لتر'),
          ]
        : const [],
  );
  if (screen == 'filtered') _buildFilteredRules(viewModel);
  viewModel.load();
  return BulkPriceEditorScreen(
    catalogRepository: repository,
    viewModel: viewModel,
  );
}

/// "Drinks or snacks, priced under 20: +10%, lift anything under cost+15%,
/// round up to 0.25" — a realistic chain to look at.
void _buildFilteredRules(BulkPriceEditorViewModel vm) {
  vm.setScopeAll(false);
  final first = vm.spec.filter.children.first.key;
  vm.updateCondition(
    first,
    (c) => c.copyWith(
      refs: const [
        BulkPriceRef(id: 10, label: 'مشروبات'),
        BulkPriceRef(id: 11, label: 'وجبات خفيفة'),
      ],
    ),
  );
  vm.addCondition(vm.spec.filter.key);
  final second = vm.spec.filter.children.last.key;
  vm.updateCondition(
    second,
    (c) => c
        .copyWith(field: BulkPriceField.price)
        .copyWith(operator: BulkPriceOperator.lt, value: '20'),
  );
  vm.addGroup(vm.spec.filter.key);
  final group = vm.spec.filter.children.last as BulkPriceGroup;
  vm.updateCondition(
    group.children.first.key,
    (c) => c
        .copyWith(field: BulkPriceField.stock)
        .copyWith(operator: BulkPriceOperator.gt, value: '0'),
  );
  vm.addCondition(group.key);
  final inner = (vm.spec.filter.children.last as BulkPriceGroup).children.last;
  vm.updateCondition(
    inner.key,
    (c) => c
        .copyWith(field: BulkPriceField.name)
        .copyWith(operator: BulkPriceOperator.contains, value: 'عرض'),
  );

  final step = vm.spec.steps.first.key;
  vm.updateStep(step, (s) => s.copyWith(value: '10'));
  vm.addStep(BulkPriceAction.minMarkup, value: '15');
  vm.setStepConditional(vm.spec.steps.last.key, true);
  final when = vm.spec.steps.last.when!;
  vm.updateCondition(
    when.children.first.key,
    (c) => c.copyWith(operator: BulkPriceOperator.lt, value: '5'),
  );
  vm.addStep(BulkPriceAction.round, value: '0.25');
  vm.updateStep(
    vm.spec.steps.last.key,
    (s) => s.copyWith(direction: BulkPriceDirection.up),
  );
  vm.setNeverBelowCost(true);
}

class _HistoryHost extends StatefulWidget {
  const _HistoryHost();

  @override
  State<_HistoryHost> createState() => _HistoryHostState();
}

class _HistoryHostState extends State<_HistoryHost> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      showBulkPriceHistorySheet(
        context,
        catalogRepository: _FakeCatalogRepository(),
      );
    });
  }

  @override
  Widget build(BuildContext context) => const Scaffold();
}

class _Board extends StatelessWidget {
  const _Board();

  @override
  Widget build(BuildContext context) {
    Widget frame(double width, double height, String screen) => SizedBox(
      width: width,
      height: height,
      child: MediaQuery(
        data: MediaQuery.of(context).copyWith(
          size: Size(width, height),
          padding: EdgeInsets.zero,
          viewInsets: EdgeInsets.zero,
        ),
        child: ClipRect(
          child: Navigator(
            onGenerateRoute: (_) =>
                MaterialPageRoute(builder: (_) => _editorFor(screen)),
          ),
        ),
      ),
    );
    return Scaffold(
      backgroundColor: const Color(0xFF444444),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Wrap(
          spacing: 16,
          runSpacing: 16,
          children: [frame(390, 860, 'filtered'), frame(1366, 860, 'filtered')],
        ),
      ),
    );
  }
}

class _Item {
  const _Item(
    this.id,
    this.name,
    this.price,
    this.cost,
    this.category, {
    this.stock = 10,
    this.variant = '',
    this.pack,
  });

  final int id;
  final String name;
  final double price;
  final double? cost;
  final int category;
  final double stock;
  final String variant;
  final double? pack;
}

const _items = [
  _Item(1, 'كوكاكولا 330مل', 2.5, 1.9, 10, pack: 55),
  _Item(2, 'بيبسي 330مل', 2.25, 1.8, 10, pack: 50),
  _Item(3, 'عصير المراعي برتقال', 4.75, 4.1, 10),
  _Item(4, 'عصير المراعي مانجو', 4.75, null, 10),
  _Item(5, 'مياه 1.5 لتر', 1.0, 0.6, 10, pack: 5.5),
  _Item(6, 'شيبس ليز عرض', 1.5, 1.35, 11),
  _Item(7, 'بسكويت أولكر', 0.75, 0.5, 11, stock: 0),
  _Item(8, 'شوكولاتة جالكسي', 3.5, 2.6, 11),
  _Item(9, 'قهوة نسكافيه 200غ', 18.0, 14.0, 12, variant: 'كلاسيك'),
  _Item(10, 'قهوة نسكافيه 200غ', 19.5, 14.5, 12, variant: 'جولد'),
  _Item(11, 'سكر 1 كغ', 3.25, 3.4, 12),
  _Item(12, 'أرز بسمتي 5 كغ', 32.0, 25.0, 12),
];

class _FakeCatalogRepository extends CatalogRepository {
  _FakeCatalogRepository() : super(PosApiService());

  @override
  Future<Result<BulkPriceOptions>> loadBulkPriceOptions() async =>
      const Ok(BulkPriceOptions(costVisible: true, maxSteps: 20));

  @override
  Future<Result<List<BulkPriceChangeRecord>>> loadBulkPriceChanges() async {
    final now = DateTime.now();
    return Ok([
      BulkPriceChangeRecord(
        id: 3,
        createdAt: now.subtract(const Duration(hours: 2)),
        createdByName: 'هاتم',
        changed: 128,
        increased: 120,
        decreased: 8,
        stepCount: 3,
      ),
      BulkPriceChangeRecord(
        id: 2,
        createdAt: now.subtract(const Duration(days: 3)),
        createdByName: 'سارة',
        changed: 42,
        increased: 0,
        decreased: 42,
        stepCount: 1,
        revertedAt: now.subtract(const Duration(days: 2)),
        revert: const BulkPriceRevertSummary(restored: 40, skipped: 2),
      ),
    ]);
  }

  @override
  Future<Result<BulkPricePreview>> previewBulkPriceChange({
    required BulkPriceSpec spec,
    BulkPricePreviewView view = BulkPricePreviewView.changed,
    int offset = 0,
    int limit = 50,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 250));
    final rows = <BulkPricePreviewRow>[];
    final stepCounts = List.filled(spec.steps.length, 0);
    for (final item in _items) {
      if (!_matches(spec.filter, item, item.price)) continue;
      var price = item.price;
      final applied = <int>[];
      final flags = <BulkPriceFlag>{};
      for (var i = 0; i < spec.steps.length; i++) {
        final step = spec.steps[i];
        if (step.when != null && !_matches(step.when!, item, price)) continue;
        final next = _apply(step, price, item.cost);
        if (next == null) {
          flags.add(BulkPriceFlag.noCost);
          continue;
        }
        price = next;
        applied.add(i);
        stepCounts[i]++;
        if (step.stop) break;
      }
      price = (math.max(0, price) * 100).round() / 100;
      if (item.cost != null && price < item.cost!) {
        if (spec.neverBelowCost) {
          price = item.cost!;
          flags.add(BulkPriceFlag.raisedToCost);
        } else {
          flags.add(BulkPriceFlag.belowCost);
        }
      }
      final delta = item.price == 0
          ? null
          : (price - item.price) / item.price * 100;
      if (delta != null && delta.abs() >= 50) {
        flags.add(BulkPriceFlag.bigChange);
      }
      final changed = (price - item.price).abs() > 0.001;
      rows.add(
        BulkPricePreviewRow(
          variantId: item.id,
          productId: item.id,
          productName: item.name,
          variantName: item.variant,
          sku: 'SKU-${item.id.toString().padLeft(4, '0')}',
          oldPrice: item.price,
          newPrice: price,
          deltaPercent: delta == null ? null : (delta * 10).round() / 10,
          appliedSteps: applied,
          flags: flags,
          packs: [
            if (changed &&
                item.pack != null &&
                spec.packMode == BulkPricePackMode.scale)
              BulkPricePackChange(
                label: 'كرتونة',
                oldPrice: item.pack!,
                newPrice: (item.pack! * price / item.price * 100).round() / 100,
              ),
          ],
          cost: item.cost,
          oldMarkup: item.cost == null
              ? null
              : (item.price - item.cost!) / item.cost! * 100,
          newMarkup: item.cost == null
              ? null
              : (price - item.cost!) / item.cost! * 100,
        ),
      );
    }
    final changed = rows
        .where((r) => r.priceChanged || r.packs.isNotEmpty)
        .toList();
    bool inView(BulkPricePreviewRow r) => switch (view) {
      BulkPricePreviewView.changed => r.priceChanged || r.packs.isNotEmpty,
      BulkPricePreviewView.increased => r.newPrice > r.oldPrice,
      BulkPricePreviewView.decreased => r.newPrice < r.oldPrice,
      BulkPricePreviewView.warnings => r.flags.any((f) => f.isWarning),
      BulkPricePreviewView.unchanged => !r.priceChanged && r.packs.isEmpty,
      BulkPricePreviewView.all => true,
    };
    final visible = rows.where(inView).toList();
    final percents = [
      for (final r in changed)
        if (r.deltaPercent != null) r.deltaPercent!,
    ];
    return Ok(
      BulkPricePreview(
        fingerprint: '${spec.toJson()}',
        costVisible: true,
        view: view,
        count: visible.length,
        rows: visible.skip(offset).take(limit).toList(),
        summary: BulkPriceSummary(
          matched: rows.length,
          changed: changed.length,
          unchanged: rows.length - changed.length,
          increased: changed.where((r) => r.newPrice > r.oldPrice).length,
          decreased: changed.where((r) => r.newPrice < r.oldPrice).length,
          productsChanged: changed.length,
          packsChanged: changed.fold(0, (sum, r) => sum + r.packs.length),
          averageChangePercent: percents.isEmpty
              ? null
              : percents.reduce((a, b) => a + b) / percents.length,
          warnings: rows.where((r) => r.flags.any((f) => f.isWarning)).length,
          flagCounts: const {},
          stepCounts: stepCounts,
        ),
      ),
    );
  }

  @override
  Future<Result<BulkPriceChangeRecord>> applyBulkPriceChange({
    required BulkPriceSpec spec,
    required String fingerprint,
  }) async => Ok(
    BulkPriceChangeRecord(
      id: 4,
      createdAt: DateTime.now(),
      createdByName: 'هاتم',
      changed: 6,
      increased: 6,
      decreased: 0,
      stepCount: spec.steps.length,
    ),
  );

  static bool _matches(BulkPriceGroup group, _Item item, double price) {
    if (group.isEmpty) return true;
    bool test(BulkPriceNode node) => switch (node) {
      BulkPriceGroup() => _matches(node, item, price),
      BulkPriceCondition() => _condition(node, item, price),
    };
    return group.match == BulkPriceMatch.all
        ? group.children.every(test)
        : group.children.any(test);
  }

  static bool _condition(BulkPriceCondition c, _Item item, double price) {
    double? number() => switch (c.field) {
      BulkPriceField.price => price,
      BulkPriceField.cost => item.cost,
      BulkPriceField.stock => item.stock,
      BulkPriceField.markup =>
        item.cost == null ? null : (price - item.cost!) / item.cost! * 100,
      _ => null,
    };
    switch (c.field.kind) {
      case BulkPriceFieldKind.refs:
        final held = c.field == BulkPriceField.category
            ? {item.category}
            : (c.field == BulkPriceField.product ? {item.id} : <int>{});
        final hit = c.refs.any((r) => held.contains(r.id));
        return switch (c.operator) {
          BulkPriceOperator.inList => hit,
          BulkPriceOperator.notInList => !hit,
          BulkPriceOperator.isEmpty => held.isEmpty,
          _ => held.isNotEmpty,
        };
      case BulkPriceFieldKind.text:
        final text = c.field == BulkPriceField.name
            ? item.name
            : 'SKU-${item.id}';
        return switch (c.operator) {
          BulkPriceOperator.contains => text.contains(c.value),
          BulkPriceOperator.notContains => !text.contains(c.value),
          BulkPriceOperator.equals => text == c.value,
          BulkPriceOperator.startsWith => text.startsWith(c.value),
          BulkPriceOperator.endsWith => text.endsWith(c.value),
          _ => true,
        };
      case BulkPriceFieldKind.flag:
        return c.operator == BulkPriceOperator.isTrue;
      case BulkPriceFieldKind.number:
        final value = number();
        if (c.operator == BulkPriceOperator.isEmpty) return value == null;
        if (c.operator == BulkPriceOperator.isNotEmpty) return value != null;
        if (value == null) return false;
        final target = double.parse(normalizeDigits(c.value));
        return switch (c.operator) {
          BulkPriceOperator.lt => value < target,
          BulkPriceOperator.lte => value <= target,
          BulkPriceOperator.gt => value > target,
          BulkPriceOperator.gte => value >= target,
          BulkPriceOperator.eq => value == target,
          BulkPriceOperator.neq => value != target,
          BulkPriceOperator.between =>
            value >= target &&
                value <= double.parse(normalizeDigits(c.valueTo)),
          _ => true,
        };
    }
  }

  static double? _apply(BulkPriceStep step, double price, double? cost) {
    final v = double.parse(normalizeDigits(step.value));
    if (step.action.needsCost && cost == null) return null;
    return switch (step.action) {
      BulkPriceAction.increasePercent => price * (100 + v) / 100,
      BulkPriceAction.decreasePercent => price * (100 - v) / 100,
      BulkPriceAction.increaseAmount => price + v,
      BulkPriceAction.decreaseAmount => price - v,
      BulkPriceAction.set => v,
      BulkPriceAction.costMarkup => cost! * (100 + v) / 100,
      BulkPriceAction.costPlus => cost! + v,
      BulkPriceAction.minMarkup => math.max(price, cost! * (100 + v) / 100),
      BulkPriceAction.minPrice => math.max(price, v),
      BulkPriceAction.maxPrice => math.min(price, v),
      BulkPriceAction.round => switch (step.direction) {
        BulkPriceDirection.up => (price / v).ceil() * v,
        BulkPriceDirection.down => (price / v).floor() * v,
        BulkPriceDirection.nearest => (price / v).round() * v,
      },
      BulkPriceAction.ending => price.floorToDouble() + v,
    };
  }
}
