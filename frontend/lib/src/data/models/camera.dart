/// Camera and recorder models, mirroring `apps.surveillance` on the backend.
///
/// Nothing here carries a recorder password: the backend never sends one, which
/// is the whole point of proxying video rather than letting tills dial the DVR
/// themselves.
library;

/// Which encoder track to pull. The sub-stream is the default everywhere —
/// a wall tile is a few hundred pixels wide, and a DVR refuses too many
/// simultaneous main-stream pulls.
enum CameraQuality {
  main('main'),
  sub('sub');

  const CameraQuality(this.wireValue);

  final String wireValue;

  static CameraQuality fromWire(Object? value) {
    final raw = value?.toString();
    for (final quality in CameraQuality.values) {
      if (quality.wireValue == raw) {
        return quality;
      }
    }
    return CameraQuality.sub;
  }
}

enum CameraStatus {
  unknown('unknown'),
  online('online'),
  offline('offline');

  const CameraStatus(this.wireValue);

  final String wireValue;

  static CameraStatus fromWire(Object? value) {
    final raw = value?.toString();
    for (final status in CameraStatus.values) {
      if (status.wireValue == raw) {
        return status;
      }
    }
    return CameraStatus.unknown;
  }
}

enum RecorderBrand {
  auto('auto'),
  hikvision('hikvision'),
  dahua('dahua');

  const RecorderBrand(this.wireValue);

  final String wireValue;

  static RecorderBrand fromWire(Object? value) {
    final raw = value?.toString();
    for (final brand in RecorderBrand.values) {
      if (brand.wireValue == raw) {
        return brand;
      }
    }
    return RecorderBrand.auto;
  }
}

enum RecorderStatus {
  never('never'),
  ok('ok'),
  error('error');

  const RecorderStatus(this.wireValue);

  final String wireValue;

  static RecorderStatus fromWire(Object? value) {
    final raw = value?.toString();
    for (final status in RecorderStatus.values) {
      if (status.wireValue == raw) {
        return status;
      }
    }
    return RecorderStatus.never;
  }
}

class Camera {
  const Camera({
    required this.id,
    required this.recorderId,
    required this.channel,
    required this.name,
    required this.deviceName,
    required this.displayName,
    required this.isEnabled,
    required this.displayOrder,
    required this.coversCheckout,
    required this.liveQuality,
    required this.playbackQuality,
    required this.status,
    this.recorderName = '',
    this.lastFrameAt,
  });

  final int id;
  final int recorderId;
  final String recorderName;

  /// The channel number on the recorder. Read-only: it describes hardware.
  final int channel;

  /// The name the shop gave this camera. Ours, not the DVR's — see
  /// [deviceName] for what the box calls it.
  final String name;
  final String deviceName;
  final String displayName;
  final bool isEnabled;
  final int displayOrder;

  /// Whether this camera is offered on an invoice's page.
  final bool coversCheckout;
  final CameraQuality liveQuality;
  final CameraQuality playbackQuality;
  final CameraStatus status;
  final DateTime? lastFrameAt;

  factory Camera.fromJson(Map<String, Object?> json) {
    return Camera(
      id: (json['id'] as num?)?.toInt() ?? 0,
      recorderId: (json['recorder'] as num?)?.toInt() ?? 0,
      recorderName: json['recorder_name']?.toString() ?? '',
      channel: (json['channel'] as num?)?.toInt() ?? 0,
      name: json['name']?.toString() ?? '',
      deviceName: json['device_name']?.toString() ?? '',
      displayName: json['display_name']?.toString() ?? '',
      isEnabled: json['is_enabled'] != false,
      displayOrder: (json['display_order'] as num?)?.toInt() ?? 0,
      coversCheckout: json['covers_checkout'] == true,
      liveQuality: CameraQuality.fromWire(json['live_quality']),
      playbackQuality: CameraQuality.fromWire(json['playback_quality']),
      status: CameraStatus.fromWire(json['status']),
      lastFrameAt: DateTime.tryParse(json['last_frame_at']?.toString() ?? ''),
    );
  }

  Camera copyWith({
    String? name,
    bool? isEnabled,
    int? displayOrder,
    bool? coversCheckout,
    CameraQuality? liveQuality,
    CameraQuality? playbackQuality,
  }) {
    return Camera(
      id: id,
      recorderId: recorderId,
      recorderName: recorderName,
      channel: channel,
      name: name ?? this.name,
      deviceName: deviceName,
      displayName: (name ?? this.name).isNotEmpty
          ? (name ?? this.name)
          : displayName,
      isEnabled: isEnabled ?? this.isEnabled,
      displayOrder: displayOrder ?? this.displayOrder,
      coversCheckout: coversCheckout ?? this.coversCheckout,
      liveQuality: liveQuality ?? this.liveQuality,
      playbackQuality: playbackQuality ?? this.playbackQuality,
      status: status,
      lastFrameAt: lastFrameAt,
    );
  }
}

class Recorder {
  const Recorder({
    required this.id,
    required this.name,
    required this.brand,
    required this.detectedBrand,
    required this.host,
    required this.port,
    required this.rtspPort,
    required this.username,
    required this.hasPassword,
    required this.useHttps,
    required this.isEnabled,
    required this.status,
    this.modelName = '',
    this.firmware = '',
    this.serialNumber = '',
    this.channelCount = 0,
    this.clockOffsetMinutes = 0,
    this.clockOffsetIsMeasured = false,
    this.lastError = '',
    this.lastSeenAt,
    this.cameras = const [],
  });

  final int id;
  final String name;
  final RecorderBrand brand;

  /// What probing actually found, which wins over [brand] when they disagree.
  final String detectedBrand;
  final String host;
  final int port;
  final int rtspPort;
  final String username;
  final bool hasPassword;
  final bool useHttps;
  final bool isEnabled;
  final RecorderStatus status;
  final String modelName;
  final String firmware;
  final String serialNumber;
  final int channelCount;

  /// How far the recorder's clock is from UTC, measured at the last probe.
  final int clockOffsetMinutes;
  final bool clockOffsetIsMeasured;
  final String lastError;
  final DateTime? lastSeenAt;
  final List<Camera> cameras;

  String get displayName => name.isNotEmpty ? name : '$host:$port';

  factory Recorder.fromJson(Map<String, Object?> json) {
    final cameras = json['cameras'];
    return Recorder(
      id: (json['id'] as num?)?.toInt() ?? 0,
      name: json['name']?.toString() ?? '',
      brand: RecorderBrand.fromWire(json['brand']),
      detectedBrand: json['detected_brand']?.toString() ?? '',
      host: json['host']?.toString() ?? '',
      port: (json['port'] as num?)?.toInt() ?? 80,
      rtspPort: (json['rtsp_port'] as num?)?.toInt() ?? 554,
      username: json['username']?.toString() ?? '',
      hasPassword: json['has_password'] == true,
      useHttps: json['use_https'] == true,
      isEnabled: json['is_enabled'] != false,
      status: RecorderStatus.fromWire(json['status']),
      modelName: json['model_name']?.toString() ?? '',
      firmware: json['firmware']?.toString() ?? '',
      serialNumber: json['serial_number']?.toString() ?? '',
      channelCount: (json['channel_count'] as num?)?.toInt() ?? 0,
      clockOffsetMinutes: (json['clock_offset_minutes'] as num?)?.toInt() ?? 0,
      clockOffsetIsMeasured: json['clock_offset_is_measured'] == true,
      lastError: json['last_error']?.toString() ?? '',
      lastSeenAt: DateTime.tryParse(json['last_seen_at']?.toString() ?? ''),
      cameras: cameras is List
          ? cameras
                .whereType<Map<String, Object?>>()
                .map(Camera.fromJson)
                .toList(growable: false)
          : const [],
    );
  }
}

/// A recorder's connection details as the settings form holds them, before the
/// backend has seen any of it.
class RecorderDraft {
  const RecorderDraft({
    this.id,
    this.name = '',
    this.brand = RecorderBrand.auto,
    this.host = '',
    this.port = 80,
    this.rtspPort = 554,
    this.username = '',
    this.password = '',
    this.useHttps = false,
    this.isEnabled = true,
  });

  final int? id;
  final String name;
  final RecorderBrand brand;
  final String host;
  final int port;
  final int rtspPort;
  final String username;

  /// Blank means "keep the stored password" on an existing recorder — the
  /// backend never echoes one back, so a form can never re-send it.
  final String password;
  final bool useHttps;
  final bool isEnabled;

  factory RecorderDraft.fromRecorder(Recorder recorder) {
    return RecorderDraft(
      id: recorder.id,
      name: recorder.name,
      brand: recorder.brand,
      host: recorder.host,
      port: recorder.port,
      rtspPort: recorder.rtspPort,
      username: recorder.username,
      useHttps: recorder.useHttps,
      isEnabled: recorder.isEnabled,
    );
  }

  RecorderDraft copyWith({
    String? name,
    RecorderBrand? brand,
    String? host,
    int? port,
    int? rtspPort,
    String? username,
    String? password,
    bool? useHttps,
    bool? isEnabled,
  }) {
    return RecorderDraft(
      id: id,
      name: name ?? this.name,
      brand: brand ?? this.brand,
      host: host ?? this.host,
      port: port ?? this.port,
      rtspPort: rtspPort ?? this.rtspPort,
      username: username ?? this.username,
      password: password ?? this.password,
      useHttps: useHttps ?? this.useHttps,
      isEnabled: isEnabled ?? this.isEnabled,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'name': name,
      'brand': brand.wireValue,
      'host': host,
      'port': port,
      'rtsp_port': rtspPort,
      'username': username,
      if (password.isNotEmpty) 'password': password,
      'use_https': useHttps,
      'is_enabled': isEnabled,
    };
  }
}

/// One channel found by a connection test, before anything is saved.
class DetectedChannel {
  const DetectedChannel({
    required this.channel,
    required this.name,
    required this.online,
  });

  final int channel;
  final String name;
  final bool online;

  factory DetectedChannel.fromJson(Map<String, Object?> json) {
    return DetectedChannel(
      channel: (json['channel'] as num?)?.toInt() ?? 0,
      name: json['name']?.toString() ?? '',
      online: json['online'] != false,
    );
  }
}

class RecorderTestResult {
  const RecorderTestResult({
    required this.ok,
    this.error = '',
    this.brand = '',
    this.model = '',
    this.firmware = '',
    this.serial = '',
    this.clockOffsetMinutes,
    this.channels = const [],
  });

  final bool ok;
  final String error;
  final String brand;
  final String model;
  final String firmware;
  final String serial;
  final int? clockOffsetMinutes;
  final List<DetectedChannel> channels;

  factory RecorderTestResult.fromJson(Map<String, Object?> json) {
    final channels = json['channels'];
    return RecorderTestResult(
      ok: json['ok'] == true,
      error: json['error']?.toString() ?? '',
      brand: json['brand']?.toString() ?? '',
      model: json['model']?.toString() ?? '',
      firmware: json['firmware']?.toString() ?? '',
      serial: json['serial']?.toString() ?? '',
      clockOffsetMinutes: (json['clock_offset_minutes'] as num?)?.toInt(),
      channels: channels is List
          ? channels
                .whereType<Map<String, Object?>>()
                .map(DetectedChannel.fromJson)
                .toList(growable: false)
          : const [],
    );
  }
}

/// A stretch of stored footage on the recorder.
///
/// Painted on the playback timeline so a reviewer can see where the recording
/// actually is before scrubbing into a gap — the thing that makes an NVR
/// timeline readable rather than a blank bar.
class RecordingSegment {
  const RecordingSegment({
    required this.start,
    required this.end,
    this.sizeBytes = 0,
  });

  final DateTime start;
  final DateTime end;
  final int sizeBytes;

  Duration get duration => end.difference(start);

  factory RecordingSegment.fromJson(Map<String, Object?> json) {
    final start = DateTime.tryParse(json['start']?.toString() ?? '');
    final end = DateTime.tryParse(json['end']?.toString() ?? '');
    return RecordingSegment(
      start: start ?? DateTime.now(),
      end: end ?? start ?? DateTime.now(),
      sizeBytes: (json['size_bytes'] as num?)?.toInt() ?? 0,
    );
  }
}

/// The answer to "what has this camera got for this window".
///
/// [known] is false when the recorder would not say — plenty of firmware
/// refuses the search and plays back fine — so the timeline draws nothing
/// rather than drawing "no footage", which would be a lie.
class RecordingIndex {
  const RecordingIndex({this.known = false, this.segments = const []});

  final bool known;
  final List<RecordingSegment> segments;

  factory RecordingIndex.fromJson(Map<String, Object?> json) {
    final segments = json['segments'];
    return RecordingIndex(
      known: json['known'] == true,
      segments: segments is List
          ? segments
                .whereType<Map<String, Object?>>()
                .map(RecordingSegment.fromJson)
                .toList(growable: false)
          : const [],
    );
  }
}

/// What this install can actually do, so the UI never offers a button that
/// cannot work. Playback and export need ffmpeg on the server; live never does.
class SurveillanceStatus {
  const SurveillanceStatus({
    this.configured = false,
    this.recorderCount = 0,
    this.cameraCount = 0,
    this.checkoutCameraCount = 0,
    this.playbackAvailable = false,
    this.exportAvailable = false,
    this.variableSpeedAvailable = false,
    this.ffmpegVersion = '',
    this.maxLiveFps = 8,
    this.maxPlaybackFps = 0,
    this.smoothLiveAvailable = false,
  });

  final bool configured;
  final int recorderCount;
  final int cameraCount;
  final int checkoutCameraCount;
  final bool playbackAvailable;
  final bool exportAvailable;
  final bool variableSpeedAvailable;
  final String ffmpegVersion;

  /// The frame rate this server can actually carry. Without ffmpeg the only
  /// live path is snapshot polling, whose ceiling is an HTTP round trip per
  /// frame; with it, real video. The client asks for a rate derived from this
  /// rather than assuming a low one.
  final int maxLiveFps;
  final int maxPlaybackFps;
  final bool smoothLiveAvailable;

  factory SurveillanceStatus.fromJson(Map<String, Object?> json) {
    return SurveillanceStatus(
      configured: json['configured'] == true,
      recorderCount: (json['recorder_count'] as num?)?.toInt() ?? 0,
      cameraCount: (json['camera_count'] as num?)?.toInt() ?? 0,
      checkoutCameraCount:
          (json['checkout_camera_count'] as num?)?.toInt() ?? 0,
      playbackAvailable: json['playback_available'] == true,
      exportAvailable: json['export_available'] == true,
      variableSpeedAvailable: json['variable_speed_available'] == true,
      ffmpegVersion: json['ffmpeg_version']?.toString() ?? '',
      maxLiveFps: (json['max_live_fps'] as num?)?.toInt() ?? 8,
      maxPlaybackFps: (json['max_playback_fps'] as num?)?.toInt() ?? 0,
      smoothLiveAvailable: json['smooth_live_available'] == true,
    );
  }
}

/// The footage window for one invoice, and the cameras that can show it.
class InvoiceFootage {
  const InvoiceFootage({
    required this.orderId,
    required this.occurredAt,
    required this.start,
    required this.end,
    required this.playbackAvailable,
    required this.cameras,
    this.receiptNumber = '',
  });

  final int orderId;
  final String receiptNumber;
  final DateTime occurredAt;
  final DateTime start;
  final DateTime end;
  final bool playbackAvailable;
  final List<Camera> cameras;

  bool get hasCameras => cameras.isNotEmpty;

  factory InvoiceFootage.fromJson(Map<String, Object?> json) {
    final cameras = json['cameras'];
    final occurred =
        DateTime.tryParse(json['occurred_at']?.toString() ?? '') ??
        DateTime.now();
    return InvoiceFootage(
      orderId: (json['order_id'] as num?)?.toInt() ?? 0,
      receiptNumber: json['receipt_number']?.toString() ?? '',
      occurredAt: occurred,
      start:
          DateTime.tryParse(json['start']?.toString() ?? '') ??
          occurred.subtract(const Duration(seconds: 20)),
      end:
          DateTime.tryParse(json['end']?.toString() ?? '') ??
          occurred.add(const Duration(seconds: 40)),
      playbackAvailable: json['playback_available'] == true,
      cameras: cameras is List
          ? cameras
                .whereType<Map<String, Object?>>()
                .map(Camera.fromJson)
                .toList(growable: false)
          : const [],
    );
  }
}
