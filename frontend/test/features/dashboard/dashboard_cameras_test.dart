import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_frontend/src/data/services/api_session.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/camera.dart';
import 'package:pointy_frontend/src/data/repositories/surveillance_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/data/services/surveillance_api_client.dart';
import 'package:pointy_frontend/src/core/storage/app_key_value_store.dart';
import 'package:pointy_frontend/src/core/storage/key_value_store.dart';
import 'package:pointy_frontend/src/features/dashboard/view_models/dashboard_cameras_view_model.dart';

/// The camera strip on the dashboard.
///
/// The dashboard is a screen people leave open all day, so the two things worth
/// pinning are what it decides to show without being asked, and what it costs
/// while it shows it.
class _FakeRepository extends SurveillanceRepository {
  _FakeRepository({this.cameras = const []}) : super(PosApiService());

  final List<Camera> cameras;
  final List<Map<String, Object?>> frameRequests = [];

  @override
  Future<Result<List<Camera>>> loadCameras({bool enabledOnly = false}) async {
    return Ok(cameras);
  }

  @override
  Future<Result<SurveillanceStatus>> loadStatus() async {
    return const Ok(SurveillanceStatus(maxLiveFps: 30));
  }

  @override
  Future<Result<Uint8List>> loadSnapshot(int cameraId) async {
    return Ok(Uint8List.fromList([0xFF, 0xD8, cameraId, 0xFF, 0xD9]));
  }

  @override
  Stream<CameraFrame> liveFrames(
    int cameraId, {
    int fps = 4,
    CameraQuality? quality,
    bool smooth = false,
    int width = 0,
  }) {
    frameRequests.add({
      'camera': cameraId,
      'fps': fps,
      'smooth': smooth,
      'width': width,
    });
    return const Stream<CameraFrame>.empty();
  }
}

Camera _camera(
  int id, {
  bool coversCheckout = false,
  int order = 0,
  String name = '',
}) {
  return Camera(
    id: id,
    recorderId: 1,
    channel: id,
    name: name.isEmpty ? 'كاميرا $id' : name,
    deviceName: '',
    displayName: name.isEmpty ? 'كاميرا $id' : name,
    isEnabled: true,
    displayOrder: order,
    coversCheckout: coversCheckout,
    liveQuality: CameraQuality.sub,
    playbackQuality: CameraQuality.main,
    status: CameraStatus.online,
  );
}

void main() {
  setUp(() => AppKeyValueStore.debugOverride(MemoryKeyValueStore()));
  tearDown(AppKeyValueStore.reset);

  group('what it shows when nobody has chosen', () {
    test('picks the checkout cameras first', () async {
      // A dashboard that starts empty and waits to be configured is a dashboard
      // nobody configures, and the camera a shop's dashboard is for is the one
      // pointed at the counter.
      final viewModel = DashboardCamerasViewModel(
        _FakeRepository(
          cameras: [
            _camera(1, order: 0),
            _camera(2, order: 1, coversCheckout: true),
            _camera(3, order: 2),
          ],
        ),
      );
      await viewModel.load();
      expect(viewModel.visibleCameras.first.id, 2);
      expect(viewModel.hasExplicitSelection, isFalse);
      expect(viewModel.isVisible, isTrue);
    });

    test('stops at three — more than that is the camera wall', () async {
      final viewModel = DashboardCamerasViewModel(
        _FakeRepository(
          cameras: [for (var id = 1; id <= 8; id++) _camera(id, order: id)],
        ),
      );
      await viewModel.load();
      expect(viewModel.visibleCameras, hasLength(3));
    });

    test('a shop with no cameras gets no band at all', () async {
      final viewModel = DashboardCamerasViewModel(_FakeRepository());
      await viewModel.load();
      expect(viewModel.isVisible, isFalse);
    });
  });

  group('what it shows once somebody has', () {
    test('exactly what was chosen, in the shop\'s own order', () async {
      final viewModel = DashboardCamerasViewModel(
        _FakeRepository(cameras: [_camera(1), _camera(2), _camera(3)]),
      );
      await viewModel.load();
      await viewModel.select([3, 1]);
      expect(viewModel.visibleCameras.map((camera) => camera.id), [3, 1]);
      expect(viewModel.hasExplicitSelection, isTrue);
    });

    test('choosing none hides the band, and is not "never chose"', () async {
      // The difference matters: an empty choice must not fall back to picking
      // three cameras the user just unticked.
      final viewModel = DashboardCamerasViewModel(
        _FakeRepository(cameras: [_camera(1), _camera(2)]),
      );
      await viewModel.load();
      await viewModel.select(const []);
      expect(viewModel.isVisible, isFalse);
      expect(viewModel.hasExplicitSelection, isTrue);
    });

    test('resetting hands the choice back to the dashboard', () async {
      final viewModel = DashboardCamerasViewModel(
        _FakeRepository(cameras: [_camera(1), _camera(2)]),
      );
      await viewModel.load();
      await viewModel.select(const []);
      await viewModel.resetSelection();
      expect(viewModel.hasExplicitSelection, isFalse);
      expect(viewModel.isVisible, isTrue);
    });

    test('the choice survives a restart', () async {
      final repository = _FakeRepository(
        cameras: [_camera(1), _camera(2), _camera(3)],
      );
      final first = DashboardCamerasViewModel(repository);
      await first.load();
      await first.select([2]);

      final second = DashboardCamerasViewModel(repository);
      await second.load();
      expect(second.visibleCameras.single.id, 2);
    });

    test(
      'a camera that has since gone drops out instead of leaving a hole',
      () async {
        // Unplugged, disabled, or its recorder removed. The stored id must not
        // become a tile that streams nothing forever.
        final repository = _FakeRepository(
          cameras: [_camera(1), _camera(2), _camera(3)],
        );
        final first = DashboardCamerasViewModel(repository);
        await first.load();
        await first.select([2, 9]);

        final second = DashboardCamerasViewModel(
          _FakeRepository(cameras: [_camera(1), _camera(3)]),
        );
        await second.load();
        expect(second.visibleCameras, isEmpty);
      },
    );
  });

  group('what it costs to leave open', () {
    test('asks for stills, not a transcoded stream', () async {
      // The whole design: a dashboard left open all day must not hold an
      // ffmpeg pipeline per camera open on the shop's mini-PC.
      final repository = _FakeRepository(cameras: [_camera(1)]);
      final viewModel = DashboardCamerasViewModel(repository);
      await viewModel.load();
      viewModel.frames(viewModel.visibleCameras.single, tileWidth: 480);

      final request = repository.frameRequests.single;
      expect(request['smooth'], isFalse);
      expect(request['fps'], DashboardCamerasViewModel.framesPerSecond);
      expect(request['fps'], lessThanOrEqualTo(4));
      // The tile's own width, so the server scales the JPEG down to it.
      expect(request['width'], 480);
    });

    test('and says so on the wire, not by omission', () async {
      // The bug this pins: the client used to send `smooth` only when true, and
      // the server reads an *absent* smooth as "yes, use the RTSP pipeline" —
      // so asking for the cheap path silently got the expensive one.
      Uri? requested;
      final session = PosApiSession(
        client: MockClient((request) async {
          requested = request.url;
          return http.Response('', 200);
        }),
        baseUrl: 'http://shop.local:8000/api/',
      );
      final client = SurveillanceApiClient(session);
      await client
          .liveFrames(7, fps: 2, smooth: false)
          .toList()
          .catchError((_) => <CameraFrame>[]);

      expect(requested, isNotNull);
      expect(requested!.queryParameters['smooth'], 'false');
      expect(requested!.queryParameters['fps'], '2');
    });

    test('a thumbnail is fetched once and remembered', () async {
      final viewModel = DashboardCamerasViewModel(
        _FakeRepository(cameras: [_camera(1)]),
      );
      await viewModel.load();
      final camera = viewModel.visibleCameras.single;
      final first = await viewModel.thumbnail(camera);
      final second = await viewModel.thumbnail(camera);
      expect(first, isNotNull);
      expect(identical(first, second), isTrue);
    });
  });
}
