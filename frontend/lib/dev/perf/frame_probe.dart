// Dev-only: per-frame cost probe for the frontend performance sweep.
//
// Two families of numbers, because the field problem was raster-bound jank
// on hardware we do not have on the desk:
//
// * Structural (hardware-independent, debug builds only — the hooks live
//   inside asserts): widgets rebuilt, render objects painted, the screen area
//   that was re-recorded, and the number of saveLayer-class layers in the
//   tree. These say *what the frame asked the GPU to do*, which is the same
//   on a Celeron as on an M-series.
// * Timing (profile builds): build and raster durations from
//   [FrameTiming], which say how long *this* machine took.
//
// Frames are attributed to the phase active when they were drawn.
import 'dart:developer' as developer;
import 'dart:ui' show FrameTiming, FramePhase, Rect;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

class FrameSample {
  FrameSample({required this.surface, required this.phase});

  final String surface;
  final String phase;
  int rebuilds = 0;
  int paints = 0;

  /// Sum of the bounds of every picture re-recorded this frame, in logical
  /// pixels squared, clipped to the window.
  double repaintArea = 0;

  /// Largest single re-recorded picture this frame.
  double largestRepaint = 0;

  /// How many pictures were re-recorded this frame. Unlike area and painted
  /// render objects, this cannot over-report: a picture is in this count only
  /// when the engine handed us a PictureLayer that did not exist last frame,
  /// which means its display list was rebuilt. A resting screen must be 0.
  int repaintPictures = 0;
  int layers = 0;
  int saveLayers = 0;
  Map<String, int> saveLayerKinds = const {};
  int? buildMicros;
  int? rasterMicros;
  int startMicros = 0;
}

class FrameProbe {
  FrameProbe();

  final List<FrameSample> samples = [];
  final Map<String, int> _rebuildsByWidget = {};
  final Map<String, int> _paintsByRenderObject = {};

  /// Rebuild histograms per phase key (surface/phase) — the diagnosis half of
  /// the report: *which* widgets rebuilt while the user was idle.
  final Map<String, Map<String, int>> rebuildHistograms = {};
  final Map<String, Map<String, int>> paintHistograms = {};

  String _surface = 'startup';
  String _phase = 'boot';
  int _phaseStartMicros = 0;
  bool _running = false;
  FrameSample? _open;
  Set<PictureLayer> _previousPictures = {};
  double _windowArea = 0;

  /// Frames drawn while a phase was active, keyed by surface/phase.
  Map<String, List<FrameSample>> get byPhase {
    final result = <String, List<FrameSample>>{};
    for (final sample in samples) {
      result
          .putIfAbsent('${sample.surface}/${sample.phase}', () => [])
          .add(sample);
    }
    return result;
  }

  bool get structuralMetricsAvailable => kDebugMode;

  void start() {
    if (_running) {
      return;
    }
    _running = true;
    _phaseStartMicros = developer.Timeline.now;
    if (kDebugMode) {
      debugProfileBuildsEnabled = true;
      debugProfilePaintsEnabled = true;
      debugOnRebuildDirtyWidget = _onRebuild;
      debugOnProfilePaint = _onPaint;
    }
    SchedulerBinding.instance.addPersistentFrameCallback(_onFrameDrawn);
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
  }

  void stop() {
    _running = false;
    if (kDebugMode) {
      debugOnRebuildDirtyWidget = null;
      debugOnProfilePaint = null;
      debugProfileBuildsEnabled = false;
      debugProfilePaintsEnabled = false;
    }
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    // Persistent frame callbacks cannot be removed; _running gates it.
  }

  void beginPhase(String surface, String phase) {
    _flushHistograms();
    _surface = surface;
    _phase = phase;
    _phaseStartMicros = developer.Timeline.now;
  }

  void _flushHistograms() {
    final key = '$_surface/$_phase';
    if (_rebuildsByWidget.isNotEmpty) {
      final target = rebuildHistograms.putIfAbsent(key, () => {});
      _rebuildsByWidget.forEach(
        (name, count) => target[name] = (target[name] ?? 0) + count,
      );
      _rebuildsByWidget.clear();
    }
    if (_paintsByRenderObject.isNotEmpty) {
      final target = paintHistograms.putIfAbsent(key, () => {});
      _paintsByRenderObject.forEach(
        (name, count) => target[name] = (target[name] ?? 0) + count,
      );
      _paintsByRenderObject.clear();
    }
  }

  FrameSample _current() {
    return _open ??= FrameSample(surface: _surface, phase: _phase)
      ..startMicros = developer.Timeline.now;
  }

  void _onRebuild(Element element, bool builtOnce) {
    if (!_running) {
      return;
    }
    final sample = _current();
    sample.rebuilds += 1;
    final name = element.widget.runtimeType.toString();
    _rebuildsByWidget[name] = (_rebuildsByWidget[name] ?? 0) + 1;
  }

  void _onPaint(RenderObject renderObject) {
    if (!_running) {
      return;
    }
    final sample = _current();
    sample.paints += 1;
    final name = renderObject.runtimeType.toString();
    _paintsByRenderObject[name] = (_paintsByRenderObject[name] ?? 0) + 1;
    if (renderObject.isRepaintBoundary && _phase.startsWith('scroll')) {
      final dc = renderObject.debugCreator;
      final chain = dc is DebugCreator ? dc.element.debugGetCreatorChain(6) : name;
      final key = '$_surface/$_phase :: $chain';
      debugBoundaryPaints[key] = (debugBoundaryPaints[key] ?? 0) + 1;
    }
  }

  /// Runs after the binding's own drawFrame (build → layout → paint →
  /// composite) in the same frame, so the counters hold exactly this frame.
  void _onFrameDrawn(Duration timeStamp) {
    if (!_running) {
      return;
    }
    final sample = _current();
    _open = null;
    if (kDebugMode) {
      _inspectLayers(sample);
    }
    samples.add(sample);
  }

  void _inspectLayers(FrameSample sample) {
    final views = RendererBinding.instance.renderViews;
    if (views.isEmpty) {
      return;
    }
    final view = views.first;
    final size = view.size;
    _windowArea = size.width * size.height;
    final window = Rect.fromLTWH(0, 0, size.width, size.height);
    final root = view.debugLayer;
    if (root == null) {
      return;
    }
    final pictures = <PictureLayer>{};
    var layers = 0;
    var saveLayers = 0;
    final kinds = <String, int>{};
    final repaintTarget = repaintHistograms.putIfAbsent(
      '$_surface/$_phase',
      () => {},
    );
    void visit(Layer layer) {
      layers += 1;
      if (layer is PictureLayer) {
        pictures.add(layer);
        if (!_previousPictures.contains(layer)) {
          final bounds = layer.canvasBounds.intersect(window);
          if (!bounds.isEmpty) {
            final area = bounds.width * bounds.height;
            sample.repaintArea += area;
            sample.repaintPictures += 1;
            if (area > sample.largestRepaint) {
              sample.largestRepaint = area;
            }
            final owner = _creatorOf(layer);
            repaintTarget[owner] = (repaintTarget[owner] ?? 0) + area;
          }
        }
      }
      String? kind;
      if (layer is OpacityLayer && (layer.alpha ?? 255) < 255) {
        kind = 'Opacity';
      } else if (layer is ShaderMaskLayer) {
        kind = 'ShaderMask';
      } else if (layer is BackdropFilterLayer) {
        kind = 'BackdropFilter';
      } else if (layer is ImageFilterLayer) {
        kind = 'ImageFilter';
      } else if (layer is ColorFilterLayer) {
        kind = 'ColorFilter';
      } else if (layer is ClipPathLayer) {
        kind = 'ClipPath';
      } else if (layer is ClipRRectLayer &&
          layer.clipBehavior == Clip.antiAliasWithSaveLayer) {
        kind = 'ClipRRect(saveLayer)';
      } else if (layer is ClipRectLayer &&
          layer.clipBehavior == Clip.antiAliasWithSaveLayer) {
        kind = 'ClipRect(saveLayer)';
      }
      if (kind != null) {
        saveLayers += 1;
        final owner = _creatorOf(layer);
        final label = '$kind ← $owner';
        kinds[label] = (kinds[label] ?? 0) + 1;
      }
      if (layer is ContainerLayer) {
        var child = layer.firstChild;
        while (child != null) {
          visit(child);
          child = child.nextSibling;
        }
      }
    }

    visit(root);
    _previousPictures = pictures;
    sample.layers = layers;
    sample.saveLayers = saveLayers;
    sample.saveLayerKinds = kinds;
  }

  /// Which widget owns a layer: the render object that painted it (for a
  /// picture, the nearest composited ancestor's creator), as a short creator
  /// chain so the report can say "the app bar repainted", not "a picture".
  static String _creatorOf(Layer layer) {
    Layer? current = layer;
    while (current != null) {
      final creator = current.debugCreator;
      if (creator is DebugCreator) {
        return creator.element.debugGetCreatorChain(4);
      }
      if (creator is RenderObject) {
        final debugCreator = creator.debugCreator;
        if (debugCreator is DebugCreator) {
          return debugCreator.element.debugGetCreatorChain(4);
        }
        return creator.runtimeType.toString();
      }
      if (creator != null) {
        return creator.toString();
      }
      current = current.parent;
    }
    return 'root';
  }

  /// Per phase key: repainted area (px²) by the widget chain that owned it.
  final Map<String, Map<String, double>> repaintHistograms = {};

  /// Attribute engine timings by when their build started, so a frame that
  /// straddles a phase change is charged to the phase it was drawn in.
  void _onTimings(List<FrameTiming> timings) {
    if (!_running) {
      return;
    }
    for (final timing in timings) {
      final buildStart = timing.timestampInMicroseconds(FramePhase.buildStart);
      FrameSample? target;
      for (var i = samples.length - 1; i >= 0; i--) {
        final sample = samples[i];
        if (sample.buildMicros != null) {
          continue;
        }
        if (sample.startMicros <= buildStart + 2000) {
          target = sample;
          break;
        }
      }
      if (target == null) {
        // A frame we did not see through the persistent callback (before
        // start); keep its timing under the current phase anyway.
        target = FrameSample(surface: _surface, phase: _phase)
          ..startMicros = buildStart;
        samples.add(target);
      }
      target.buildMicros = timing.buildDuration.inMicroseconds;
      target.rasterMicros = timing.rasterDuration.inMicroseconds;
    }
  }

  static final Map<String, int> debugBoundaryPaints = {};
  double get windowArea => _windowArea;

  int get phaseStartMicros => _phaseStartMicros;

  void finish() {
    _flushHistograms();
    stop();
  }
}
