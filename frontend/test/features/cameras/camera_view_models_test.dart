import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/camera.dart';
import 'package:pointy_frontend/src/data/repositories/surveillance_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/data/services/surveillance_api_client.dart';
import 'package:pointy_frontend/src/features/cameras/view_models/camera_player_view_model.dart';
import 'package:pointy_frontend/src/features/cameras/view_models/camera_wall_view_model.dart';

class _FakeRepository extends SurveillanceRepository {
  _FakeRepository({
    this.cameras = const [],
    this.status = const SurveillanceStatus(),
  }) : super(PosApiService());

  final List<Camera> cameras;
  final SurveillanceStatus status;
  final List<String> renamed = [];
  final List<({DateTime start, DateTime end})> playbackWindows = [];

  @override
  Future<Result<SurveillanceStatus>> loadStatus() async => Ok(status);

  @override
  Future<Result<List<Camera>>> loadCameras({bool enabledOnly = false}) async {
    return Ok(cameras);
  }

  @override
  Future<Result<Camera>> updateCamera(
    int id, {
    String? name,
    bool? isEnabled,
    int? displayOrder,
    bool? coversCheckout,
    CameraQuality? liveQuality,
    CameraQuality? playbackQuality,
  }) async {
    renamed.add(name ?? '');
    final existing = cameras.firstWhere((camera) => camera.id == id);
    return Ok(existing.copyWith(name: name));
  }

  @override
  Stream<CameraFrame> playbackFrames(
    int cameraId, {
    required DateTime start,
    required DateTime end,
    double speed = 1.0,
    int fps = 10,
    CameraQuality? quality,
    int width = 0,
  }) {
    playbackWindows.add((start: start, end: end));
    return const Stream<CameraFrame>.empty();
  }

  @override
  Future<Result<RecordingIndex>> loadRecordings(
    int cameraId, {
    required DateTime start,
    required DateTime end,
  }) async {
    return const Ok(RecordingIndex());
  }

  @override
  Future<Result<Uint8List>> loadStill(
    int cameraId, {
    required DateTime at,
  }) async {
    return Ok(Uint8List(0));
  }
}

Camera _camera(int id) {
  return Camera(
    id: id,
    recorderId: 1,
    channel: id,
    name: 'Camera $id',
    deviceName: '',
    displayName: 'Camera $id',
    isEnabled: true,
    displayOrder: id,
    coversCheckout: false,
    liveQuality: CameraQuality.sub,
    playbackQuality: CameraQuality.main,
    status: CameraStatus.online,
  );
}

void main() {
  group('CameraWallViewModel', () {
    test('tile size decides the columns, and the viewport decides how many', () {
      // The wall scrolls, so a layout choice can only mean tile size — and the
      // same choice has to give one column on a phone and four on a monitor
      // without anybody configuring a breakpoint.
      expect(CameraWallLayout.medium.columnsFor(390), 1);
      expect(CameraWallLayout.medium.columnsFor(820), 2);
      expect(CameraWallLayout.medium.columnsFor(1280), 3);
      expect(CameraWallLayout.small.columnsFor(1280), 4);
      expect(CameraWallLayout.large.columnsFor(390), 1);
    });

    test('a viewport narrower than one tile still gets a column', () {
      expect(CameraWallLayout.large.columnsFor(120), 1);
    });

    test('renaming keeps the list in place', () async {
      final repository = _FakeRepository(cameras: [_camera(1), _camera(2)]);
      final viewModel = CameraWallViewModel(repository);
      await viewModel.load();

      await viewModel.rename(_camera(1), '  الصندوق  ');
      expect(repository.renamed.single, 'الصندوق');
      expect(viewModel.cameras.first.name, 'الصندوق');
      expect(viewModel.cameras, hasLength(2));
    });

    test('pausing stops every tile', () async {
      final viewModel = CameraWallViewModel(
        _FakeRepository(cameras: [_camera(1)]),
      );
      await viewModel.load();
      expect(viewModel.isPaused, isFalse);
      viewModel.togglePaused();
      expect(viewModel.isPaused, isTrue);
    });

    test(
      'the live rate comes from what the server says it can carry',
      () async {
        final viewModel = CameraWallViewModel(
          _FakeRepository(
            cameras: [_camera(1)],
            status: const SurveillanceStatus(maxLiveFps: 30),
          ),
        );
        await viewModel.load();
        expect(viewModel.status.maxLiveFps, 30);
      },
    );
  });

  group('CameraPlayerViewModel', () {
    CameraPlayerViewModel build({
      CameraPlayerMode mode = CameraPlayerMode.playback,
      DateTime? start,
      SurveillanceStatus? status,
    }) {
      return CameraPlayerViewModel(
        _FakeRepository(),
        camera: _camera(1),
        mode: mode,
        start: start ?? DateTime.utc(2026, 9, 7, 12),
        window: const Duration(minutes: 10),
        status:
            status ??
            const SurveillanceStatus(
              playbackAvailable: true,
              exportAvailable: true,
              variableSpeedAvailable: true,
              maxLiveFps: 30,
              maxPlaybackFps: 30,
            ),
      );
    }

    test('asks for the frame rate the server advertises, capped at 30', () {
      expect(build().liveFps, 30);
      expect(build().playbackFps, 30);
      expect(
        build(status: const SurveillanceStatus(maxLiveFps: 60)).liveFps,
        30,
      );
      // No ffmpeg: the only live path is snapshot polling, and the server says
      // so rather than the client guessing.
      expect(build(status: const SurveillanceStatus()).liveFps, 8);
    });

    test('a seek opens a new window and bumps the generation', () {
      final viewModel = build();
      final before = viewModel.generation;
      viewModel.seekTo(DateTime.utc(2026, 9, 7, 13));
      expect(viewModel.generation, greaterThan(before));
      expect(viewModel.windowStart, DateTime.utc(2026, 9, 7, 13));
    });

    test('live never seeks', () {
      final viewModel = build(mode: CameraPlayerMode.live);
      final before = viewModel.generation;
      viewModel.seekTo(DateTime.utc(2026, 9, 7, 13));
      expect(viewModel.generation, before);
    });

    test('progress tracks the frames the player reports', () {
      final viewModel = build();
      expect(viewModel.progress, 0);
      viewModel.reportFrameTime(DateTime.utc(2026, 9, 7, 12, 5));
      expect(viewModel.progress, closeTo(0.5, 0.001));
    });

    test('changing speed restarts from the current position, not the top', () {
      final viewModel = build();
      viewModel.reportFrameTime(DateTime.utc(2026, 9, 7, 12, 3));
      viewModel.setSpeed(4);
      expect(viewModel.speed, 4);
      expect(viewModel.windowStart, DateTime.utc(2026, 9, 7, 12, 3));
    });

    test('speed is refused when the server cannot vary it', () {
      final viewModel = build(
        status: const SurveillanceStatus(playbackAvailable: true),
      );
      viewModel.setSpeed(4);
      expect(viewModel.speed, 1.0);
    });

    test('play at the end replays the window rather than resuming nothing', () {
      final viewModel = build();
      viewModel.reportEnded();
      expect(viewModel.isPlaying, isFalse);
      viewModel.togglePlaying();
      expect(viewModel.isPlaying, isTrue);
      expect(viewModel.hasEnded, isFalse);
    });

    test('switching to live and back keeps the same camera', () {
      final viewModel = build(mode: CameraPlayerMode.live);
      expect(viewModel.isLive, isTrue);
      viewModel.switchTo(CameraPlayerMode.playback);
      expect(viewModel.isLive, isFalse);
      expect(viewModel.camera.id, 1);
    });
  });

  group('export mode', () {
    CameraPlayerViewModel selecting() {
      final viewModel = CameraPlayerViewModel(
        _FakeRepository(),
        camera: _camera(1),
        mode: CameraPlayerMode.playback,
        start: DateTime.utc(2026, 9, 7, 12),
        window: const Duration(minutes: 10),
        status: const SurveillanceStatus(
          playbackAvailable: true,
          exportAvailable: true,
        ),
      );
      viewModel.reportFrameTime(DateTime.utc(2026, 9, 7, 12, 5));
      viewModel.beginSelection();
      return viewModel;
    }

    test('entering the mode seeds a clip around where the reviewer is', () {
      // Not two blank handles to place from nothing: the reviewer is already
      // looking at the moment they care about.
      final viewModel = selecting();
      expect(viewModel.isSelecting, isTrue);
      expect(viewModel.hasSelection, isTrue);
      expect(
        viewModel.selectionStart!.isBefore(DateTime.utc(2026, 9, 7, 12, 5)),
        isTrue,
      );
      expect(
        viewModel.selectionEnd!.isAfter(DateTime.utc(2026, 9, 7, 12, 5)),
        isTrue,
      );
    });

    test('the seeded clip never runs outside the window', () {
      final viewModel = CameraPlayerViewModel(
        _FakeRepository(),
        camera: _camera(1),
        mode: CameraPlayerMode.playback,
        start: DateTime.utc(2026, 9, 7, 12),
        window: const Duration(minutes: 10),
        status: const SurveillanceStatus(playbackAvailable: true),
      );
      // Sitting on the very first frame: the clip must not start before the
      // window it is a selection of.
      viewModel.beginSelection();
      expect(
        viewModel.selectionStart!.isBefore(viewModel.windowStart),
        isFalse,
      );
      expect(viewModel.selectionEnd!.isAfter(viewModel.windowEnd), isFalse);
    });

    test('what plays is what will be exported', () {
      // The stream is cut to the selection, so the loop the reviewer watches is
      // the clip the file will contain — that is the whole point of the mode.
      final viewModel = selecting();
      final repository = _FakeRepository();
      final model = CameraPlayerViewModel(
        repository,
        camera: _camera(1),
        mode: CameraPlayerMode.playback,
        start: viewModel.windowStart,
        window: const Duration(minutes: 10),
        status: const SurveillanceStatus(playbackAvailable: true),
      );
      model.reportFrameTime(DateTime.utc(2026, 9, 7, 12, 5));
      model.beginSelection();
      model.frames();
      expect(repository.playbackWindows.single.start, model.selectionStart);
      expect(repository.playbackWindows.single.end, model.selectionEnd);
    });

    test('reaching the end of a selection loops instead of stopping', () {
      final viewModel = selecting();
      final before = viewModel.generation;
      viewModel.reportEnded();
      expect(viewModel.hasEnded, isFalse);
      expect(viewModel.isPlaying, isTrue);
      expect(viewModel.generation, greaterThan(before));
      expect(viewModel.position, viewModel.selectionStart);
    });

    test('a handle dragged past its partner is refused, not inverted', () {
      final viewModel = selecting();
      final start = viewModel.selectionStart!;
      final end = viewModel.selectionEnd!;
      viewModel.setSelection(end.add(const Duration(minutes: 1)), end);
      expect(viewModel.selectionStart, start);
      expect(viewModel.selectionEnd, end);
    });

    test('dragging does not re-cut until the finger lifts', () {
      final viewModel = selecting();
      final before = viewModel.generation;
      viewModel.setSelection(
        viewModel.windowStart,
        viewModel.windowStart.add(const Duration(minutes: 2)),
      );
      expect(viewModel.generation, before);

      viewModel.setSelection(
        viewModel.windowStart,
        viewModel.windowStart.add(const Duration(minutes: 3)),
        restart: true,
      );
      expect(viewModel.generation, greaterThan(before));
    });

    test('leaving the mode clears the clip', () {
      final viewModel = selecting();
      viewModel.cancelSelection();
      expect(viewModel.isSelecting, isFalse);
      expect(viewModel.hasSelection, isFalse);
    });
  });
}
