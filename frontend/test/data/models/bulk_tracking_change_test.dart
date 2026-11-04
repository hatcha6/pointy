import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/models/bulk_tracking_change.dart';
import 'package:pointy_frontend/src/data/models/product_variant.dart';

void main() {
  test('a preview parses its summary, rows, outcomes and warnings', () {
    final preview = BulkTrackingPreview.fromJson({
      'summary': {
        'matched': 3,
        'change': 1,
        'same': 1,
        'blocked': 1,
        'empty_shelf': 1,
        'undated_stock': 2,
      },
      'results': [
        {
          'product': 5,
          'name': 'حليب',
          'variants': 2,
          'on_hand': '12.000',
          'current_mode': 'quantity',
          'expiry_required': false,
          'outcome': 'change',
          'message': '',
          'warnings': ['empty_shelf', 'undated_stock', 'something_new'],
        },
        {
          'product': 6,
          'name': 'هاتف',
          'variants': 1,
          'on_hand': '3.000',
          'current_mode': 'serial',
          'outcome': 'blocked',
          'message': 'لا يمكن',
          'warnings': <String>[],
        },
        {'product': 7, 'name': 'لبن', 'outcome': 'same'},
      ],
    });

    expect(preview.summary.matched, 3);
    expect(preview.summary.emptyShelf, 1);
    expect(preview.summary.undatedStock, 2);
    final first = preview.rows.first;
    expect(first.onHand, 12);
    expect(first.variants, 2);
    expect(first.warnings, {
      BulkTrackingWarning.emptyShelf,
      BulkTrackingWarning.undatedStock,
    });
    expect(preview.rows[1].outcome, BulkTrackingOutcome.blocked);
    expect(preview.rows[1].message, 'لا يمكن');
    expect(preview.rows[2].outcome, BulkTrackingOutcome.same);
  });

  test('an apply result parses and adds up', () {
    final a = BulkTrackingApplyResult.fromJson({
      'done': 98,
      'blocked': 1,
      'failures': [
        {'product': 4, 'message': 'تعذّر'},
      ],
    });
    final total = a.plus(const BulkTrackingApplyResult(done: 100));
    expect(total.done, 198);
    expect(total.blocked, 1);
    expect(total.failures.single.product, 4);
  });

  test('the request body carries only what the mode needs', () {
    const keepReminder = BulkTrackingAction(
      tracking: BulkTrackingTarget.expiry,
    );
    expect(keepReminder.toJson(filter: const {}), {
      'filter': <String, Object?>{},
      'tracking': 'expiry',
      'reminder_mode': 'keep',
    });

    final set = BulkTrackingAction(
      reminderMode: BulkReminderMode.set,
      reminderDate: DateTime(2027, 3, 5),
    );
    expect(
      set.toJson(filter: const {}, productIds: const [1, 2]),
      containsPair('reminder_date', '2027-03-05'),
    );
    expect(
      set.toJson(filter: const {}, productIds: const [1, 2])['product_ids'],
      [1, 2],
    );

    const clear = BulkTrackingAction(reminderMode: BulkReminderMode.clear);
    expect(
      clear.toJson(filter: const {}).containsKey('reminder_date'),
      isFalse,
    );
    expect(const BulkTrackingAction().isNoop, isTrue);
  });

  test('a variant reads its expiry reminder date, null when absent', () {
    final base = {'id': 1, 'product': 1, 'sku': 'A', 'unit_price': '1.00'};
    expect(
      ProductVariant.fromJson({
        ...base,
        'expiry_reminder_date': '2027-08-31',
      }).expiryReminderDate,
      DateTime(2027, 8, 31),
    );
    expect(ProductVariant.fromJson(base).expiryReminderDate, isNull);
    expect(
      ProductVariant.fromJson({
        ...base,
        'expiry_reminder_date': null,
      }).expiryReminderDate,
      isNull,
    );
  });
}
