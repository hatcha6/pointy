import '../sandbox_payloads.dart';
import '../sandbox_request.dart';
import '../sandbox_shop.dart';

/// Identity, settings, and the background chatter every screen produces.
///
/// The quiet endpoints answer with real empty payloads rather than a 501:
/// notifications, companion devices and telemetry are not what a lesson
/// teaches, and a 501 here would put an error banner over the learner's first
/// screen.
SandboxReply handleBoot(SandboxShop shop, SandboxRequest request) {
  if (request.on('GET', 'auth/me/') != null) {
    return (200, userJson(shop));
  }
  if (request.on('GET', 'setup/status/') != null) {
    return (200, {'requires_onboarding': false});
  }
  if (request.on('GET', 'state/') != null) {
    return (
      200,
      {
        'versions': {
          'catalog': '${shop.stateVersion}',
          'sales': '${shop.stateVersion}',
          'purchasing': '${shop.stateVersion}',
          'contacts': '${shop.stateVersion}',
          'inventory': '${shop.stateVersion}',
        },
      },
    );
  }
  if (request.on('GET', 'shop-settings/') != null) {
    return (200, shopSettingsJson(shop));
  }
  if (request.on('GET', 'business-notifications/') != null ||
      request.on('GET', 'companion/devices/') != null ||
      request.on('GET', 'printing/printers/') != null ||
      request.on('GET', 'print-jobs/') != null ||
      request.on('GET', 'discounts/') != null ||
      request.on('GET', 'warehouses/') != null ||
      request.on('GET', 'modifier-groups/') != null ||
      request.on('GET', 'payment-cards/') != null ||
      // The practice shop keeps its money in one place, so the till's bank
      // picker never appears and checkout teaches the same steps it always
      // did. Answering empty rather than 501 is what keeps it that way: a
      // lesson must not be interrupted by a screen about bank accounts.
      request.on('GET', 'money-accounts/') != null ||
      request.on('GET', 'card-terminals/') != null) {
    return (200, page(const []));
  }
  if (request.on('GET', 'currencies/') != null) {
    return (200, page(const []));
  }
  if (request.on('GET', 'exchange-rates/current/') != null) {
    // The practice shop keeps one currency. Foreign pricing is a real feature
    // with its own guides; putting it in a first lesson's way is not.
    return (
      200,
      {'base_currency': 'LYD', 'rates': const <Object?>[], 'as_of': null},
    );
  }
  if (request.on('GET', 'dashboard/') != null) {
    // A manager lands on the dashboard before walking to the screen their
    // lesson is about. Nothing here is taught, so it answers empty rather than
    // 501 — an error banner over the first screen teaches the wrong thing.
    return (
      200,
      {
        'generated_at': stamp(DateTime.now()),
        'period': const <String, Object?>{},
        'sections': const <String, Object?>{},
        'today_special_days': const <Object?>[],
      },
    );
  }
  if (request.on('POST', 'analytics/events/') != null) {
    return (202, {'accepted': 0, 'duplicates': 0});
  }
  if (request.on('GET', 'subscription/status/') != null) {
    return (
      200,
      {'remote_access_active': false, 'ai_active': false, 'plan': 'training'},
    );
  }
  return null;
}
