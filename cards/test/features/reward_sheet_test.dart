import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_cards/dev/cards_fixtures.dart';
import 'package:pointy_cards/l10n/generated/app_localizations.dart';
import 'package:pointy_cards/src/data/models/campaign.dart';
import 'package:pointy_cards/src/features/attribution/reward_sheet.dart';

void main() {
  test('the reward says why, in the words of how the customer came', () async {
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    String why({required String kind, String via = 'link', String name = ''}) =>
        RewardSheet.because(
          l10n,
          CampaignReward.fromJson(
            fixtureReward(kind: kind, via: via, name: name),
          ),
        );

    expect(
      why(kind: 'flyer', name: 'ملصق جامعة مصراتة'),
      'لأنك مسحت رمز ملصق جامعة مصراتة.',
    );
    expect(why(kind: 'flyer'), 'لأنك مسحت رمز الملصق.');
    expect(why(kind: 'billboard'), 'لأنك مسحت رمز اللوحة الإعلانية.');
    // Typed off the poster rather than scanned: the code itself.
    expect(why(kind: 'billboard', via: 'code'), 'لأنك استخدمت الرمز UNI1.');
    expect(
      why(kind: 'creator', via: 'code', name: 'أحمد'),
      'لأنك جئت عن طريق أحمد.',
    );
    expect(why(kind: 'creator'), 'لأنك جئت عن طريق صانع محتوى نتعاون معه.');
    expect(why(kind: 'referral', name: 'سالم'), 'لأنك جئت بدعوة من سالم.');
    expect(why(kind: 'ad', via: 'referrer'), 'لأنك جئت من إعلاننا.');
    expect(why(kind: 'ad', via: 'code'), 'لأنك استخدمت الرمز UNI1.');
    expect(why(kind: 'other', via: 'link'), 'لأنك استخدمت الرمز UNI1.');
  });
}
