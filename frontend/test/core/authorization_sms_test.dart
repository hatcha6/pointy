import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';

AuthorizationCapabilities _manager({required bool smsAvailable}) {
  return AuthorizationCapabilities.forUser(
    PosUser(
      id: 1,
      username: 'owner',
      role: UserRole.manager,
      isActive: true,
      smsAvailable: smsAvailable,
    ),
  );
}

/// A supervisor holding every CRM permission and the invoice one.
AuthorizationCapabilities _crmStaff({
  required bool smsAvailable,
  Set<String> permissions = const {
    'sales.view_order',
    'crm.view_conversations',
    'crm.manage_conversations',
    'crm.manage_campaigns',
    'crm.send_campaigns',
    'messaging.manage_gateways',
  },
}) {
  return AuthorizationCapabilities.forUser(
    PosUser(
      id: 2,
      username: 'supervisor',
      role: UserRole.supervisor,
      isActive: true,
      permissions: permissions,
      smsAvailable: smsAvailable,
    ),
  );
}

/// SMS is a paid entitlement on the company's relay, like the assistant: no
/// inbox, no campaigns and no "send as message" without it — for anyone.
void main() {
  group('a manager', () {
    test('without SMS keeps the settings page and loses the rest', () {
      final capabilities = _manager(smsAvailable: false);

      // The settings page is where the shop reads "not in your subscription".
      expect(capabilities.canManageMessaging, isTrue);
      expect(capabilities.canViewConversations, isFalse);
      expect(capabilities.canManageConversations, isFalse);
      expect(capabilities.canManageCampaigns, isFalse);
      expect(capabilities.canSendCampaigns, isFalse);
      expect(capabilities.canSendSms, isFalse);
    });

    test('with SMS has all of it', () {
      final capabilities = _manager(smsAvailable: true);

      expect(capabilities.canManageMessaging, isTrue);
      expect(capabilities.canViewConversations, isTrue);
      expect(capabilities.canManageConversations, isTrue);
      expect(capabilities.canManageCampaigns, isTrue);
      expect(capabilities.canSendCampaigns, isTrue);
      expect(capabilities.canSendSms, isTrue);
    });

    test('SMS and the assistant are separate entitlements', () {
      final capabilities = AuthorizationCapabilities.forUser(
        const PosUser(
          id: 1,
          username: 'owner',
          role: UserRole.manager,
          isActive: true,
          aiAvailable: true,
        ),
      );

      expect(capabilities.allows(AppCapability.useAiAssistant), isTrue);
      expect(capabilities.canSendSms, isFalse);
    });
  });

  group('staff', () {
    test('held CRM permissions do not conjure SMS', () {
      final capabilities = _crmStaff(smsAvailable: false);

      expect(capabilities.canViewInvoices, isTrue);
      expect(capabilities.canManageMessaging, isTrue);
      expect(capabilities.canViewConversations, isFalse);
      expect(capabilities.canManageConversations, isFalse);
      expect(capabilities.canManageCampaigns, isFalse);
      expect(capabilities.canSendCampaigns, isFalse);
      expect(capabilities.canSendSms, isFalse);
    });

    test('with SMS, the CRM permissions work as granted', () {
      final capabilities = _crmStaff(smsAvailable: true);

      expect(capabilities.canViewConversations, isTrue);
      expect(capabilities.canManageConversations, isTrue);
      expect(capabilities.canManageCampaigns, isTrue);
      expect(capabilities.canSendCampaigns, isTrue);
      expect(capabilities.canSendSms, isTrue);
    });

    test('sending an invoice rides the invoice permission', () {
      // The server gates the send on sales.view_order: whoever may open an
      // invoice may text it to its customer, and nobody else.
      final withInvoices = _crmStaff(
        smsAvailable: true,
        permissions: const {'sales.view_order'},
      );
      final withoutInvoices = _crmStaff(
        smsAvailable: true,
        permissions: const {'sales.add_order'},
      );

      expect(withInvoices.canSendSms, isTrue);
      expect(withInvoices.canViewConversations, isFalse);
      expect(withoutInvoices.canSendSms, isFalse);
    });
  });

  test('sms_available is read from the auth payload', () {
    final user = PosUser.fromJson(const {
      'id': 1,
      'username': 'owner',
      'role': 'manager',
      'sms_available': true,
    });

    expect(user.smsAvailable, isTrue);
    expect(PosUser.fromJson(const {'id': 1}).smsAvailable, isFalse);
  });
}
