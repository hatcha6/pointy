import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/models/system_backup.dart';

/// The banner on the backup screen is driven entirely by this parse, and it has
/// to be right in two directions: it must raise the alarm when the shop really
/// has no way back, and it must stay quiet against a backend too old to answer
/// the question — a client mid-rollout should not be told its backups are broken
/// on the strength of a missing field.
void main() {
  group('BackupHealth', () {
    test('reads a stale shop from the backend payload', () {
      final status = BackupOperationsStatus.fromJson({
        'schedule': {'enabled': true, 'destination_path': '/mnt/usb'},
        'health': {
          'enabled': true,
          'is_stale': true,
          'stale_after_hours': 48,
          'last_error': 'destination unavailable',
          'latest_verified_at': '2026-08-20T02:04:00Z',
          'last_attempt_at': '2026-08-24T02:00:00Z',
        },
      });

      expect(status.health.isStale, isTrue);
      expect(status.health.hasNeverVerified, isFalse);
      expect(status.health.staleAfterHours, 48);
      expect(status.health.lastError, 'destination unavailable');
      expect(status.health.latestVerifiedAt?.toUtc().day, 20);
    });

    test('a shop that has never verified a backup reports it', () {
      final status = BackupOperationsStatus.fromJson({
        'schedule': const <String, Object?>{},
        'health': const <String, Object?>{
          'enabled': true,
          'is_stale': true,
          'stale_after_hours': 48,
          'last_error': '',
          'latest_verified_at': null,
        },
      });

      expect(status.health.hasNeverVerified, isTrue);
      expect(status.health.isStale, isTrue);
    });

    test('a healthy shop raises nothing', () {
      final status = BackupOperationsStatus.fromJson({
        'schedule': const <String, Object?>{},
        'health': const <String, Object?>{
          'enabled': true,
          'is_stale': false,
          'stale_after_hours': 48,
          'last_error': '',
          'latest_verified_at': '2026-08-24T02:04:00Z',
        },
      });

      expect(status.health.isStale, isFalse);
    });

    test(
      'an older backend with no health field does not raise a false alarm',
      () {
        final status = BackupOperationsStatus.fromJson({
          'schedule': const <String, Object?>{'enabled': true},
        });

        expect(status.health.isStale, isFalse);
        expect(status.latestVerifiedBackupJob, isNull);
      },
    );
  });
}
