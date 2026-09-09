import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../data/models/camera.dart';
import '../../../data/repositories/surveillance_repository.dart';
import '../../../shared/app_navigation_drawer.dart';
import '../../../shared/components/components.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../view_models/camera_player_view_model.dart';
import '../view_models/camera_wall_view_model.dart';
import '../widgets/camera_tile.dart';
import 'camera_player_screen.dart';

/// The camera wall: every enabled channel, live, in a grid that scrolls.
///
/// Scrolls rather than paginates. A wall is a place you glance at, and page
/// numbers make you remember which page the back door was on; with a scroll
/// the shop's cameras are simply one list in the order the shop put them in.
///
/// Tiles cost nothing while they are off screen. The grid is built with no
/// cache extent, so Flutter disposes a tile the moment it leaves the viewport,
/// which closes its socket, which tells the server to stop pulling that camera
/// from the recorder. Scrolling back is cheap because the server's producer
/// lingers for a few seconds after its last viewer.
class CamerasScreen extends StatefulWidget {
  const CamerasScreen({
    super.key,
    required this.viewModel,
    required this.repository,
    required this.capabilities,
    required this.navigation,
    this.onOpenSettings,
  });

  final CameraWallViewModel viewModel;

  /// Handed to the player, which owns its own lifecycle on its own route.
  final SurveillanceRepository repository;
  final AuthorizationCapabilities capabilities;
  final AppNavigation navigation;
  final VoidCallback? onOpenSettings;

  @override
  State<CamerasScreen> createState() => _CamerasScreenState();
}

class _CamerasScreenState extends State<CamerasScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(widget.viewModel.load());
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.viewModel,
      builder: (context, _) {
        final l10n = AppLocalizations.of(context)!;
        final viewModel = widget.viewModel;

        return PointyScaffold(
          drawer: AppNavigationDrawer(
            selectedDestination: AppNavigationDestination.cameras,
            navigation: widget.navigation,
          ),
          appBar: AppBar(
            leading: const PointyNavigationMenuButton(),
            title: Text(l10n.camerasTitle),
            actions: [
              IconButton(
                tooltip: viewModel.isPaused
                    ? l10n.camerasResumeAllTooltip
                    : l10n.camerasPauseAllTooltip,
                onPressed: viewModel.isEmpty ? null : viewModel.togglePaused,
                icon: Icon(viewModel.isPaused ? Icons.play_arrow : Icons.pause),
              ),
              if (!viewModel.isEmpty) _TileSizeMenu(viewModel: viewModel),
              IconButton(
                tooltip: l10n.camerasRefreshTooltip,
                onPressed: viewModel.isLoading
                    ? null
                    : () => unawaited(viewModel.load()),
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          body: _body(context, l10n),
        );
      },
    );
  }

  Widget _body(BuildContext context, AppLocalizations l10n) {
    final viewModel = widget.viewModel;
    if (viewModel.isLoading && viewModel.isEmpty) {
      return const PointyLoadingArea();
    }
    if (viewModel.hasLoadError && viewModel.isEmpty) {
      return PointyErrorState(
        title: l10n.camerasLoadErrorTitle,
        action: FilledButton.icon(
          onPressed: () => unawaited(viewModel.load()),
          icon: const Icon(Icons.refresh),
          label: Text(l10n.cameraRetryAction),
        ),
      );
    }
    if (viewModel.isEmpty) {
      return PointyEmptyState(
        icon: Icons.videocam_off_outlined,
        title: l10n.camerasEmptyTitle,
        message: l10n.camerasEmptyBody,
        action:
            widget.capabilities.canManageCameras &&
                widget.onOpenSettings != null
            ? FilledButton.icon(
                onPressed: widget.onOpenSettings,
                icon: const Icon(Icons.settings_outlined),
                label: Text(l10n.camerasOpenSettingsButton),
              )
            : null,
      );
    }

    final spacing = AdaptiveSpacing.of(context);
    return Column(
      children: [
        if (viewModel.isPaused)
          PointyInlineMessage(message: l10n.camerasPausedBanner),
        Expanded(
          child: RefreshIndicator(
            onRefresh: viewModel.load,
            child: _Wall(
              viewModel: viewModel,
              padding: spacing.pagePadding,
              onOpen: _openPlayer,
              onRename: _rename,
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _rename(Camera camera) async {
    final l10n = AppLocalizations.of(context)!;
    if (!widget.capabilities.canManageCameras) {
      return;
    }
    final name = await showDialog<String>(
      context: context,
      builder: (_) => PointyTextEntryDialog(
        title: l10n.cameraRenameTitle,
        icon: Icons.videocam_outlined,
        fieldLabel: l10n.cameraRenameHint,
        subject: camera.deviceName.isNotEmpty ? camera.deviceName : null,
        initialValue: camera.name,
        confirmLabel: l10n.cameraRenameAction,
      ),
    );
    if (name == null || !mounted) {
      return;
    }
    await widget.viewModel.rename(camera, name);
  }

  /// Opening a camera is the same screen whether you want to watch it now or
  /// look at what it saw — the player switches between the two in place.
  void _openPlayer(Camera camera) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CameraPlayerScreen(
          viewModel: CameraPlayerViewModel(
            widget.repository,
            camera: camera,
            mode: CameraPlayerMode.live,
            status: widget.viewModel.status,
          ),
        ),
      ),
    );
  }
}

class _Wall extends StatelessWidget {
  const _Wall({
    required this.viewModel,
    required this.padding,
    required this.onOpen,
    required this.onRename,
  });

  final CameraWallViewModel viewModel;
  final EdgeInsetsGeometry padding;
  final ValueChanged<Camera> onOpen;
  final ValueChanged<Camera> onRename;

  static const double _gap = 8;

  @override
  Widget build(BuildContext context) {
    final cameras = viewModel.cameras;
    return LayoutBuilder(
      builder: (context, constraints) {
        final resolved = padding.resolve(Directionality.of(context));
        final available = constraints.maxWidth - resolved.horizontal;
        final columns = viewModel.layout.columnsFor(available);
        final tileWidth = (available - _gap * (columns - 1)) / columns;
        final ratio = MediaQuery.devicePixelRatioOf(context);

        final tileHeight = tileWidth * 9 / 16;

        return GridView.builder(
          padding: padding,
          // One row of headroom, and no more.
          //
          // This was zero, on the reasoning that a tile kept alive off-screen
          // is a camera still being pulled for a picture nobody can see. True,
          // but at zero Flutter destroys a tile the instant it is one pixel
          // past the edge — so nudging the wall tore down the stream and
          // scrolling back paid a full ffmpeg cold start against the DVR. In
          // the field that read as the feature being broken (2026-09-08).
          //
          // A single row is the smallest thing that makes ordinary scrolling
          // free: it holds the tiles a person is *about* to look at and the one
          // they just glanced away from, while a wall scrolled properly away
          // still stops pulling. The rest of the fix is on the server — the
          // producer lingers, and a reattach paints the last frame it held
          // rather than a blank square.
          cacheExtent: tileHeight + _gap,
          physics: const AlwaysScrollableScrollPhysics(),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: _gap,
            crossAxisSpacing: _gap,
            childAspectRatio: 16 / 9,
          ),
          itemCount: cameras.length,
          itemBuilder: (context, index) {
            final camera = cameras[index];
            return CameraTile(
              key: ValueKey('camera-${camera.id}'),
              camera: camera,
              isActive: !viewModel.isPaused,
              // Phones get no per-tile buttons: they would cover the picture,
              // and a tap already opens the camera where they fit properly.
              compact: columns == 1 && tileWidth < 420,
              frames: () => viewModel.liveFrames(
                camera,
                tileWidth: (tileWidth * ratio).round(),
              ),
              onOpen: () => onOpen(camera),
              onRename: () => onRename(camera),
              onOpenPlayback: () => onOpen(camera),
            );
          },
        );
      },
    );
  }
}

class _TileSizeMenu extends StatelessWidget {
  const _TileSizeMenu({required this.viewModel});

  final CameraWallViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return PopupMenuButton<CameraWallLayout>(
      tooltip: l10n.camerasTileSizeTooltip,
      icon: const Icon(Icons.grid_view_outlined),
      initialValue: viewModel.layout,
      onSelected: viewModel.setLayout,
      itemBuilder: (context) => [
        PopupMenuItem(
          value: CameraWallLayout.large,
          child: Text(l10n.camerasLayoutLarge),
        ),
        PopupMenuItem(
          value: CameraWallLayout.medium,
          child: Text(l10n.camerasLayoutMedium),
        ),
        PopupMenuItem(
          value: CameraWallLayout.small,
          child: Text(l10n.camerasLayoutSmall),
        ),
      ],
    );
  }
}
