import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/cart_line.dart';
import 'package:pointy_frontend/src/data/models/voucher_account.dart';
import 'package:pointy_frontend/src/data/models/voucher_menu.dart';
import 'package:pointy_frontend/src/features/pos/view_models/pos_card_requests_controller.dart';
import 'package:pointy_frontend/src/features/pos/views/card_requests/pos_card_requests_dock.dart';
import 'package:pointy_frontend/src/data/models/card_request.dart';
import 'package:pointy_frontend/src/features/pos/views/pos_voucher_account_sheet.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

const _target = VoucherTarget(
  kind: VoucherTargetKind.gameAccount,
  check: 'pubg_mobile',
  fields: [VoucherTargetField(key: 'player_id', label: 'معرّف اللاعب')],
);

VoucherBrand _brand() => VoucherBrand.fromJson({
  'key': 'pubg',
  'name': 'ببجي',
  'target': {
    'kind': 'game_account',
    'check': 'pubg_mobile',
    'fields': [
      {'key': 'player_id', 'label': 'معرّف اللاعب'},
    ],
  },
  'product': {
    'id': 5,
    'name': 'ببجي',
    'is_system': true,
    'system_kind': 'voucher',
    'quantity_on_hand': 0,
  },
  'items': [
    {
      'variant_id': 9,
      'key': 'pubg-60',
      'label': '60 UC',
      'name': '60 UC',
      'price': '11.00',
      'available': true,
      'sku': 'DFT-PUBG60',
    },
  ],
});

Widget _app(Widget child) => MaterialApp(
  locale: const Locale('ar'),
  supportedLocales: AppLocalizations.supportedLocales,
  localizationsDelegates: const [
    AppLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  theme: PointyTheme.light(),
  home: Scaffold(body: child),
);

const _saved = SavedVoucherAccount(
  id: 1,
  ref: '5123456789',
  values: {'player_id': '5123456789'},
  playerName: 'Sniper',
  label: 'أحمد الجار',
  useCount: 3,
);

void main() {
  group('target reading', () {
    test('tidies what was typed the way the server will', () {
      final id = _target.fields.single;
      expect(_target.clean(id, ' ٥١٢٣ ٤٥ '), '512345');
      const telegram = VoucherTarget(
        kind: VoucherTargetKind.telegram,
        fields: [VoucherTargetField(key: 'username', label: 'x')],
      );
      final field = telegram.fields.single;
      expect(telegram.clean(field, 'https://t.me/ahmed_ly'), 'ahmed_ly');
      expect(telegram.clean(field, '@ahmed_ly'), 'ahmed_ly');
      expect(telegram.line({'username': 'ahmed_ly'}), '@ahmed_ly');
      expect(
        telegram.problemWith(field, 'ab'),
        VoucherAccountProblem.notTelegram,
      );
      expect(telegram.checkable, isFalse);
      expect(_target.checkable, isTrue);
    });

    test('a Steam invite is never remembered', () {
      const gift = VoucherTarget(
        kind: VoucherTargetKind.steamInvite,
        fields: [VoucherTargetField(key: 'invite_url', label: 'x')],
      );
      final field = gift.fields.single;
      expect(gift.remembers, isFalse);
      expect(
        gift.clean(field, 'add me https://s.team/p/GKCP-MVN/CWQ thanks'),
        'https://s.team/p/gkcp-mvn/CWQ',
      );
    });

    test(
      'a brand of an unknown kind can never be sold without its account',
      () {
        final brand = VoucherBrand.fromJson({
          'key': 'x',
          'name': 'x',
          'target': {
            'kind': 'smart_meter',
            'fields': [
              {'key': 'a', 'label': 'b'},
            ],
          },
          'product': {
            'id': 5,
            'name': 'x',
            'is_system': true,
            'system_kind': 'voucher',
            'quantity_on_hand': 0,
          },
          'items': [
            {
              'variant_id': 9,
              'key': 'k',
              'price': '1',
              'available': true,
              'sku': 's',
            },
          ],
        });
        expect(brand.sentToAccount, isTrue);
        expect(brand.target, isNull);
        expect(brand.isAvailable, isFalse);
      },
    );
  });

  test('a held invoice keeps whose account the line is for', () {
    const line = CartLineIntegration(
      provider: 'pointy',
      subscriberRef: '5123',
      optionCode: 'pubg-60',
      optionLabel: '60 UC',
      accountTarget: {'player_id': '5123'},
      accountName: 'Sniper',
    );
    final held = CartLineIntegration.fromJson(line.toStorageJson());
    expect(held.accountTarget, {'player_id': '5123'});
    expect(held.accountName, 'Sniper');
    expect(held.isSentToAccount, isTrue);
    expect(line.toJson()['account_target'], {'player_id': '5123'});
  });

  testWidgets('a slim menu still sells: the card carries its own line', (
    tester,
  ) async {
    final brand = _brand();
    final variant = brand.variantFor(brand.items.single)!;
    expect(variant.id, 9);
    expect(variant.sku, 'DFT-PUBG60');
    expect(variant.productDetail!.isVoucher, isTrue);
    expect(brand.canSell(brand.items.single), isTrue);
  });

  group('account picker', () {
    late List<String> searches;
    late VoucherAccountStatus status;
    VoucherAccountPick? picked;

    Future<void> pump(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1100, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      searches = [];
      status = VoucherAccountStatus.valid;
      picked = null;
      await tester.pumpWidget(
        _app(
          PosVoucherAccountPicker(
            brand: _brand(),
            target: _target,
            onPicked: (pick) => picked = pick,
            loadSaved: ({required brand, search = '', customer}) async {
              searches.add(search);
              return Ok(
                SavedVoucherAccountPage(
                  accounts: search.isEmpty || '5123456789'.contains(search)
                      ? const [_saved]
                      : const [],
                ),
              );
            },
            check: ({required variantId, required values}) async =>
                Ok(VoucherAccountCheck(status: status, name: 'Sniper')),
          ),
        ),
      );
      await tester.pump();
    }

    Finder field() =>
        find.byKey(const ValueKey('voucher_account_field_player_id'));
    Finder tile() => find.byKey(const ValueKey('voucher_item_pubg-60'));

    testWidgets('an amount with no account asks for it and sells nothing', (
      tester,
    ) async {
      await pump(tester);
      await tester.tap(tile());
      await tester.pump();
      expect(picked, isNull);
      expect(find.text('أدخل معرّف اللاعب.'), findsOneWidget);
    });

    testWidgets('a saved account is one tap, and carries its look-up', (
      tester,
    ) async {
      await pump(tester);
      expect(find.text('أحمد الجار'), findsOneWidget);
      await tester.tap(find.text('أحمد الجار'));
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('Sniper'), findsWidgets);
      await tester.tap(tile());
      await tester.pump();
      expect(picked!.account, {'player_id': '5123456789'});
      expect(picked!.subscriberRef, '5123456789');
      expect(picked!.accountName, 'Sniper');
    });

    testWidgets('typing searches the book, a new ID sells all the same', (
      tester,
    ) async {
      await pump(tester);
      await tester.enterText(field(), '77');
      await tester.pump(const Duration(milliseconds: 300));
      expect(searches.last, '77');
      expect(find.text('أحمد الجار'), findsNothing);
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(tile());
      await tester.pump();
      expect(picked!.account, {'player_id': '77'});
    });

    testWidgets('an account the game does not know cannot be sold', (
      tester,
    ) async {
      await pump(tester);
      status = VoucherAccountStatus.invalid;
      await tester.enterText(field(), '404');
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      await tester.tap(tile());
      await tester.pump();
      expect(picked, isNull);
      expect(find.textContaining('لا يوجد حساب'), findsOneWidget);
    });

    testWidgets('never overflows on a phone', (tester) async {
      await pump(tester);
      tester.view.physicalSize = const Size(360, 700);
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });

  group('the dock', () {
    PosCardRequestsController controllerWith(List<CardRequest> rows) {
      return PosCardRequestsController(load: () async => Ok(rows));
    }

    testWidgets('is not there on a quiet till', (tester) async {
      final controller = controllerWith(const []);
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        _app(
          PosCardRequestsDock(controller: controller, child: const SizedBox()),
        ),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('card_requests_pill')), findsNothing);
    });

    testWidgets('the panel leaves what is behind it usable', (tester) async {
      tester.view.physicalSize = const Size(1000, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final controller = controllerWith([
        CardRequest(
          orderLine: 1,
          orderId: 1,
          state: CardRequestState.working,
          label: 'ببجي 60',
          account: '5123',
          createdAt: DateTime.now(),
        ),
        const CardRequest(
          orderLine: 2,
          orderId: 2,
          state: CardRequestState.failed,
          label: 'ببجي 325',
          errorCode: 'out_of_stock',
          refundAmount: 52,
        ),
        const CardRequest(
          orderLine: 3,
          orderId: 3,
          state: CardRequestState.succeeded,
          label: 'أمازون',
          receipt: {'code': 'AQ7K'},
        ),
      ]);
      addTearDown(controller.dispose);
      var tapped = 0;
      await tester.pumpWidget(
        _app(
          PosCardRequestsDock(
            controller: controller,
            child: Align(
              alignment: AlignmentDirectional.topEnd,
              child: TextButton(
                onPressed: () => tapped++,
                child: const Text('خلف'),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('card_requests_pill')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('card_requests_pill')));
      await tester.pump();
      expect(find.byKey(const ValueKey('card_requests_panel')), findsOneWidget);
      expect(find.text('AQ7K'), findsOneWidget);
      expect(find.textContaining('أعد للزبون'), findsOneWidget);
      await tester.tap(find.text('خلف'));
      expect(tapped, 1);
      controller.setPanelOpen(false);
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
    });
  });
}
