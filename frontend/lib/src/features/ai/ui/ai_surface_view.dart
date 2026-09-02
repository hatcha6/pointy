import 'package:flutter/material.dart';
import 'package:genui/genui.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../data/models/ai_chat.dart';
import '../../../shared/components/components.dart';
import 'ai_surface_host.dart';

/// Renders one generated surface inside an assistant bubble.
///
/// Isolated behind a [RepaintBoundary] and keyed by surface id: a surface is
/// immutable once it arrives, so streamed tokens elsewhere in the turn never
/// repaint it.
class AiSurfaceView extends StatelessWidget {
  const AiSurfaceView({super.key, required this.host, required this.surface});

  final AiSurfaceHost host;
  final AiUiSurface surface;

  @override
  Widget build(BuildContext context) {
    if (!host.isLive(surface.surfaceId)) {
      return const SizedBox.shrink();
    }
    return RepaintBoundary(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Surface(
          surfaceContext: host.contextFor(surface.surfaceId),
          actionDelegate: AiSurfaceDelegate(host),
          defaultBuilder: (context) => const SizedBox.shrink(),
        ),
      ),
    );
  }
}

/// Shown when a surface cannot be rendered at all.
class AiSurfaceError extends StatelessWidget {
  const AiSurfaceError({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return PointyInlineMessage.error(message: l10n.aiUiSurfaceFailed);
  }
}
