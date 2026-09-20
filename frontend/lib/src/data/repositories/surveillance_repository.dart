import 'dart:typed_data';

import '../../core/result.dart';
import '../models/camera.dart';
import '../services/pos_api_service.dart';
import '../services/surveillance_api_client.dart';

/// Camera configuration and footage, wrapped in [Result] like every other
/// repository. The frame streams are deliberately *not* wrapped: a video stream
/// fails mid-flight, not once, so its errors belong on the stream.
class SurveillanceRepository {
  const SurveillanceRepository(this._service);

  final PosApiService _service;

  Future<Result<SurveillanceStatus>> loadStatus() {
    return Result.guard(() => _service.fetchSurveillanceStatus());
  }

  Future<Result<List<Recorder>>> loadRecorders() {
    return Result.guard(() => _service.fetchRecorders());
  }

  Future<Result<Recorder>> saveRecorder(RecorderDraft draft) {
    return Result.guard(() => _service.saveRecorder(draft));
  }

  Future<Result<void>> deleteRecorder(int id) {
    return Result.guard(() => _service.deleteRecorder(id));
  }

  Future<Result<RecorderTestResult>> testRecorder(RecorderDraft draft) {
    return Result.guard(() => _service.testRecorder(draft));
  }

  Future<Result<Recorder>> syncRecorder(int id) {
    return Result.guard(() => _service.syncRecorder(id));
  }

  Future<Result<List<Camera>>> loadCameras({bool enabledOnly = false}) {
    return Result.guard(() => _service.fetchCameras(enabledOnly: enabledOnly));
  }

  Future<Result<Camera>> updateCamera(
    int id, {
    String? name,
    bool? isEnabled,
    int? displayOrder,
    bool? coversCheckout,
    CameraQuality? liveQuality,
    CameraQuality? playbackQuality,
  }) {
    return Result.guard(
      () => _service.updateCamera(
        id,
        name: name,
        isEnabled: isEnabled,
        displayOrder: displayOrder,
        coversCheckout: coversCheckout,
        liveQuality: liveQuality,
        playbackQuality: playbackQuality,
      ),
    );
  }

  Future<Result<RecordingIndex>> loadRecordings(
    int cameraId, {
    required DateTime start,
    required DateTime end,
  }) {
    return Result.guard(
      () => _service.fetchCameraRecordings(cameraId, start: start, end: end),
    );
  }

  Future<Result<InvoiceFootage>> loadInvoiceFootage(int orderId) {
    return Result.guard(() => _service.fetchInvoiceFootage(orderId));
  }

  Stream<CameraFrame> liveFrames(
    int cameraId, {
    int fps = 4,
    CameraQuality? quality,
    bool smooth = false,
    int width = 0,
  }) {
    return _service.liveCameraFrames(
      cameraId,
      fps: fps,
      quality: quality,
      smooth: smooth,
      width: width,
    );
  }

  /// Deliberately not wrapped in a [Result]: the caller needs to tell
  /// "this camera has no microphone" apart from "that failed, try again",
  /// and collapsing both into a failure string would lose exactly that.
  Future<Uri> audioStreamUri(int cameraId) {
    return _service.cameraAudioStreamUri(cameraId);
  }

  Stream<CameraFrame> playbackFrames(
    int cameraId, {
    required DateTime start,
    required DateTime end,
    double speed = 1.0,
    int fps = 10,
    CameraQuality? quality,
    int width = 0,
  }) {
    return _service.playbackCameraFrames(
      cameraId,
      start: start,
      end: end,
      speed: speed,
      fps: fps,
      quality: quality,
      width: width,
    );
  }

  /// One JPEG from a camera, now. The cheap identity shot — no ffmpeg, no
  /// stream — used to put a face on a camera in a picker.
  Future<Result<Uint8List>> loadSnapshot(int cameraId) {
    return Result.guard(() => _service.fetchCameraSnapshot(cameraId));
  }

  Future<Result<Uint8List>> loadStill(int cameraId, {required DateTime at}) {
    return Result.guard(() => _service.fetchCameraStill(cameraId, at: at));
  }

  Future<Result<void>> exportClip(
    int cameraId, {
    required DateTime start,
    required DateTime end,
    CameraQuality? quality,
    required Future<void> Function(Stream<List<int>> bytes) onBytes,
  }) {
    return Result.guard(
      () => _service.exportCameraClip(
        cameraId,
        start: start,
        end: end,
        quality: quality,
        onBytes: onBytes,
      ),
    );
  }
}
