import 'dart:typed_data';

import '../../core/result.dart';
import '../models/companion.dart';
import '../services/api_session.dart';
import '../services/machine_lan_address.dart';
import '../services/pos_api_service.dart';

/// [Result]-wrapped access to the companion camera, so view models branch on
/// success/failure without try/catch. The live event stream is deliberately not
/// wrapped: it is consumed by [CompanionBridge], which handles its own
/// reconnection.
class CompanionRepository {
  const CompanionRepository(
    this._service, {
    MachineAddressReader readAddresses = readMachineIpv4Addresses,
  }) : _readAddresses = readAddresses;

  final PosApiService _service;
  final MachineAddressReader _readAddresses;

  /// The QR is for the phone, not this till. The backend builds its URL from
  /// the address this till reached it on, and a till on the server PC reaches
  /// it over loopback — a QR the phone would open on itself. See
  /// [lanReachableUrl].
  Future<Result<CompanionPairing>> createPairing({
    required String tillKey,
    String tillLabel = '',
  }) {
    return Result.guard(() async {
      final pairing = await _service.createCompanionPairing(
        tillKey: tillKey,
        tillLabel: tillLabel,
      );
      return pairing.copyWith(
        url: await lanReachableUrl(pairing.url, readAddresses: _readAddresses),
      );
    });
  }

  Future<Result<List<CompanionDevice>>> loadDevices(String tillKey) {
    return Result.guard(() => _service.fetchCompanionDevices(tillKey));
  }

  Future<Result<CompanionDevice>> setPaused(int deviceId, bool isPaused) {
    return Result.guard(
      () => _service.setCompanionDevicePaused(deviceId, isPaused),
    );
  }

  Future<Result<void>> unpair(int deviceId) {
    return Result.guard(() => _service.unpairCompanionDevice(deviceId));
  }

  Future<Result<CompanionEventPage>> loadEvents({
    required String tillKey,
    int since = 0,
  }) {
    return Result.guard(
      () => _service.fetchCompanionEvents(tillKey: tillKey, since: since),
    );
  }

  Future<Result<CompanionCaptureRequest>> requestCapture({
    required String tillKey,
    String prompt = '',
    String ownerType = '',
    int? ownerId,
    String role = '',
    bool isPrimary = false,
    bool allowMultiple = false,
  }) {
    return Result.guard(
      () => _service.requestCompanionCapture(
        tillKey: tillKey,
        prompt: prompt,
        ownerType: ownerType,
        ownerId: ownerId,
        role: role,
        isPrimary: isPrimary,
        allowMultiple: allowMultiple,
      ),
    );
  }

  Future<Result<Uint8List>> downloadCapture(int attachmentId) {
    return Result.guard(() => _service.downloadCompanionCapture(attachmentId));
  }

  Future<Result<void>> cancelCaptureRequest(int id) {
    return Result.guard(() => _service.cancelCompanionCaptureRequest(id));
  }

  Stream<SseEvent> openStream({required String tillKey, int since = 0}) {
    return _service.streamCompanionEvents(tillKey: tillKey, since: since);
  }
}
