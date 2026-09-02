import 'dart:async';

import 'package:a2ui_core/a2ui_core.dart' as core;
import 'package:flutter/material.dart';
import 'package:genui/genui.dart';

import '../../../data/models/ai_chat.dart';
import 'ai_surface_action.dart';
import 'ai_ui_support.dart';
import 'pointy_ai_catalog.dart';

/// Owns the generative-UI engine for one conversation.
///
/// This is the only place the app touches the genui package. Everything above
/// it speaks in [AiUiSurface] and [AiSurfaceAction], so swapping the rendering
/// engine would not reach the view models, the chat screen or the catalog's
/// callers.
class AiSurfaceHost {
  AiSurfaceHost({Catalog? catalog})
    : _controller = SurfaceController(
        catalogs: [catalog ?? PointyAiCatalog.build()],
      );

  final SurfaceController _controller;
  final StreamController<AiSurfaceAction> _actions =
      StreamController<AiSurfaceAction>.broadcast();
  final Set<String> _live = <String>{};

  /// Taps on any surface this host renders.
  Stream<AiSurfaceAction> get actions => _actions.stream;

  /// Whether [surfaceId] has been created and can be rendered.
  bool isLive(String surfaceId) => _live.contains(surfaceId);

  /// Applies one surface: creates it, then sends its components and data.
  ///
  /// Re-applying a surface id replaces it, which is what happens when a
  /// conversation is reloaded from history.
  void apply(AiUiSurface surface) {
    if (_live.contains(surface.surfaceId)) {
      _controller.handleMessage(
        core.DeleteSurfaceMessage(surfaceId: surface.surfaceId),
      );
      _live.remove(surface.surfaceId);
    }
    _controller.handleMessage(
      core.CreateSurfaceMessage(
        surfaceId: surface.surfaceId,
        catalogId: pointyAiCatalogId,
      ),
    );
    _live.add(surface.surfaceId);
    if (surface.data.isNotEmpty) {
      _controller.handleMessage(
        core.UpdateDataModelMessage(
          surfaceId: surface.surfaceId,
          value: surface.data,
        ),
      );
    }
    _controller.handleMessage(
      core.UpdateComponentsMessage(
        surfaceId: surface.surfaceId,
        components: surface.components,
      ),
    );
  }

  /// The rendering context for one surface, passed to [Surface].
  SurfaceContext contextFor(String surfaceId) =>
      _controller.contextFor(surfaceId);

  /// Reads the current data model of a surface, used when a form is submitted.
  Map<String, Object?> dataFor(String surfaceId) {
    final value = _controller
        .contextFor(surfaceId)
        .dataModel
        .getValue<Object>(DataPath.root);
    return value is Map ? value.cast<String, Object?>() : <String, Object?>{};
  }

  /// Drops every surface, e.g. when the user opens another conversation.
  void reset() {
    for (final surfaceId in _live.toList()) {
      _controller.handleMessage(
        core.DeleteSurfaceMessage(surfaceId: surfaceId),
      );
    }
    _live.clear();
  }

  /// Called by [AiSurfaceDelegate] when a catalog item dispatches an action.
  void emit(AiSurfaceAction action) {
    if (action.kind == AiSurfaceActionKind.unknown) return;
    if (!_actions.isClosed) _actions.add(action);
  }

  void dispose() {
    _actions.close();
    _controller.dispose();
  }
}

/// Intercepts catalog events before genui turns them into chat messages, so
/// Pointy routes them itself.
class AiSurfaceDelegate implements ActionDelegate {
  const AiSurfaceDelegate(this.host);

  final AiSurfaceHost host;

  @override
  bool handleEvent(
    BuildContext context,
    UiEvent event,
    SurfaceContext surfaceContext,
    Widget Function(SurfaceDefinition, Catalog, String, DataContext)
    buildWidget,
  ) {
    if (!event.isUserAction) return false;
    final action = UserActionEvent.fromMap(event.toMap());
    final parsed = AiSurfaceAction.parse(
      name: action.name,
      surfaceId: surfaceContext.surfaceId,
      context: action.context,
      data: action.name.startsWith('submit:')
          ? host.dataFor(surfaceContext.surfaceId)
          : const <String, Object?>{},
    );
    host.emit(parsed);
    // Handled here; never fall through to genui's own submit stream.
    return true;
  }
}
