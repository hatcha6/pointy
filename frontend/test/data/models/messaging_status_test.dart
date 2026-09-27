import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/models/clock_time.dart';
import 'package:pointy_frontend/src/data/models/messaging_gateway.dart';
import 'package:pointy_frontend/src/data/models/messaging_status.dart';

/// `GET /api/messaging/status/` as the contract spells it.
Map<String, Object?> _payload({
  Object? usage = const {
    'used': 12,
    'limit': 500,
    'remaining': 488,
    'period_start': '2026-09-01T00:00:00+02:00',
    'resets_at': '2026-10-01T00:00:00+02:00',
  },
  String usageError = '',
  Object? configured = true,
}) {
  return {
    'entitled': true,
    'available': true,
    'test_mode': false,
    'gateway': {
      'id': 1,
      'name': 'رسائل دفتر',
      'provider': 'relay',
      'channel': 'sms',
      'is_default': true,
      'is_active': true,
      'max_messages_per_minute': 30,
      'daily_cap': 0,
      'quiet_hours_start': '22:00:00',
      'quiet_hours_end': '08:00:00',
      'send_timeout_seconds': 20,
      'last_seen_at': '2026-09-27T08:15:00Z',
      'last_error': '',
      'last_error_at': null,
      'created_at': '2026-09-01T08:00:00Z',
      'updated_at': '2026-09-27T08:15:00Z',
    },
    'usage': usage,
    'usage_error': usageError,
    'templates': [
      {
        'kind': 'invoice',
        'title': 'فاتورة بيع',
        'description': 'تُرسل للعميل من تفاصيل الفاتورة.',
        'text': r'شكرًا لتسوقك من $1. فاتورتك رقم $2 بقيمة $3.',
        'variables': ['اسم المحل', 'رقم الفاتورة', 'الإجمالي'],
        'example':
            'شكرًا لتسوقك من محل النور. فاتورتك رقم 000123 بقيمة 125.00 د.ل.',
        'consent_class': 'transactional',
        'configured': configured,
      },
      {
        'kind': 'marketing',
        'title': 'عرض ترويجي',
        'text': r'عرض من $1: $2 (لإيقاف العروض أبلغ المحل)',
        'consent_class': 'marketing',
        'configured': false,
      },
    ],
  };
}

void main() {
  group('MessagingServiceStatus.fromJson', () {
    test('parses the full status payload', () {
      final status = MessagingServiceStatus.fromJson(_payload());

      expect(status.entitled, isTrue);
      expect(status.available, isTrue);
      expect(status.testMode, isFalse);
      expect(status.usageError, isEmpty);

      final gateway = status.gateway!;
      expect(gateway.provider, MessagingProvider.relay);
      expect(gateway.isActive, isTrue);
      expect(gateway.maxMessagesPerMinute, 30);
      expect(gateway.quietHoursStart, const ClockTime(22, 0));
      expect(gateway.quietHoursEnd, const ClockTime(8, 0));
      expect(gateway.hasQuietHours, isTrue);
      expect(gateway.lastSeenAt, isNotNull);
      expect(gateway.hasError, isFalse);

      final usage = status.usage!;
      expect(usage.used, 12);
      expect(usage.limit, 500);
      expect(usage.remaining, 488);
      expect(usage.isUnlimited, isFalse);
      expect(usage.isExhausted, isFalse);
      expect(usage.fraction, closeTo(0.024, 1e-9));
      // Libya's midnight on the 1st is still the 30th in UTC.
      expect(usage.resetsAt, DateTime.utc(2026, 9, 30, 22));

      expect(status.templates, hasLength(2));
      final invoice = status.templates.first;
      expect(invoice.kind, 'invoice');
      expect(invoice.variables, ['اسم المحل', 'رقم الفاتورة', 'الإجمالي']);
      expect(invoice.example, contains('محل النور'));
      expect(invoice.configured, isTrue);
      expect(invoice.isMarketing, isFalse);
      expect(status.templates.last.isMarketing, isTrue);
      expect(status.templates.last.configured, isFalse);
    });

    test('a null usage keeps the reason instead', () {
      final status = MessagingServiceStatus.fromJson(
        _payload(
          usage: null,
          usageError: 'relay_unreachable',
          configured: null,
        ),
      );

      expect(status.usage, isNull);
      expect(status.isRelayUnreachable, isTrue);
      expect(status.isNotConfigured, isFalse);
      // The relay could not be asked, so nobody knows what is approved.
      expect(status.templates.first.configured, isNull);
    });

    test('limit 0 is unlimited, never exhausted', () {
      final usage = MessagingUsage.fromJson(const {
        'used': 9000,
        'limit': 0,
        'remaining': -1,
      });

      expect(usage.isUnlimited, isTrue);
      expect(usage.isExhausted, isFalse);
      expect(usage.fraction, 0);
      expect(usage.remaining, -1);
    });

    test('a spent allowance is exhausted and clamps its bar', () {
      final usage = MessagingUsage.fromJson(const {'used': 520, 'limit': 500});

      expect(usage.isExhausted, isTrue);
      expect(usage.fraction, 1.0);
      // Derived when the payload leaves it out.
      expect(usage.remaining, 0);
    });

    test('an unentitled shop with no gateway parses to nulls', () {
      final status = MessagingServiceStatus.fromJson(const {
        'entitled': false,
        'available': false,
        'gateway': null,
        'usage': null,
        'usage_error': 'not_entitled',
      });

      expect(status.entitled, isFalse);
      expect(status.gateway, isNull);
      expect(status.usage, isNull);
      expect(status.templates, isEmpty);
    });

    test('withGateway makes availability follow the switch', () {
      final status = MessagingServiceStatus.fromJson(_payload());
      final off = status.withGateway(
        const MessagingGateway(id: 1, name: 'رسائل دفتر', isActive: false),
      );

      expect(off.available, isFalse);
      expect(off.usage, same(status.usage));
      expect(off.templates, same(status.templates));
    });
  });

  group('MessagingGateway', () {
    test('an unknown provider does not break parsing', () {
      final gateway = MessagingGateway.fromJson(const {
        'id': 3,
        'provider': 'sms_gate',
      });

      expect(gateway.provider, MessagingProvider.unknown);
      expect(gateway.quietHoursStart, isNull);
      expect(gateway.hasQuietHours, isFalse);
    });

    test('splits "code: detail" in the last error', () {
      const gateway = MessagingGateway(
        id: 1,
        name: 'x',
        lastError:
            'provider_credit: wallet must have at least 0.15 LYD to send an sms',
      );

      expect(gateway.lastErrorCode, 'provider_credit');
      expect(gateway.lastErrorDetail, startsWith('wallet must'));
    });

    test('a last error without a code is all detail', () {
      const gateway = MessagingGateway(id: 1, name: 'x', lastError: 'boom');

      expect(gateway.lastErrorCode, isEmpty);
      expect(gateway.lastErrorDetail, 'boom');
    });
  });

  group('ClockTime', () {
    test('reads HH:MM and HH:MM:SS, rejects the rest', () {
      expect(ClockTime.tryParse('22:00:00'), const ClockTime(22, 0));
      expect(ClockTime.tryParse('7:05'), const ClockTime(7, 5));
      expect(ClockTime.tryParse('08:30:00.000000'), const ClockTime(8, 30));
      expect(ClockTime.tryParse(null), isNull);
      expect(ClockTime.tryParse(''), isNull);
      expect(ClockTime.tryParse('25:00'), isNull);
      expect(ClockTime.tryParse('late'), isNull);
    });

    test('writes what the backend stores and shows 24-hour', () {
      expect(const ClockTime(7, 5).toJson(), '07:05:00');
      expect(const ClockTime(22, 0).label, '22:00');
    });
  });

  group('MessagingSendResult', () {
    test('parses a serialized message with its body', () {
      final sent = MessagingSendResult.fromJson(const {
        'status': 'sent',
        'error_code': '',
        'error_detail': '',
        'body': 'رسالة تجريبية من محل النور عبر دفتر',
        'template_kind': 'test',
      });

      expect(sent.ok, isTrue);
      expect(sent.isFailure, isFalse);
      expect(sent.body, contains('محل النور'));
    });

    test('only a terminal status is a failure', () {
      expect(const MessagingSendResult(status: 'failed').isFailure, isTrue);
      expect(
        const MessagingSendResult(status: 'blocked_consent').isFailure,
        isTrue,
      );
      expect(const MessagingSendResult(status: 'queued').isFailure, isFalse);
      expect(const MessagingSendResult(status: 'queued').ok, isFalse);
    });
  });
}
