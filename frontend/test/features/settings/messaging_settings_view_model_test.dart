import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/clock_time.dart';
import 'package:pointy_frontend/src/data/models/messaging_gateway.dart';
import 'package:pointy_frontend/src/data/models/messaging_status.dart';
import 'package:pointy_frontend/src/data/repositories/messaging_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/settings/view_models/messaging_settings_view_model.dart';

MessagingGateway _gateway({
  bool isActive = true,
  int perMinute = 30,
  int dailyCap = 0,
  ClockTime? start = const ClockTime(22, 0),
  ClockTime? end = const ClockTime(8, 0),
}) {
  return MessagingGateway(
    id: 7,
    name: 'رسائل دفتر',
    isDefault: true,
    isActive: isActive,
    maxMessagesPerMinute: perMinute,
    dailyCap: dailyCap,
    quietHoursStart: start,
    quietHoursEnd: end,
  );
}

MessagingServiceStatus _status({
  bool entitled = true,
  MessagingGateway? gateway,
  MessagingUsage? usage = const MessagingUsage(
    used: 12,
    limit: 500,
    remaining: 488,
  ),
  String usageError = '',
}) {
  final resolved = gateway ?? _gateway();
  return MessagingServiceStatus(
    entitled: entitled,
    available: entitled && resolved.isActive,
    gateway: resolved,
    usage: usage,
    usageError: usageError,
  );
}

PosApiException _refusal(Map<String, Object?> body, {int status = 400}) {
  return PosApiException(
    message: 'refused $status',
    statusCode: status,
    responseBody: jsonEncode(body),
  );
}

void main() {
  group('where the shop stands', () {
    test('without SMS in the subscription there is nothing to edit', () async {
      final vm = MessagingSettingsViewModel(
        _FakeRepo(
          status: _status(
            entitled: false,
            usage: null,
            usageError: 'not_entitled',
          ),
        ),
      );
      await vm.load();

      expect(vm.serviceState, MessagingServiceState.notSubscribed);
      expect(vm.canEdit, isFalse);
      expect(vm.canTest, isFalse);
      // "Not entitled" is the story; a usage-unavailable banner would be noise.
      expect(vm.isUsageUnavailable, isFalse);
    });

    test('the relay refusing outranks a stale local entitlement', () async {
      // Mirrored "entitled", but the relay said 402 when asked for usage: the
      // sends would be refused the same way, so the page must not say "on".
      final vm = MessagingSettingsViewModel(
        _FakeRepo(status: _status(usage: null, usageError: 'not_entitled')),
      );
      await vm.load();

      expect(vm.serviceState, MessagingServiceState.notSubscribed);
      expect(vm.canEdit, isFalse);
      expect(vm.canTest, isFalse);
    });

    test('a working service seeds the form from the saved gateway', () async {
      final vm = MessagingSettingsViewModel(
        _FakeRepo(status: _status(gateway: _gateway(dailyCap: 200))),
      );
      await vm.load();

      expect(vm.serviceState, MessagingServiceState.active);
      expect(vm.canEdit, isTrue);
      expect(vm.canTest, isTrue);
      expect(vm.isActive, isTrue);
      expect(vm.maxMessagesPerMinute, 30);
      expect(vm.dailyCap, 200);
      expect(vm.quietHoursStart, const ClockTime(22, 0));
      expect(vm.quietHoursEnd, const ClockTime(8, 0));
      expect(vm.usage?.used, 12);
    });

    test('switched off: editable, but no test send', () async {
      final vm = MessagingSettingsViewModel(
        _FakeRepo(status: _status(gateway: _gateway(isActive: false))),
      );
      await vm.load();

      expect(vm.serviceState, MessagingServiceState.disabled);
      expect(vm.canEdit, isTrue);
      expect(vm.canTest, isFalse);
    });

    test('a relay without the provider set up reads as not ready', () async {
      final vm = MessagingSettingsViewModel(
        _FakeRepo(status: _status(usage: null, usageError: 'not_configured')),
      );
      await vm.load();

      expect(vm.serviceState, MessagingServiceState.notReady);
    });

    test(
      'an unreachable relay leaves usage unknown, not the service',
      () async {
        final vm = MessagingSettingsViewModel(
          _FakeRepo(
            status: _status(usage: null, usageError: 'relay_unreachable'),
          ),
        );
        await vm.load();

        expect(vm.serviceState, MessagingServiceState.active);
        expect(vm.isUsageUnavailable, isTrue);
      },
    );

    test('a failed load says so', () async {
      final vm = MessagingSettingsViewModel(
        _FakeRepo(statusResult: Error(Exception('offline'))),
      );
      await vm.load();

      expect(vm.hasLoadError, isTrue);
      expect(vm.hasStatus, isFalse);
    });
  });

  group('saving the dials', () {
    test('a fresh load is clean and has nothing to save', () async {
      final vm = MessagingSettingsViewModel(_FakeRepo(status: _status()));
      await vm.load();

      expect(vm.isDirty, isFalse);
      expect(vm.canSave, isFalse);
    });

    test('one PATCH carries every editable field', () async {
      final repo = _FakeRepo(status: _status());
      final vm = MessagingSettingsViewModel(repo);
      await vm.load();

      vm.setActive(false);
      vm.setMaxMessagesPerMinute(12);
      vm.setDailyCap(150);
      vm.setQuietHoursStart(const ClockTime(21, 30));
      expect(vm.isDirty, isTrue);
      expect(vm.canSave, isTrue);

      final revision = vm.revision;
      expect(await vm.save(), isTrue);

      expect(repo.updatedId, 7);
      expect(repo.update?.toJson(), {
        'is_active': false,
        'max_messages_per_minute': 12,
        'daily_cap': 150,
        'quiet_hours_start': '21:30:00',
        'quiet_hours_end': '08:00:00',
      });
      expect(vm.isDirty, isFalse);
      expect(vm.revision, greaterThan(revision));
      // The switch is the shop's: saving it off makes SMS unavailable here.
      expect(vm.status?.available, isFalse);
      expect(vm.serviceState, MessagingServiceState.disabled);
    });

    test('putting a value back makes the form clean again', () async {
      final vm = MessagingSettingsViewModel(_FakeRepo(status: _status()));
      await vm.load();

      vm.setDailyCap(10);
      expect(vm.isDirty, isTrue);
      vm.setDailyCap(0);
      expect(vm.isDirty, isFalse);
    });

    test('half a quiet-hours window cannot be saved', () async {
      final vm = MessagingSettingsViewModel(
        _FakeRepo(status: _status(gateway: _gateway(start: null, end: null))),
      );
      await vm.load();

      vm.setQuietHoursStart(const ClockTime(22, 0));
      expect(vm.hasQuietHoursIssue, isTrue);
      expect(vm.canSave, isFalse);

      vm.setQuietHoursEnd(const ClockTime(22, 0));
      expect(vm.hasQuietHoursIssue, isTrue, reason: 'an empty window');

      vm.setQuietHoursEnd(const ClockTime(7, 0));
      expect(vm.hasQuietHoursIssue, isFalse);
      expect(vm.canSave, isTrue);
    });

    test('clearing the window sends both ends as null', () async {
      final repo = _FakeRepo(status: _status());
      final vm = MessagingSettingsViewModel(repo);
      await vm.load();

      vm.clearQuietHours();
      expect(await vm.save(), isTrue);

      final payload = repo.update!.toJson();
      expect(payload.containsKey('quiet_hours_start'), isTrue);
      expect(payload['quiet_hours_start'], isNull);
      expect(payload['quiet_hours_end'], isNull);
    });

    test('a refused save keeps the edits and names the reason', () async {
      final repo = _FakeRepo(
        status: _status(),
        updateResult: Error(
          _refusal({
            'quiet_hours_end': ['حدّد بداية ونهاية أوقات الهدوء معًا.'],
          }),
        ),
      );
      final vm = MessagingSettingsViewModel(repo);
      await vm.load();

      vm.setDailyCap(40);
      expect(await vm.save(), isFalse);

      expect(vm.saveFailed, isTrue);
      expect(vm.saveErrorDetail, contains('أوقات الهدوء'));
      expect(vm.isDirty, isTrue);
      expect(vm.dailyCap, 40);

      // Editing again retires the failure: it described another form.
      vm.setDailyCap(41);
      expect(vm.saveFailed, isFalse);
    });

    test('a reload while editing keeps what is being typed', () async {
      final vm = MessagingSettingsViewModel(_FakeRepo(status: _status()));
      await vm.load();

      vm.setMaxMessagesPerMinute(5);
      await vm.load();

      expect(vm.maxMessagesPerMinute, 5);
      expect(vm.isDirty, isTrue);
    });

    test('discarding puts the saved values back', () async {
      final vm = MessagingSettingsViewModel(_FakeRepo(status: _status()));
      await vm.load();

      vm.setActive(false);
      vm.clearQuietHours();
      vm.discardEdits();

      expect(vm.isDirty, isFalse);
      expect(vm.isActive, isTrue);
      expect(vm.quietHoursStart, const ClockTime(22, 0));
    });
  });

  group('test send', () {
    test('success shows the text that went out, then re-reads', () async {
      final repo = _FakeRepo(
        status: _status(),
        testResult: const Ok(
          MessagingSendResult(
            status: 'sent',
            body: 'رسالة تجريبية من محل النور عبر دفتر',
          ),
        ),
      );
      final vm = MessagingSettingsViewModel(repo);
      await vm.load();
      final loadsBefore = repo.loads;

      await vm.sendTest(' 0912345678 ');

      expect(repo.testedTo, '0912345678');
      expect(vm.testOutcome, MessagingTestOutcome.sent);
      expect(vm.testBody, contains('محل النور'));
      expect(repo.loads, loadsBefore + 1);
    });

    test('a failed message carries its code and detail', () async {
      final vm = MessagingSettingsViewModel(
        _FakeRepo(
          status: _status(),
          testResult: const Ok(
            MessagingSendResult(
              status: 'failed',
              errorCode: 'invalid_phone',
              errorDetail: 'LY phones must be made of 9 numbers',
            ),
          ),
        ),
      );
      await vm.load();

      await vm.sendTest('12345');

      expect(vm.testOutcome, MessagingTestOutcome.failed);
      expect(vm.testErrorCode, 'invalid_phone');
      expect(vm.testErrorDetail, contains('9 numbers'));
    });

    test('a refused send reads the code from the response', () async {
      final vm = MessagingSettingsViewModel(
        _FakeRepo(
          status: _status(),
          testResult: Error(
            _refusal({
              'detail': 'خدمة الرسائل موقوفة من إعدادات الرسائل في المحل.',
              'code': 'service_disabled',
            }),
          ),
        ),
      );
      await vm.load();

      await vm.sendTest('0912345678');

      expect(vm.testOutcome, MessagingTestOutcome.failed);
      expect(vm.testErrorCode, 'service_disabled');
    });

    test('a queued message is on its way, not failed', () async {
      final vm = MessagingSettingsViewModel(
        _FakeRepo(
          status: _status(),
          testResult: const Ok(MessagingSendResult(status: 'queued')),
        ),
      );
      await vm.load();

      await vm.sendTest('0912345678');

      expect(vm.testOutcome, MessagingTestOutcome.queued);
    });

    test('nothing is sent while the service is switched off', () async {
      final repo = _FakeRepo(
        status: _status(gateway: _gateway(isActive: false)),
      );
      final vm = MessagingSettingsViewModel(repo);
      await vm.load();

      await vm.sendTest('0912345678');

      expect(repo.testedTo, isNull);
      expect(vm.testOutcome, MessagingTestOutcome.none);
    });
  });
}

class _FakeRepo extends MessagingRepository {
  _FakeRepo({
    MessagingServiceStatus? status,
    this.statusResult,
    this.updateResult,
    Result<MessagingSendResult>? testResult,
  }) : _status = status,
       testResult = testResult ?? const Ok(MessagingSendResult(status: 'sent')),
       super(PosApiService());

  MessagingServiceStatus? _status;
  final Result<MessagingServiceStatus>? statusResult;
  final Result<MessagingGateway>? updateResult;
  final Result<MessagingSendResult> testResult;

  int loads = 0;
  int? updatedId;
  MessagingGatewayUpdate? update;
  String? testedTo;

  @override
  Future<Result<MessagingServiceStatus>> loadStatus() async {
    loads++;
    return statusResult ?? Ok(_status!);
  }

  @override
  Future<Result<MessagingGateway>> updateGateway(
    int id,
    MessagingGatewayUpdate update,
  ) async {
    updatedId = id;
    this.update = update;
    final refusal = updateResult;
    if (refusal != null) {
      return refusal;
    }
    final saved = MessagingGateway(
      id: id,
      name: 'رسائل دفتر',
      isDefault: true,
      isActive: update.isActive,
      maxMessagesPerMinute: update.maxMessagesPerMinute,
      dailyCap: update.dailyCap,
      quietHoursStart: update.quietHoursStart,
      quietHoursEnd: update.quietHoursEnd,
    );
    _status = _status?.withGateway(saved);
    return Ok(saved);
  }

  @override
  Future<Result<MessagingSendResult>> testSend({
    required int id,
    required String to,
  }) async {
    testedTo = to;
    return testResult;
  }
}
