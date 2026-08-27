import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/models/relay_installation_status.dart';

void main() {
  group('RelayInstallationStatus.fromJson', () {
    test('parses the full status payload', () {
      final status = RelayInstallationStatus.fromJson(const {
        'configured': true,
        'remote_access_supported': true,
        'installation_id': 'POS-LY-7F3A',
        'shop_name': 'سوبر ماركت',
        'relay_public_api_url': 'https://relay.pointy.ly',
        'relay_connector_address': 'relay.pointy.ly:8443',
        'relay_enabled': true,
        'subscription_active': true,
        'ai_enabled': true,
        'subscription_ends_at': '2999-01-01T00:00:00Z',
        'last_synced_at': '2026-06-25T10:00:00Z',
        'connector_last_seen_at': '2026-06-25T09:59:00Z',
        'connector_version': '1.4.0',
      });

      expect(status.configured, isTrue);
      expect(status.remoteAccessSupported, isTrue);
      expect(status.installationId, 'POS-LY-7F3A');
      expect(status.shopName, 'سوبر ماركت');
      expect(status.relayEnabled, isTrue);
      expect(status.subscriptionActive, isTrue);
      expect(status.aiEnabled, isTrue);
      expect(status.connectorVersion, '1.4.0');
      expect(status.subscriptionEndsAt, isNotNull);
      expect(status.lastSyncedAt, isNotNull);
      expect(status.connectorLastSeenAt, isNotNull);
    });

    test('defaults missing fields to empty / false / null', () {
      final status = RelayInstallationStatus.fromJson(const {});

      expect(status.configured, isFalse);
      expect(status.installationId, isEmpty);
      expect(status.hasInstallationId, isFalse);
      expect(status.subscriptionEndsAt, isNull);
      expect(status.connectorLastSeenAt, isNull);
    });
  });

  group('computed entitlement helpers', () {
    RelayInstallationStatus build({
      bool relayEnabled = true,
      bool subscriptionActive = true,
      bool aiEnabled = true,
      DateTime? endsAt,
    }) {
      return RelayInstallationStatus(
        configured: true,
        remoteAccessSupported: relayEnabled && subscriptionActive,
        installationId: 'POS-1',
        shopName: 'shop',
        relayPublicApiUrl: '',
        relayConnectorAddress: '',
        relayEnabled: relayEnabled,
        subscriptionActive: subscriptionActive,
        aiEnabled: aiEnabled,
        subscriptionEndsAt: endsAt,
      );
    }

    test('subscriptionExpired is false with no end date or a future date', () {
      expect(build(endsAt: null).subscriptionExpired, isFalse);
      expect(
        build(
          endsAt: DateTime.now().add(const Duration(days: 5)),
        ).subscriptionExpired,
        isFalse,
      );
    });

    test('subscriptionExpired is true once the end date has passed', () {
      expect(
        build(
          endsAt: DateTime.now().subtract(const Duration(days: 1)),
        ).subscriptionExpired,
        isTrue,
      );
    });

    test('aiAvailable requires the AI flag, an active and unexpired sub', () {
      expect(build().aiAvailable, isTrue);
      expect(build(aiEnabled: false).aiAvailable, isFalse);
      expect(build(subscriptionActive: false).aiAvailable, isFalse);
      expect(
        build(
          endsAt: DateTime.now().subtract(const Duration(days: 1)),
        ).aiAvailable,
        isFalse,
      );
    });

    test('daysUntilExpiry is null without an end date', () {
      expect(build(endsAt: null).daysUntilExpiry, isNull);
      expect(
        build(
          endsAt: DateTime.now().add(const Duration(days: 10, hours: 1)),
        ).daysUntilExpiry,
        10,
      );
    });
  });
}
