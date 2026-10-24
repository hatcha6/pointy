import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_cards/src/core/arabic_search.dart';
import 'package:pointy_cards/src/core/phone.dart';
import 'package:pointy_cards/src/core/redeem.dart';

void main() {
  test('search folds how Arabic is typed', () {
    expect(matchesSearch('ليبيانا', ['ليبيانا']), isTrue);
    expect(matchesSearch('اتصالات', ['إتصالات']), isTrue);
    expect(matchesSearch('باقه', ['باقة شهر']), isTrue);
    expect(matchesSearch('LIBYANA', ['Libyana']), isTrue);
    expect(matchesSearch('ببجي ٦٠', ['ببجي', '60 شدة']), isTrue);
    expect(matchesSearch('نتفليكس', ['ليبيانا']), isFalse);
    expect(matchesSearch('  ', ['anything']), isTrue);
  });

  test('Libyan mobiles in every spelling', () {
    for (final raw in [
      '0912345678',
      '912345678',
      '+218 91 234 5678',
      '00218912345678',
      '٠٩١٢٣٤٥٦٧٨',
      '091-234-5678',
    ]) {
      expect(LibyanPhone.national(raw), '912345678', reason: raw);
    }
    expect(LibyanPhone.national('0212345678'), isNull);
    expect(LibyanPhone.national('09123'), isNull);
    expect(LibyanPhone.display('912345678'), '091 234 5678');
  });

  test('the dial string comes only from a hint that spells it out', () {
    expect(
      rechargeDialString('اطلب *112* ثم الرقم السري ثم #', '1234 5678'),
      '*112*12345678#',
    );
    expect(
      rechargeDialString('اتصل بالرقم 120 متبوعاً بالرقم السري', '1234'),
      isNull,
    );
    expect(rechargeDialString('', '1234'), isNull);
  });
}
