import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/models/dashboard.dart';

void main() {
  Map<String, Object?> snapshotJson(Object? todaySpecialDays) => {
    'generated_at': '2026-12-24T08:00:00Z',
    'period': {'days': 30},
    'sections': <String, Object?>{},
    if (todaySpecialDays != null) 'today_special_days': todaySpecialDays,
  };

  test('parses today_special_days into localized special days', () {
    final snapshot = DashboardSnapshot.fromJson(
      snapshotJson([
        {
          'key': 'independence_day',
          'name_en': 'Libyan Independence Day',
          'name_ar': 'عيد الاستقلال',
          'category': 'national',
        },
        {
          'key': 'christmas_eve',
          'name_en': 'Christmas Eve',
          'name_ar': 'ليلة عيد الميلاد',
          'category': 'religious',
        },
      ]),
    );

    expect(snapshot.todaySpecialDays, hasLength(2));
    final first = snapshot.todaySpecialDays.first;
    expect(first.key, 'independence_day');
    expect(first.localizedName('ar'), 'عيد الاستقلال');
    expect(first.localizedName('en'), 'Libyan Independence Day');
  });

  test('localizedName falls back to the other language when one is blank', () {
    const onlyArabic = DashboardSpecialDay(
      key: 'eid',
      nameEn: '',
      nameAr: 'عيد',
      category: 'religious',
    );
    expect(onlyArabic.localizedName('en'), 'عيد');
    expect(onlyArabic.localizedName('ar'), 'عيد');
  });

  test('missing today_special_days yields an empty list', () {
    final snapshot = DashboardSnapshot.fromJson(snapshotJson(null));
    expect(snapshot.todaySpecialDays, isEmpty);
  });

  test('ignores malformed entries instead of throwing', () {
    final snapshot = DashboardSnapshot.fromJson(
      snapshotJson([
        'not-a-map',
        {'key': 'new_year', 'name_en': 'New Year', 'name_ar': 'رأس السنة'},
      ]),
    );
    expect(snapshot.todaySpecialDays, hasLength(1));
    expect(snapshot.todaySpecialDays.single.key, 'new_year');
  });
}
