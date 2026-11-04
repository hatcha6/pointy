// Dev-only preview harness for the reorder queue («إعادة الطلب»).
//
// Renders the real screen with a fake repository and no backend/auth. Run with
// `make frontend-reorder-preview`, then pick the surface with `?screen=`:
//
//   queue    | the ordinary queue, no supplier chosen
//   selected | a supplier chosen and rows ticked, the order button live
//   empty    | nothing to reorder
//   board    | the queue in phone and desktop frames side by side
//
// Add `&dark=1` for the dark theme. See AGENTS.md ("UI preview harness").
// Not part of the shipping app. Safe to delete.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/models/purchase_submission.dart';
import 'package:pointy_frontend/src/data/models/reorder_queue.dart';
import 'package:pointy_frontend/src/data/repositories/contact_repository.dart';
import 'package:pointy_frontend/src/data/repositories/reorder_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/purchasing/view_models/reorder_view_model.dart';
import 'package:pointy_frontend/src/features/purchasing/views/reorder_screen.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/navigation/app_navigation.dart';
import 'package:pointy_frontend/src/shared/shell/shell.dart';

void main() => runApp(const _PreviewApp());

const _rows = [
  ReorderRow(
    variantId: 1,
    productId: 1,
    productName: 'حليب المراعي كامل الدسم ١ لتر',
    sku: 'MLK-1L',
    status: ReorderStatus.out,
    onHand: 0,
    threshold: 12,
    expected: 24,
    orderQuantity: 18,
    lastSupplierName: 'شركة النور للتوريدات',
  ),
  ReorderRow(
    variantId: 2,
    productId: 2,
    productName: 'قميص قطني',
    variantName: 'أزرق / كبير',
    sku: 'SHRT-BL-L',
    status: ReorderStatus.low,
    onHand: 2,
    threshold: 5,
    orderQuantity: 8,
    inDraft: 6,
    lastSupplierName: 'مصنع الأمل',
  ),
  ReorderRow(
    variantId: 3,
    productId: 2,
    productName: 'قميص قطني',
    variantName: 'أسود / وسط',
    sku: 'SHRT-BK-M',
    status: ReorderStatus.low,
    onHand: 5,
    threshold: 5,
    orderQuantity: 5,
    lastSupplierName: 'مصنع الأمل',
  ),
  ReorderRow(
    variantId: 4,
    productId: 3,
    productName: 'شاحن سريع ٢٠ واط',
    sku: 'CHG-20W',
    status: ReorderStatus.approaching,
    onHand: 38,
    threshold: 10,
    daysLeft: 4,
    orderQuantity: 22,
    lastSupplierName: 'شركة النور للتوريدات',
  ),
  ReorderRow(
    variantId: 5,
    productId: 4,
    productName: 'زيت زيتون بكر ممتاز، عبوة زجاجية كبيرة خمسة لترات للمطاعم',
    status: ReorderStatus.approaching,
    onHand: 6,
    threshold: 5,
    orderQuantity: 4,
  ),
];

class _FakeReorderRepository extends ReorderRepository {
  _FakeReorderRepository(this._rows) : super(PosApiService());

  final List<ReorderRow> _rows;

  @override
  Future<Result<ReorderQueue>> loadQueue({
    int? supplierId,
    required bool includeApproaching,
  }) async {
    final rows = _rows
        .where(
          (row) =>
              includeApproaching || row.status != ReorderStatus.approaching,
        )
        .toList(growable: false);
    return Ok(ReorderQueue(rows: rows, totalCount: rows.length));
  }

  @override
  Future<Result<PurchaseOrder>> createOrder({
    required int supplierId,
    required List<ReorderOrderLine> lines,
    String? idempotencyKey,
  }) async {
    return Error(Exception('preview'));
  }
}

class _MemoryPreference extends ReorderApproachingPreference {
  const _MemoryPreference();

  @override
  Future<bool> read() async => true;

  @override
  Future<void> write(bool value) async {}
}

class _FakeNavigation implements AppNavigation {
  @override
  final PosUser currentUser = const PosUser(
    id: 1,
    username: 'owner',
    role: UserRole.manager,
    isActive: true,
  );

  @override
  AuthorizationCapabilities get capabilities =>
      AuthorizationCapabilities.forUser(currentUser);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

ReorderViewModel _viewModel(List<ReorderRow> rows) {
  return ReorderViewModel(
    _FakeReorderRepository(rows),
    preference: const _MemoryPreference(),
  );
}

Widget _screen(ReorderViewModel viewModel) {
  return ReorderScreen(
    viewModel: viewModel,
    contactRepository: ContactRepository(PosApiService()),
    navigation: _FakeNavigation(),
    onOpenPurchaseOrder: (_, _) {},
  );
}

class _SelectedQueue extends StatefulWidget {
  const _SelectedQueue();

  @override
  State<_SelectedQueue> createState() => _SelectedQueueState();
}

class _SelectedQueueState extends State<_SelectedQueue> {
  final _vm = _viewModel(_rows);

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  Future<void> _prepare() async {
    await _vm.setSupplier(id: 7, name: 'شركة النور للتوريدات');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    _vm
      ..toggle(_rows[0])
      ..toggle(_rows[3])
      ..setQuantity(_rows[3], 30);
  }

  @override
  Widget build(BuildContext context) => _screen(_vm);
}

Widget _frame(BuildContext context, double width, double height, Widget child) {
  return SizedBox(
    width: width,
    height: height,
    child: MediaQuery(
      data: MediaQuery.of(context).copyWith(
        size: Size(width, height),
        padding: EdgeInsets.zero,
        viewInsets: EdgeInsets.zero,
      ),
      child: child,
    ),
  );
}

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
      home: Builder(
        builder: (context) => switch (Uri.base.queryParameters['screen']) {
          'selected' => const _SelectedQueue(),
          'empty' => _screen(_viewModel(const [])),
          'board' => Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _frame(context, 390, 800, _screen(_viewModel(_rows))),
              const SizedBox(width: 24),
              Expanded(child: _screen(_viewModel(_rows))),
            ],
          ),
          _ => _screen(_viewModel(_rows)),
        },
      ),
    );
  }
}
