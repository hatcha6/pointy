// Dev-only preview harness for the camera (DVR/NVR) surfaces.
//
// Renders the camera wall, the playback screen, the settings page and the
// invoice footage panel with fake repositories — no backend, no DVR, no auth.
//
// Two frame sources, and the difference matters:
//
// * `source=synthetic` (default) paints a moving picture in-process. It proves
//   the player, the clock, the frame-drop path and the layout, and it needs
//   nothing running. It cannot prove anything about *decoding*, because the
//   frames are PNGs this file drew — they have no quantization tables, so no
//   JPEG framing question is ever asked.
// * `source=rig` serves **real video** from `tools/camera-rig`: frames encoded
//   by ffmpeg, carrying a recorder's quantization table — the one holding
//   `FF D9` that painted every tile grey in the field. That is the source to
//   use before believing the player works.
//
//   docker compose -f tools/camera-rig/docker-compose.yml up -d --build
//   flutter run -d web-server --web-port 8080 -t lib/dev/cameras_preview.dart
//   open 'http://localhost:8080/?screen=grey-pixels'
//
// Screens: board | wall | wall-single | wall-empty | playback | live-player
//          | settings | invoice | grey-pixels
// Params:  source=synthetic|rig|rig-clean|rig-broken   rig=<base url>
//
// See AGENTS.md ("UI preview harness"). Not part of the shipping app.
import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/camera.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/repositories/surveillance_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/data/services/surveillance_api_client.dart';
import 'package:pointy_frontend/src/features/cameras/view_models/camera_player_view_model.dart';
import 'package:pointy_frontend/src/features/cameras/view_models/camera_settings_view_model.dart';
import 'package:pointy_frontend/src/features/cameras/view_models/camera_wall_view_model.dart';
import 'package:pointy_frontend/src/features/cameras/views/camera_player_screen.dart';
import 'package:pointy_frontend/src/data/services/recorder_discovery.dart';
import 'package:pointy_frontend/src/features/cameras/views/camera_settings_page.dart';
import 'package:pointy_frontend/src/features/cameras/views/cameras_screen.dart';
import 'package:pointy_frontend/src/features/dashboard/view_models/dashboard_cameras_view_model.dart';
import 'package:pointy_frontend/src/features/dashboard/views/dashboard_cameras_band.dart';
import 'package:pointy_frontend/src/features/cameras/widgets/invoice_footage_section.dart';
import 'package:pointy_frontend/src/features/cameras/widgets/mjpeg_view.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/navigation/app_navigation.dart';
import 'package:pointy_frontend/src/shared/components/components.dart';
import 'package:pointy_frontend/src/shared/responsive/responsive.dart';
import 'package:pointy_frontend/src/shared/shell/shell.dart';

void main() => runApp(const _PreviewApp());

class _PreviewApp extends StatelessWidget {
  const _PreviewApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      locale: const Locale('ar'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: PointyTheme.light(),
      builder: (context, child) => PointyNavigationRailScope(
        isActive: false,
        controller: PointyNavigationRailController(),
        child: child ?? const SizedBox.shrink(),
      ),
      home: const _PreviewRouter(),
    );
  }
}

String _selectedScreen() => _param('screen') ?? 'wall';

String? _param(String name) {
  final uri = Uri.base;
  final direct = uri.queryParameters[name];
  if (direct != null) {
    return direct;
  }
  final fragment = uri.fragment;
  final parsed = Uri.tryParse(
    fragment.startsWith('/') ? fragment.substring(1) : fragment,
  );
  return parsed?.queryParameters[name];
}

/// Where `tools/camera-rig` is listening. Override with `&rig=http://host:port`
/// when the rig runs somewhere other than this machine.
String get _rigBase => _param('rig') ?? 'http://localhost:8090';

/// Which feed the fake repository hands to the player.
///
/// `rig` is the trapped one on purpose: the whole reason to point the harness
/// at real video is to see the frame that used to break, so that is what you
/// get unless you ask for the clean one.
String get _frameSource => _param('source') ?? 'synthetic';

class _PreviewRouter extends StatelessWidget {
  const _PreviewRouter();

  @override
  Widget build(BuildContext context) {
    switch (_selectedScreen()) {
      case 'board':
        return const _DesignBoard();
      case 'wall-single':
        return _wall(cameraCount: 1);
      case 'wall-empty':
        return _wall(cameraCount: 0);
      case 'playback':
        return _playback();
      case 'live-player':
        return _playback(mode: CameraPlayerMode.live);
      case 'settings':
        return _settings();
      case 'dashboard-band':
        return _dashboardBand();
      case 'recorder-form':
        return _recorderForm();
      case 'recorder-form-empty':
        return _recorderForm(found: false);
      case 'invoice':
        return _invoice();
      case 'grey-pixels':
        return const _GreyPixelsBoard();
      case 'wall':
      default:
        return _wall();
    }
  }
}

// ---------------------------------------------------------------------------
// Surfaces
// ---------------------------------------------------------------------------
Widget _wall({int cameraCount = 6}) {
  final repository = _FakeSurveillanceRepository(cameraCount: cameraCount);
  return CamerasScreen(
    viewModel: CameraWallViewModel(repository),
    repository: repository,
    capabilities: _capabilities,
    navigation: const _FakeNavigation(),
    onOpenSettings: () {},
  );
}

Widget _playback({CameraPlayerMode mode = CameraPlayerMode.playback}) {
  final repository = _FakeSurveillanceRepository();
  return CameraPlayerScreen(
    viewModel: CameraPlayerViewModel(
      repository,
      camera: _fakeCamera(1),
      mode: mode,
      start: DateTime.now().subtract(const Duration(minutes: 10)),
      status: const SurveillanceStatus(
        configured: true,
        playbackAvailable: true,
        exportAvailable: true,
        variableSpeedAvailable: true,
        maxLiveFps: 30,
        maxPlaybackFps: 30,
        smoothLiveAvailable: true,
      ),
    ),
  );
}

/// The dashboard band, in the company it keeps: a headline above it and a card
/// below, so its weight on the page can actually be judged.
Widget _dashboardBand() {
  final viewModel = DashboardCamerasViewModel(_FakeSurveillanceRepository());
  return Builder(
    builder: (context) {
      final spacing = AdaptiveSpacing.of(context);
      return PointyScaffold(
        appBar: PointyAppBar(title: const Text('لوحة المعلومات')),
        body: SingleChildScrollView(
          padding: spacing.pagePadding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const _PreviewHeadline(),
              SizedBox(height: spacing.lg),
              DashboardCamerasBand(
                viewModel: viewModel,
                onOpenCamera: (_) {},
                onOpenWall: () {},
              ),
              SizedBox(height: spacing.lg),
              const PointyDetailSection(
                title: 'أكثر المنتجات مبيعاً',
                icon: Icons.trending_up,
                child: SizedBox(height: 120),
              ),
            ],
          ),
        ),
      );
    },
  );
}

class _PreviewHeadline extends StatelessWidget {
  const _PreviewHeadline();

  @override
  Widget build(BuildContext context) {
    return const PointyDetailSection(
      title: 'مبيعات اليوم',
      icon: Icons.payments_outlined,
      child: SizedBox(height: 90),
    );
  }
}

Widget _settings() {
  return CameraSettingsPage(
    viewModel: _settingsViewModel(),
    enableSurveillance: true,
    onToggleEnabled: (_) async {},
  );
}

Widget _recorderForm({bool found = true}) {
  return RecorderFormPage(
    viewModel: _settingsViewModel(found: found),
    initial: const RecorderDraft(),
  );
}

CameraSettingsViewModel _settingsViewModel({bool found = true}) {
  return CameraSettingsViewModel(
    _FakeSurveillanceRepository(),
    // Stands in for the LAN sweep, which finds nothing in a browser.
    sweep: () async {
      await Future<void>.delayed(const Duration(milliseconds: 700));
      if (!found) {
        return const [];
      }
      return const [
        DiscoveredRecorder(
          host: '192.168.1.64',
          port: 80,
          brand: RecorderBrand.hikvision,
          model: 'DS-7216HGHI-K1',
        ),
        DiscoveredRecorder(
          host: '192.168.1.108',
          port: 80,
          brand: RecorderBrand.dahua,
          model: '7K03A1BPAZ1E2F3',
        ),
        DiscoveredRecorder(host: '192.168.1.201', port: 8080),
      ];
    },
  );
}

Widget _invoice() {
  final l10nHost = Builder(
    builder: (context) => Scaffold(
      appBar: AppBar(title: const Text('فاتورة #1042')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          InvoiceFootageSection(
            repository: _FakeSurveillanceRepository(),
            orderId: 1042,
            capabilities: _capabilities,
          ),
        ],
      ),
    ),
  );
  return l10nHost;
}

// ---------------------------------------------------------------------------
// Design board
// ---------------------------------------------------------------------------
class _DesignBoard extends StatelessWidget {
  const _DesignBoard();

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xFFEFEFEF),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Wrap(
          spacing: 24,
          runSpacing: 24,
          children: [
            _frame('جدار الكاميرات', 1000, 640, _wall()),
            _frame('كاميرا واحدة', 520, 640, _wall(cameraCount: 1)),
            _frame('لا توجد كاميرات', 520, 640, _wall(cameraCount: 0)),
            _frame('مراجعة التسجيلات', 1000, 700, _playback()),
            _frame(
              'مشغّل مباشر',
              1000,
              620,
              _playback(mode: CameraPlayerMode.live),
            ),
            _frame('هاتف — الجدار', 390, 780, _wall()),
            _frame('هاتف — المشغّل', 390, 780, _playback()),
            _frame('لوحة المعلومات', 1100, 700, _dashboardBand()),
            _frame('إعدادات الكاميرات', 640, 900, _settings()),
            _frame('إضافة جهاز — بحث الشبكة', 640, 900, _recorderForm()),
            _frame('لقطة الفاتورة', 640, 640, _invoice()),
          ],
        ),
      ),
    );
  }

  Widget _frame(String label, double width, double height, Widget child) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text(
            label,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
          ),
        ),
        SizedBox(
          width: width,
          height: height,
          child: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                size: Size(width, height),
                padding: EdgeInsets.zero,
                viewInsets: EdgeInsets.zero,
              ),
              child: ClipRect(child: child),
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------
final _capabilities = AuthorizationCapabilities.forUser(
  const PosUser(
    id: 1,
    username: 'preview',
    firstName: '',
    lastName: '',
    displayName: 'معاينة',
    email: '',
    role: UserRole.manager,
    isActive: true,
    surveillanceEnabled: true,
  ),
);

Camera _fakeCamera(int id) {
  const names = ['الصندوق', 'الباب الأمامي', 'المخزن', 'الرف الجانبي'];
  return Camera(
    id: id,
    recorderId: 1,
    channel: id,
    name: names[(id - 1) % names.length],
    deviceName: 'CAM$id',
    displayName: names[(id - 1) % names.length],
    isEnabled: true,
    displayOrder: id,
    coversCheckout: id == 1,
    liveQuality: CameraQuality.sub,
    playbackQuality: CameraQuality.main,
    status: id == 4 ? CameraStatus.offline : CameraStatus.online,
  );
}

class _FakeNavigation implements AppNavigation {
  const _FakeNavigation();

  @override
  AuthorizationCapabilities get capabilities => _capabilities;

  @override
  PosUser get currentUser => _capabilities.allows(AppCapability.accessPos)
      ? const PosUser(
          id: 1,
          username: 'preview',
          firstName: '',
          lastName: '',
          displayName: 'معاينة',
          email: '',
          role: UserRole.manager,
          isActive: true,
        )
      : throw StateError('unreachable');

  @override
  void navigateTo(
    BuildContext context,
    AppNavigationDestination destination, {
    AppNavigationDestination? from,
  }) {}

  @override
  void openAiChat(
    BuildContext context, {
    String? seedPrompt,
    bool autoSend = false,
    AppNavigationDestination? from,
  }) {}

  @override
  void logout(BuildContext context) {}
}

class _FakeSurveillanceRepository extends SurveillanceRepository {
  _FakeSurveillanceRepository({this.cameraCount = 6}) : super(PosApiService());

  final int cameraCount;

  List<Camera> get _cameras =>
      List.generate(cameraCount, (index) => _fakeCamera(index + 1));

  @override
  Future<Result<SurveillanceStatus>> loadStatus() async {
    return Ok(
      SurveillanceStatus(
        configured: cameraCount > 0,
        recorderCount: cameraCount > 0 ? 1 : 0,
        cameraCount: cameraCount,
        checkoutCameraCount: cameraCount > 0 ? 1 : 0,
        playbackAvailable: true,
        exportAvailable: true,
        variableSpeedAvailable: true,
        ffmpegVersion: '6.1',
        maxLiveFps: 30,
        maxPlaybackFps: 30,
        smoothLiveAvailable: true,
      ),
    );
  }

  @override
  Future<Result<List<Camera>>> loadCameras({bool enabledOnly = false}) async {
    return Ok(_cameras);
  }

  @override
  Future<Result<List<Recorder>>> loadRecorders() async {
    if (cameraCount == 0) {
      return const Ok([]);
    }
    return Ok([
      Recorder(
        id: 1,
        name: 'جهاز المحل',
        brand: RecorderBrand.auto,
        detectedBrand: 'hikvision',
        host: '192.168.1.64',
        port: 80,
        rtspPort: 554,
        username: 'admin',
        hasPassword: true,
        useHttps: false,
        isEnabled: true,
        status: RecorderStatus.ok,
        modelName: 'DS-7216HGHI-K1',
        firmware: 'V4.30.005',
        channelCount: cameraCount,
        clockOffsetMinutes: 120,
        clockOffsetIsMeasured: true,
        cameras: _cameras,
      ),
    ]);
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
    return Ok(
      _fakeCamera(id).copyWith(
        name: name,
        isEnabled: isEnabled,
        coversCheckout: coversCheckout,
        liveQuality: liveQuality,
        playbackQuality: playbackQuality,
      ),
    );
  }

  @override
  Future<Result<InvoiceFootage>> loadInvoiceFootage(int orderId) async {
    final now = DateTime.now();
    return Ok(
      InvoiceFootage(
        orderId: orderId,
        receiptNumber: '1042',
        occurredAt: now.subtract(const Duration(hours: 2)),
        start: now.subtract(const Duration(hours: 2, seconds: 20)),
        end: now.subtract(const Duration(hours: 1, minutes: 59, seconds: 20)),
        playbackAvailable: true,
        cameras: _cameras.take(2).toList(),
      ),
    );
  }

  @override
  Stream<CameraFrame> liveFrames(
    int cameraId, {
    int fps = 4,
    CameraQuality? quality,
    bool smooth = false,
    int width = 0,
  }) {
    return _framesFor(cameraId, fps: fps);
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
    return _framesFor(cameraId, fps: fps, anchor: start, speed: speed);
  }
}

/// The feed named by `?source=`, for whichever surface asked.
Stream<CameraFrame> _framesFor(
  int cameraId, {
  int fps = 4,
  DateTime? anchor,
  double speed = 1.0,
}) {
  switch (_frameSource) {
    case 'rig':
      return _rigFrames('trap', fps: fps, anchor: anchor, speed: speed);
    case 'rig-clean':
      return _rigFrames('clean', fps: fps, anchor: anchor, speed: speed);
    case 'rig-broken':
      return _rigFrames('broken', fps: fps, anchor: anchor, speed: speed);
    default:
      return _syntheticFrames(cameraId, fps: fps, anchor: anchor, speed: speed);
  }
}

/// Real frames, off the rig, through the widget's real decoder.
///
/// Stills on a timer rather than a held MJPEG socket, because that is what the
/// shipping client does on web too — `SurveillanceApiClient._frames` falls back
/// to polling there, since a browser HTTP client buffers a streaming response
/// until it ends and a live tile would otherwise show nothing, ever. So this is
/// not a shortcut around the real path; on this platform it *is* the real path.
Stream<CameraFrame> _rigFrames(
  String variant, {
  int fps = 4,
  DateTime? anchor,
  double speed = 1.0,
}) async* {
  final interval = Duration(milliseconds: (1000 / fps).round());
  final client = http.Client();
  var index = 0;
  try {
    while (true) {
      final started = DateTime.now();
      http.Response? response;
      try {
        response = await client.get(
          Uri.parse('$_rigBase/$variant/snapshot.jpg?i=$index'),
        );
      } catch (_) {
        // The rig is not up. Say so through the player's own error path rather
        // than throwing, so the harness shows the widget's failure state —
        // which is a thing worth previewing too.
        throw StateError(
          'camera rig unreachable at $_rigBase — '
          'docker compose -f tools/camera-rig/docker-compose.yml up -d',
        );
      }
      if (response.statusCode == 200) {
        yield CameraFrame(
          bytes: response.bodyBytes,
          capturedAt: anchor == null
              ? DateTime.now()
              : anchor.add(
                  Duration(milliseconds: (index * 1000 * speed / fps).round()),
                ),
        );
      }
      index++;
      final elapsed = DateTime.now().difference(started);
      final remaining = interval - elapsed;
      if (remaining > Duration.zero) {
        await Future<void>.delayed(remaining);
      }
    }
  } finally {
    client.close();
  }
}

/// A moving picture with no camera behind it.
///
/// Enough to prove layout, the clock, frame-drop and teardown. **Not** enough
/// to prove decoding: these frames are PNGs (see `_paintFrame`), and every
/// interesting way a real frame goes wrong is a JPEG question — a quantization
/// table that contains a false end-of-image, a truncated scan, a restart marker
/// mid-entropy. A PNG has none of those, so a player that would paint grey on a
/// real camera looks perfect here. Use `?source=rig` for that.
Stream<CameraFrame> _syntheticFrames(
  int seed, {
  int fps = 4,
  DateTime? anchor,
  double speed = 1.0,
}) async* {
  final interval = Duration(milliseconds: (1000 / fps).round());
  var index = 0;
  while (true) {
    final bytes = await _paintFrame(seed, index);
    yield CameraFrame(
      bytes: bytes,
      capturedAt: anchor == null
          ? DateTime.now()
          : anchor.add(
              Duration(milliseconds: (index * 1000 * speed / fps).round()),
            ),
    );
    index++;
    await Future<void>.delayed(interval);
  }
}

Future<Uint8List> _paintFrame(int seed, int index) async {
  const width = 640.0;
  const height = 360.0;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder, const Rect.fromLTWH(0, 0, width, height));
  final hue = (seed * 47) % 360;
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, width, height),
    Paint()..color = HSVColor.fromAHSV(1, hue.toDouble(), 0.25, 0.30).toColor(),
  );
  // A shape that moves, so a frozen preview is obvious at a glance.
  final angle = index * 0.18;
  canvas.drawCircle(
    Offset(
      width / 2 + math.cos(angle) * 140,
      height / 2 + math.sin(angle) * 70,
    ),
    28,
    Paint()..color = HSVColor.fromAHSV(1, hue.toDouble(), 0.5, 0.9).toColor(),
  );
  final painter = TextPainter(
    text: TextSpan(
      text: 'CAM $seed · ${index.toString().padLeft(4, '0')}',
      style: const TextStyle(color: Colors.white70, fontSize: 20),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  painter.paint(canvas, const Offset(16, 16));

  final picture = recorder.endRecording();
  final image = await picture.toImage(width.toInt(), height.toInt());
  picture.dispose();
  // PNG rather than JPEG: `toByteData` has no JPEG encoder. Both go through
  // `instantiateImageCodec`, so the *plumbing* is unchanged — but the bytes are
  // not, and JPEG framing is exactly where this feature has actually broken.
  // That gap is what `tools/camera-rig` exists to close; see the file header.
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

// ---------------------------------------------------------------------------
// The grey pixels, on screen
// ---------------------------------------------------------------------------

/// Three feeds off the rig, so "grey pixels" stops being a phrase in a commit.
///
/// **clean** is a frame with ffmpeg's own quantization table. **recorder table**
/// is the same picture carrying the table a DVR sent — the one holding `FF D9`
/// — and it must look identical: that is the fix working, in the client, on the
/// bytes that broke it. **cut at the false marker** is what the old demuxer
/// handed the decoder, and it is what a shop phoned about.
///
/// Pinned LTR, unlike the rest of the app: this is a before/after comparison
/// read in the order the labels are written, and mirroring it puts "clean" on
/// the right of the sentence describing it as the left.
///
///   open 'http://localhost:8080/?screen=grey-pixels'
class _GreyPixelsBoard extends StatelessWidget {
  const _GreyPixelsBoard();

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Scaffold(
        backgroundColor: const Color(0xFF14110E),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Real frames from tools/camera-rig',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'If the middle tile matches the left, the demuxer is intact. '
                  'The right tile is the bug.',
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.6)),
                ),
                const SizedBox(height: 16),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final tiles = [
                        const _RigTile(
                          variant: 'clean',
                          label: 'clean',
                          caption: 'ffmpeg’s own quantization table',
                        ),
                        const _RigTile(
                          variant: 'trap',
                          label: 'recorder table (FF D9)',
                          caption: 'must be identical to clean',
                        ),
                        const _RigTile(
                          variant: 'broken',
                          label: 'cut at the false marker',
                          caption: 'what the shop saw',
                        ),
                      ];
                      // One column on a phone, a row anywhere there is width.
                      if (constraints.maxWidth < 760) {
                        return ListView.separated(
                          itemCount: tiles.length,
                          separatorBuilder: (_, _) =>
                              const SizedBox(height: 12),
                          itemBuilder: (context, index) =>
                              SizedBox(height: 240, child: tiles[index]),
                        );
                      }
                      return Row(
                        children: [
                          for (var i = 0; i < tiles.length; i++) ...[
                            if (i > 0) const SizedBox(width: 12),
                            Expanded(child: tiles[i]),
                          ],
                        ],
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RigTile extends StatelessWidget {
  const _RigTile({
    required this.variant,
    required this.label,
    required this.caption,
  });

  final String variant;
  final String label;
  final String caption;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: ColoredBox(
              color: const Color(0xFF231F1A),
              child: MjpegView(
                // A factory, not a stream: MjpegView calls this again on every
                // reconnect.
                frames: () => _rigFrames(variant, fps: 8),
                fit: BoxFit.contain,
                // An empty tile and a broken tile look identical without this.
                // The truncated frame never decodes, so MjpegView never gets a
                // first frame and would otherwise just sit here looking like a
                // layout mistake.
                placeholder: const Center(
                  child: Padding(
                    padding: EdgeInsets.all(12),
                    child: Text(
                      'no frame has decoded yet',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Color(0xFF7A736A), fontSize: 12),
                    ),
                  ),
                ),
                // The rig being down, and a frame that will not decode, are
                // different failures and the harness should show which.
                errorBuilder: (context, error, retry) => Center(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '$error',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Color(0xFFE5A3A3),
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: 8),
                        TextButton(
                          onPressed: retry,
                          child: const Text('retry'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w600,
          ),
        ),
        Text(
          caption,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.55),
            fontSize: 12,
          ),
        ),
      ],
    );
  }
}
