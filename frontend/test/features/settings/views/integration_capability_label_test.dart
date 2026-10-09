import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations_ar.dart';
import 'package:pointy_frontend/src/data/models/integration_provider.dart';
import 'package:pointy_frontend/src/features/settings/views/integration_presentation.dart';

/// The chips under a provider's name on the integrations card. A capability
/// the app has no word for would print its raw code — English — on an Arabic
/// screen, so each one the backend can list has an Arabic label.
void main() {
  final l10n = AppLocalizationsAr();

  test('the direct services are named in Arabic', () {
    expect(
      integrationCapabilityLabel(IntegrationCapability.airtime, l10n),
      'الشحن المباشر',
    );
    expect(
      integrationCapabilityLabel(IntegrationCapability.bills, l10n),
      'دفع الفواتير',
    );
  });

  test('the backend\'s wire codes are the ones the labels switch on', () {
    expect(IntegrationCapability.airtime, 'airtime');
    expect(IntegrationCapability.bills, 'bills');
  });

  test('every earlier capability keeps its label', () {
    expect(
      integrationCapabilityLabel(IntegrationCapability.balance, l10n),
      'الرصيد',
    );
    expect(
      integrationCapabilityLabel(IntegrationCapability.lookup, l10n),
      'استعلام',
    );
    expect(
      integrationCapabilityLabel(IntegrationCapability.recharge, l10n),
      'شحن',
    );
    expect(
      integrationCapabilityLabel(IntegrationCapability.vouchers, l10n),
      'كروت في الكتالوج',
    );
    expect(
      integrationCapabilityLabel(IntegrationCapability.profiles, l10n),
      'عدة ملفات',
    );
  });
}
