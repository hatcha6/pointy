import 'dart:typed_data';

import '../models/companion.dart';
import 'api_session.dart';

/// Talks to the till half of the companion camera API.
///
/// Every call is scoped to a `till_key` — this install's own stable device id —
/// because the companion channel belongs to a till, not to a user: a phone
/// stays paired across a shift change, an app restart and an update.
class CompanionApiClient {
  const CompanionApiClient(this._session);

  final PosApiSession _session;

  /// Mints the QR a phone scans. Short-lived and single-use, so the till should
  /// only ask for one while the pairing sheet is actually on screen.
  Future<CompanionPairing> createPairing({
    required String tillKey,
    String tillLabel = '',
  }) async {
    final response = await _session.post(
      'companion/pairings/',
      body: {
        'till_key': tillKey,
        if (tillLabel.isNotEmpty) 'till_label': tillLabel,
      },
    );
    _session.ensureSuccess(response, 'Companion pairing failed with status');
    final decoded = _session.decodedBody(response);
    return CompanionPairing.fromJson(
      decoded is Map<String, Object?> ? decoded : const {},
    );
  }

  Future<List<CompanionDevice>> listDevices(String tillKey) async {
    final response = await _session.get(
      'companion/devices/',
      query: {'till_key': tillKey},
    );
    _session.ensureSuccess(response, 'Companion devices failed with status');
    return companionDevicesFromResponse(_session.decodedBody(response));
  }

  /// Silences or wakes a paired phone without unpairing it — the guard against
  /// a phone in a pocket scanning into an open cart.
  Future<CompanionDevice> setPaused(int deviceId, bool isPaused) async {
    final response = await _session.patch(
      'companion/devices/$deviceId/',
      body: {'is_paused': isPaused},
    );
    _session.ensureSuccess(response, 'Companion pause failed with status');
    final decoded = _session.decodedBody(response);
    return CompanionDevice.fromJson(
      decoded is Map<String, Object?> ? decoded : const {},
    );
  }

  Future<void> unpair(int deviceId) async {
    final response = await _session.delete('companion/devices/$deviceId/');
    _session.ensureSuccess(response, 'Companion unpair failed with status');
  }

  /// The polling fallback, and the replay a till uses to catch up after its
  /// stream dropped. Returns everything newer than [since].
  Future<CompanionEventPage> events({
    required String tillKey,
    int since = 0,
    int limit = 100,
  }) async {
    final response = await _session.get(
      'companion/events/',
      query: {'till_key': tillKey, 'since': '$since', 'limit': '$limit'},
    );
    _session.ensureSuccess(response, 'Companion events failed with status');
    final decoded = _session.decodedBody(response);
    return CompanionEventPage.fromJson(
      decoded is Map<String, Object?> ? decoded : const {},
    );
  }

  /// The live channel. The backend sends a `ping` every 15s, so the idle
  /// timeout measures a dead connection rather than a quiet shop, and asks the
  /// client to reconnect once an hour so no socket lives indefinitely.
  Stream<SseEvent> openStream({required String tillKey, int since = 0}) {
    return _session.openEventStream(
      'companion/stream/',
      method: 'GET',
      query: {'till_key': tillKey, 'since': '$since'},
      connectTimeout: const Duration(seconds: 15),
      idleTimeout: const Duration(seconds: 45),
    );
  }

  /// Asks the paired phone for one specific photo. With [ownerType]/[ownerId]
  /// the picture files itself against that record on arrival; without them it
  /// comes back to the till as a free capture.
  Future<CompanionCaptureRequest> requestCapture({
    required String tillKey,
    String prompt = '',
    String ownerType = '',
    int? ownerId,
    String role = '',
    bool isPrimary = false,
    bool allowMultiple = false,
  }) async {
    final response = await _session.post(
      'companion/capture-requests/',
      body: {
        'till_key': tillKey,
        if (prompt.isNotEmpty) 'prompt': prompt,
        if (ownerType.isNotEmpty && ownerId != null) ...{
          'owner_type': ownerType,
          'owner_id': ownerId,
        },
        if (role.isNotEmpty) 'role': role,
        'is_primary': isPrimary,
        'allow_multiple': allowMultiple,
      },
    );
    _session.ensureSuccess(
      response,
      'Companion capture request failed with status',
    );
    final decoded = _session.decodedBody(response);
    return CompanionCaptureRequest.fromJson(
      decoded is Map<String, Object?> ? decoded : const {},
    );
  }

  /// The bytes of a photo a phone just took.
  ///
  /// A companion capture is stored server-side, so what comes back to the till
  /// is an attachment id rather than a file. Surfaces that need the bytes
  /// themselves — the AI composer, which sends the picture inline to the model
  /// — fetch them here.
  Future<Uint8List> downloadCapture(int attachmentId) async {
    final response = await _session.get('attachments/$attachmentId/content/');
    _session.ensureSuccess(
      response,
      'Companion capture download failed with status',
    );
    return response.bodyBytes;
  }

  Future<void> cancelCaptureRequest(int id) async {
    final response = await _session.delete('companion/capture-requests/$id/');
    _session.ensureSuccess(
      response,
      'Companion capture cancel failed with status',
    );
  }
}
