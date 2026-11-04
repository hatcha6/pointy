import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_cards/src/core/redeem.dart';
import 'package:pointy_cards/src/data/models/catalog.dart';

void main() {
  CardRedeem read(Map<String, dynamic> json) => CardRedeem.fromJson(json)!;

  final libyana = read({'kind': 'dial', 'template': '120{code}'});
  final almadar = read({'kind': 'dial', 'template': '*112*{code}#'});
  final apple = read({
    'kind': 'link',
    'template': 'https://apps.apple.com/redeem?code={code}',
    'pattern': 'X[A-Z0-9]{15}',
  });
  final steam = read({
    'kind': 'link',
    'template': 'https://store.steampowered.com/account/registerkey?key={code}',
  });
  final amazon = read({
    'kind': 'link',
    'template': 'https://www.amazon.com/gc/redeem?claimCode={code}',
    'by_country': {'AE': 'https://www.amazon.ae/gc/redeem?claimCode={code}'},
  });

  test('a dial puts the joined-up code into the operator\'s string', () {
    final call = redeemStep(libyana, code: '4827 1930 5561 2')!;
    expect(call.kind, RedeemKind.call);
    expect(call.value, '1204827193055612');

    final ussd = redeemStep(almadar, code: '1234567890123')!;
    expect(ussd.kind, RedeemKind.call);
    expect(ussd.value, '*112*1234567890123#');
  });

  test('a dial takes digits only: no button for a code it cannot dial', () {
    expect(redeemStep(libyana, code: 'ABC-123'), isNull);
    expect(redeemStep(libyana, code: '٤٨٢٧'), isNull);
    expect(redeemStep(libyana, code: '  '), isNull);
  });

  test('Apple\'s code goes in joined up and in capitals, or not at all', () {
    expect(
      redeemStep(apple, code: 'xabc defg-hjkl mnpq')!.value,
      'https://apps.apple.com/redeem?code=XABCDEFGHJKLMNPQ',
    );
    expect(redeemStep(apple, code: '1234-5678'), isNull);
  });

  test('a code without a pattern keeps its dashes, made safe for a link', () {
    expect(
      redeemStep(steam, code: 'AAAAA-BBBBB-CCCCC')!.value,
      'https://store.steampowered.com/account/registerkey?key=AAAAA-BBBBB-CCCCC',
    );
    expect(
      redeemStep(steam, code: 'A&B=C')!.value,
      'https://store.steampowered.com/account/registerkey?key=A%26B%3DC',
    );
  });

  test('a card goes to its own country\'s site', () {
    expect(
      redeemStep(amazon, code: 'ABCD', country: 'AE')!.value,
      'https://www.amazon.ae/gc/redeem?claimCode=ABCD',
    );
    expect(
      redeemStep(amazon, code: 'ABCD', country: 'US')!.value,
      'https://www.amazon.com/gc/redeem?claimCode=ABCD',
    );
  });

  test('what this build cannot use costs a button, not the shelf', () {
    expect(CardRedeem.fromJson(null), isNull);
    expect(CardRedeem.fromJson('nonsense'), isNull);
    expect(CardRedeem.fromJson(<String, dynamic>{'kind': 'dial'}), isNull);
    expect(
      CardRedeem.fromJson(<String, dynamic>{
        'kind': 'link',
        'template': 'https://a.example/',
        'pattern': '(',
      }),
      isNull,
    );
    expect(
      redeemStep(read({'kind': 'sms', 'template': '{code}'}), code: '123'),
      isNull,
    );
  });
}
