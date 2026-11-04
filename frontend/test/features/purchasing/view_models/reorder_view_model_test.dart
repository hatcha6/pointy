import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/purchase_submission.dart';
import 'package:pointy_frontend/src/data/models/reorder_queue.dart';
import 'package:pointy_frontend/src/data/repositories/reorder_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/purchasing/view_models/reorder_view_model.dart';

const _low = ReorderRow(
  variantId: 1,
  productId: 1,
  productName: 'حليب',
  sku: 'MLK',
  status: ReorderStatus.low,
  onHand: 2,
  threshold: 5,
  orderQuantity: 8,
);
const _soon = ReorderRow(
  variantId: 2,
  productId: 2,
  productName: 'قميص',
  variantName: 'أزرق',
  status: ReorderStatus.approaching,
  onHand: 6,
  threshold: 5,
  orderQuantity: 4,
);

class _Repository extends ReorderRepository {
  _Repository() : super(PosApiService());

  List<ReorderRow> rows = const [_low, _soon];
  final queries = <({int? supplierId, bool approaching})>[];
  List<ReorderOrderLine>? sentLines;
  int? sentSupplier;
  final sentKeys = <String?>[];
  Result<PurchaseOrder>? orderResult;

  @override
  Future<Result<ReorderQueue>> loadQueue({
    int? supplierId,
    required bool includeApproaching,
  }) async {
    queries.add((supplierId: supplierId, approaching: includeApproaching));
    return Ok(ReorderQueue(rows: rows, totalCount: rows.length));
  }

  @override
  Future<Result<PurchaseOrder>> createOrder({
    required int supplierId,
    required List<ReorderOrderLine> lines,
    String? idempotencyKey,
  }) async {
    sentSupplier = supplierId;
    sentLines = lines;
    sentKeys.add(idempotencyKey);
    return orderResult ?? Error(Exception('no order'));
  }
}

class _Preference extends ReorderApproachingPreference {
  _Preference(this.stored);

  bool stored;
  final written = <bool>[];

  @override
  Future<bool> read() async => stored;

  @override
  Future<void> write(bool value) async => written.add(value);
}

Future<ReorderViewModel> _loaded(
  _Repository repository, {
  _Preference? preference,
}) async {
  final viewModel = ReorderViewModel(
    repository,
    preference: preference ?? _Preference(true),
  );
  await pumpEventQueue();
  return viewModel;
}

void main() {
  test('a row reads the server\'s quantities, which arrive as strings', () {
    final row = ReorderRow.fromJson(const {
      'variant': 3,
      'product': 2,
      'product_name': 'حليب',
      'variant_name': '',
      'sku': 'MLK',
      'status': 'low',
      'on_hand': '2.500',
      'threshold': '5.000',
      'expected': '0',
      'in_draft': '6.000',
      'days_left': null,
      'order_quantity': '8',
      'last_supplier_name': 'مورد',
    });

    expect(row.status, ReorderStatus.low);
    expect(row.onHand, 2.5);
    expect(row.inDraft, 6);
    expect(row.orderQuantity, 8);
    expect(row.daysLeft, isNull);
  });

  test(
    'asks with the remembered approaching choice from the first load',
    () async {
      final repository = _Repository();
      final viewModel = await _loaded(
        repository,
        preference: _Preference(false),
      );
      addTearDown(viewModel.dispose);

      expect(repository.queries, [(supplierId: null, approaching: false)]);
    },
  );

  test('switching approaching off reloads and is remembered', () async {
    final repository = _Repository();
    final preference = _Preference(true);
    final viewModel = await _loaded(repository, preference: preference);
    addTearDown(viewModel.dispose);

    await viewModel.setIncludeApproaching(false);

    expect(repository.queries.last.approaching, isFalse);
    expect(preference.written, [false]);
  });

  test('no order without a supplier, however much is ticked', () async {
    final repository = _Repository();
    final viewModel = await _loaded(repository);
    addTearDown(viewModel.dispose);

    viewModel.toggle(_low);

    expect(viewModel.canCreateOrder, isFalse);
    expect(await viewModel.createOrder(), isNull);
    expect(repository.sentLines, isNull);
  });

  test('no order with a supplier and nothing ticked', () async {
    final viewModel = await _loaded(_Repository());
    addTearDown(viewModel.dispose);

    await viewModel.setSupplier(id: 7, name: 'مورد');

    expect(viewModel.canCreateOrder, isFalse);
  });

  test(
    'sends the ticked rows, suggested or typed, to the chosen supplier',
    () async {
      final repository = _Repository();
      final viewModel = await _loaded(repository);
      addTearDown(viewModel.dispose);
      await viewModel.setSupplier(id: 7, name: 'مورد');

      viewModel
        ..toggle(_low)
        ..setQuantity(_soon, 11);
      await viewModel.createOrder();

      expect(repository.sentSupplier, 7);
      expect(
        {
          for (final line in repository.sentLines!)
            line.variantId: line.quantity,
        },
        {1: 8.0, 2: 11.0},
      );
    },
  );

  test('a quantity that is not above zero is ignored', () async {
    final viewModel = await _loaded(_Repository());
    addTearDown(viewModel.dispose);

    viewModel.setQuantity(_low, 0);

    expect(viewModel.quantityOf(_low), 8);
    expect(viewModel.isSelected(_low), isFalse);
  });

  test('a retried order reuses its key; a changed one does not', () async {
    final repository = _Repository();
    final viewModel = await _loaded(repository);
    addTearDown(viewModel.dispose);
    await viewModel.setSupplier(id: 7, name: 'مورد');
    viewModel.toggle(_low);

    await viewModel.createOrder();
    await viewModel.createOrder();
    viewModel.setQuantity(_low, 20);
    await viewModel.createOrder();

    expect(repository.sentKeys[0], isNotNull);
    expect(repository.sentKeys[1], repository.sentKeys[0]);
    expect(repository.sentKeys[2], isNot(repository.sentKeys[0]));
  });

  test('a ticked row that left the queue does not ride along', () async {
    final repository = _Repository();
    final viewModel = await _loaded(repository);
    addTearDown(viewModel.dispose);
    viewModel
      ..toggle(_low)
      ..toggle(_soon);

    repository.rows = const [_low];
    await viewModel.load();

    expect(viewModel.selectedCount, 1);
    expect(viewModel.isSelected(_low), isTrue);
  });

  test('the search narrows on the screen without asking again', () async {
    final repository = _Repository();
    final viewModel = await _loaded(repository);
    addTearDown(viewModel.dispose);

    viewModel.setSearch('أزرق');

    expect(viewModel.visibleRows, [_soon]);
    expect(repository.queries, hasLength(1));
  });

  test('select all covers what the search shows, not what it hides', () async {
    final viewModel = await _loaded(_Repository());
    addTearDown(viewModel.dispose);

    viewModel
      ..setSearch('MLK')
      ..toggleAllVisible();

    expect(viewModel.isSelected(_low), isTrue);
    expect(viewModel.isSelected(_soon), isFalse);
    expect(viewModel.allVisibleSelected, isTrue);
  });
}
