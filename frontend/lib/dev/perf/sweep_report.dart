// Dev-only: turns FrameProbe samples into per-surface/per-phase summaries with
// a verdict against the 60fps-on-any-hardware budget, and renders them as
// JSON and Markdown.
import 'dart:convert';

import 'frame_probe.dart';
import 'sweep_driver.dart';

enum Verdict { ok, warn, fail }

class PhaseSummary {
  PhaseSummary({required this.surface, required this.phase});

  final String surface;
  final String phase;
  int frames = 0;
  double rebuildsAvg = 0;
  int rebuildsMax = 0;
  double paintsAvg = 0;
  int paintsMax = 0;
  double repaintFracAvg = 0;
  double repaintFracMax = 0;
  double largestRepaintAvg = 0;
  double picturesAvg = 0;
  int picturesMax = 0;
  int saveLayersMax = 0;
  Map<String, int> saveLayerKinds = {};
  int timedFrames = 0;
  double buildP50 = 0;
  double buildP95 = 0;
  double buildMax = 0;
  double rasterP50 = 0;
  double rasterP95 = 0;
  double rasterMax = 0;
  int overBudget = 0;
  Verdict verdict = Verdict.ok;
  final List<String> reasons = [];

  String get key => '$surface/$phase';

  Map<String, Object?> toJson() => {
    'surface': surface,
    'phase': phase,
    'frames': frames,
    'rebuilds_avg': _r(rebuildsAvg),
    'rebuilds_max': rebuildsMax,
    'paints_avg': _r(paintsAvg),
    'paints_max': paintsMax,
    'repaint_fraction_avg': _r(repaintFracAvg, 3),
    'repaint_fraction_max': _r(repaintFracMax, 3),
    'largest_repaint_avg_px2': _r(largestRepaintAvg, 0),
    'pictures_rerecorded_avg': _r(picturesAvg),
    'pictures_rerecorded_max': picturesMax,
    'save_layers_max': saveLayersMax,
    'save_layer_kinds': saveLayerKinds,
    'timed_frames': timedFrames,
    'build_ms_p50': _r(buildP50),
    'build_ms_p95': _r(buildP95),
    'build_ms_max': _r(buildMax),
    'raster_ms_p50': _r(rasterP50),
    'raster_ms_p95': _r(rasterP95),
    'raster_ms_max': _r(rasterMax),
    'frames_over_16ms': overBudget,
    'verdict': verdict.name,
    'reasons': reasons,
  };
}

double _r(double value, [int digits = 1]) {
  final factor = digits == 0 ? 1 : (digits == 1 ? 10 : 1000);
  return (value * factor).round() / factor;
}

double _percentile(List<double> sorted, double p) {
  if (sorted.isEmpty) {
    return 0;
  }
  final index = ((sorted.length - 1) * p).round();
  return sorted[index.clamp(0, sorted.length - 1)];
}

/// Budgets. Structural ones are absolute because they are hardware-free; the
/// timing ones are calibrated for the machine the sweep runs on and are only
/// a proxy — a frame that already costs 8ms of raster on an M-series Mac is
/// a dropped frame on a shop PC.
class SweepBudget {
  const SweepBudget({
    this.idleRepaintFraction = 0.05,
    this.idleRebuilds = 5,
    this.idlePaints = 25,
    this.scrollRebuildsWarn = 250,
    this.scrollRebuildsFail = 600,
    this.scrollRepaintOverViewport = 1.25,
    // Calibrated against the healthy screens measured on this app: a
    // virtualised list of PointyDataRows paints 18–30 render objects per
    // scroll frame at a 2500px/s fling on a 1366×768 window.
    this.idlePictures = 0.2,
    this.scrollPicturesWarn = 4,
    this.scrollPicturesFail = 8,
    this.typingRebuildsWarn = 150,
    this.typingPicturesWarn = 3,
    this.typingPicturesFail = 6,
    this.typingRepaintFraction = 0.5,
    this.transitionRebuildsWarn = 1500,
    this.loadRebuildsWarn = 3000,
    this.timingWarnMs = 4,
    this.timingFailMs = 8,
  });

  final double idleRepaintFraction;
  final int idleRebuilds;
  final int idlePaints;
  final int scrollRebuildsWarn;
  final int scrollRebuildsFail;
  final double scrollRepaintOverViewport;
  final double idlePictures;
  final double scrollPicturesWarn;
  final double scrollPicturesFail;
  final int typingRebuildsWarn;
  final double typingPicturesWarn;
  final double typingPicturesFail;
  final double typingRepaintFraction;
  final int transitionRebuildsWarn;
  final int loadRebuildsWarn;
  final double timingWarnMs;
  final double timingFailMs;
}

class SweepReport {
  SweepReport({
    required this.summaries,
    required this.statuses,
    required this.misses,
    required this.rebuildHistograms,
    required this.paintHistograms,
    required this.repaintHistograms,
    required this.structural,
    required this.timed,
    required this.windowArea,
    required this.mode,
  });

  final List<PhaseSummary> summaries;
  final Map<String, SurfaceStatus> statuses;
  final List<String> misses;
  final Map<String, Map<String, int>> rebuildHistograms;
  final Map<String, Map<String, int>> paintHistograms;
  final Map<String, Map<String, double>> repaintHistograms;
  final bool structural;
  final bool timed;
  final double windowArea;
  final String mode;

  List<PhaseSummary> get failures =>
      summaries.where((s) => s.verdict == Verdict.fail).toList();
  List<PhaseSummary> get warnings =>
      summaries.where((s) => s.verdict == Verdict.warn).toList();

  static SweepReport build(
    FrameProbe probe,
    SweepDriver driver, {
    required List<String> misses,
    required String mode,
    SweepBudget budget = const SweepBudget(),
    // Debug-build timings include the JIT and the probe's own hooks; only a
    // profile build's numbers mean anything, so the caller says.
    bool judgeTimings = true,
  }) {
    final windowArea = probe.windowArea;
    final timed = probe.samples.any((s) => s.buildMicros != null);
    final summaries = <PhaseSummary>[];
    final grouped = probe.byPhase;
    for (final entry in grouped.entries) {
      final parts = entry.key.split('/');
      final surface = parts.first;
      final phase = parts.sublist(1).join('/');
      if (phase == 'between' || phase == 'boot') {
        continue;
      }
      final frames = entry.value;
      final summary = PhaseSummary(surface: surface, phase: phase);
      summary.frames = frames.length;
      if (frames.isEmpty) {
        summaries.add(summary);
        continue;
      }
      var rebuilds = 0;
      var paints = 0;
      var repaint = 0.0;
      var largest = 0.0;
      var pictures = 0;
      final kinds = <String, int>{};
      for (final frame in frames) {
        rebuilds += frame.rebuilds;
        paints += frame.paints;
        repaint += frame.repaintArea;
        largest += frame.largestRepaint;
        pictures += frame.repaintPictures;
        if (frame.repaintPictures > summary.picturesMax) {
          summary.picturesMax = frame.repaintPictures;
        }
        if (frame.rebuilds > summary.rebuildsMax) {
          summary.rebuildsMax = frame.rebuilds;
        }
        if (frame.paints > summary.paintsMax) {
          summary.paintsMax = frame.paints;
        }
        if (windowArea > 0) {
          final frac = frame.repaintArea / windowArea;
          if (frac > summary.repaintFracMax) {
            summary.repaintFracMax = frac;
          }
        }
        if (frame.saveLayers > summary.saveLayersMax) {
          summary.saveLayersMax = frame.saveLayers;
          kinds
            ..clear()
            ..addAll(frame.saveLayerKinds);
        }
      }
      summary.rebuildsAvg = rebuilds / frames.length;
      summary.paintsAvg = paints / frames.length;
      summary.repaintFracAvg = windowArea > 0
          ? repaint / frames.length / windowArea
          : 0;
      summary.largestRepaintAvg = largest / frames.length;
      summary.picturesAvg = pictures / frames.length;
      summary.saveLayerKinds = kinds;

      final builds = <double>[];
      final rasters = <double>[];
      for (final frame in frames) {
        if (frame.buildMicros == null) {
          continue;
        }
        final build = frame.buildMicros! / 1000;
        final raster = (frame.rasterMicros ?? 0) / 1000;
        builds.add(build);
        rasters.add(raster);
        if (build > 16.6 || raster > 16.6) {
          summary.overBudget += 1;
        }
      }
      builds.sort();
      rasters.sort();
      summary.timedFrames = builds.length;
      summary.buildP50 = _percentile(builds, 0.5);
      summary.buildP95 = _percentile(builds, 0.95);
      summary.buildMax = builds.isEmpty ? 0 : builds.last;
      summary.rasterP50 = _percentile(rasters, 0.5);
      summary.rasterP95 = _percentile(rasters, 0.95);
      summary.rasterMax = rasters.isEmpty ? 0 : rasters.last;

      _judge(
        summary,
        budget,
        probe.structuralMetricsAvailable,
        driver,
        judgeTimings: judgeTimings,
      );
      summaries.add(summary);
    }
    summaries.sort((a, b) {
      final byVerdict = b.verdict.index.compareTo(a.verdict.index);
      if (byVerdict != 0) {
        return byVerdict;
      }
      final bySurface = a.surface.compareTo(b.surface);
      return bySurface != 0 ? bySurface : a.phase.compareTo(b.phase);
    });
    return SweepReport(
      summaries: summaries,
      statuses: driver.statuses,
      misses: misses,
      rebuildHistograms: probe.rebuildHistograms,
      paintHistograms: probe.paintHistograms,
      repaintHistograms: probe.repaintHistograms,
      structural: probe.structuralMetricsAvailable,
      timed: timed,
      windowArea: windowArea,
      mode: mode,
    );
  }

  static void _judge(
    PhaseSummary s,
    SweepBudget budget,
    bool structural,
    SweepDriver driver, {
    required bool judgeTimings,
  }) {
    void fail(String why) {
      s.verdict = Verdict.fail;
      s.reasons.add(why);
    }

    void warn(String why) {
      if (s.verdict != Verdict.fail) {
        s.verdict = Verdict.warn;
      }
      s.reasons.add(why);
    }

    final phase = s.phase;
    if (structural) {
      // Under `flutter test` a frame is only drawn when something scheduled
      // one, so an idle screen that draws nothing has no samples at all, and
      // a lone late frame (a deferred load finishing) is not a per-frame
      // cost. Only a sustained stream of idle frames is jank.
      if (phase.startsWith('idle') && s.frames >= 5) {
        if (s.picturesAvg > budget.idlePictures) {
          fail(
            '${s.picturesAvg.toStringAsFixed(1)} pictures re-recorded per '
            'idle frame (a resting screen should redraw nothing)',
          );
        }
        if (s.rebuildsAvg > budget.idleRebuilds) {
          fail('${s.rebuildsAvg.toStringAsFixed(1)} widgets rebuilt per idle frame');
        }
        if (s.paintsAvg > budget.idlePaints) {
          warn('${s.paintsAvg.toStringAsFixed(0)} render objects painted per idle frame');
        }
        if (s.saveLayersMax > 0) {
          warn('${s.saveLayersMax} saveLayer(s) in the resting tree: ${s.saveLayerKinds}');
        }
      } else if (phase.startsWith('scroll')) {
        // Painted render objects, not repainted area, is the honest scroll
        // metric: Flutter records a viewport's picture with the whole
        // viewport as its cull rect however little of it actually changed,
        // so area over-reports every scrolling list equally. A virtualised
        // list with per-item repaint boundaries only paints the items
        // entering the viewport, so this number stays small however long the
        // list is — and grows with how expensive one row is to paint.
        if (s.picturesAvg > budget.scrollPicturesFail) {
          fail(
            '${s.picturesAvg.toStringAsFixed(1)} pictures re-recorded per '
            'scroll frame (rows repaint instead of just moving)',
          );
        } else if (s.picturesAvg > budget.scrollPicturesWarn) {
          warn(
            '${s.picturesAvg.toStringAsFixed(1)} pictures re-recorded per '
            'scroll frame',
          );
        }
        final meta = driver.phaseMeta[s.key];
        final viewport = (meta?['viewport_area'] as num?)?.toDouble();
        if (viewport != null &&
            viewport > 0 &&
            s.largestRepaintAvg > viewport * budget.scrollRepaintOverViewport) {
          warn(
            'the largest re-recorded picture is '
            '${(s.largestRepaintAvg / viewport).toStringAsFixed(1)}× the list '
            'viewport (something outside the list may be re-recording)',
          );
        }
        if (s.rebuildsAvg > budget.scrollRebuildsFail) {
          fail('${s.rebuildsAvg.toStringAsFixed(0)} widgets rebuilt per scroll frame');
        } else if (s.rebuildsAvg > budget.scrollRebuildsWarn) {
          warn('${s.rebuildsAvg.toStringAsFixed(0)} widgets rebuilt per scroll frame');
        }
        if (s.saveLayersMax > 0) {
          warn('${s.saveLayersMax} saveLayer(s) while scrolling: ${s.saveLayerKinds}');
        }
      } else if (phase.startsWith('typing')) {
        // One character should redraw the field, not the page behind it.
        if (s.picturesAvg > budget.typingPicturesFail) {
          fail(
            '${s.picturesAvg.toStringAsFixed(1)} pictures re-recorded per '
            'keystroke frame (the page redraws, not just the field)',
          );
        } else if (s.picturesAvg > budget.typingPicturesWarn) {
          warn(
            '${s.picturesAvg.toStringAsFixed(1)} pictures re-recorded per '
            'keystroke frame',
          );
        }
        if (s.rebuildsAvg > budget.typingRebuildsWarn) {
          warn('${s.rebuildsAvg.toStringAsFixed(0)} widgets rebuilt per typing frame');
        }
      } else if (phase.startsWith('open') || phase.startsWith('close')) {
        if (s.rebuildsMax > budget.transitionRebuildsWarn) {
          warn('${s.rebuildsMax} widgets rebuilt in one transition frame');
        }
        if (s.saveLayersMax > 1) {
          warn('${s.saveLayersMax} saveLayers during the transition: ${s.saveLayerKinds}');
        }
      } else if (phase == 'load') {
        if (s.rebuildsMax > budget.loadRebuildsWarn) {
          warn('${s.rebuildsMax} widgets rebuilt in one load frame');
        }
      }
    }
    if (judgeTimings && s.timedFrames > 0) {
      if (s.buildP95 > budget.timingFailMs) {
        fail('build p95 ${s.buildP95.toStringAsFixed(1)}ms');
      } else if (s.buildP95 > budget.timingWarnMs) {
        warn('build p95 ${s.buildP95.toStringAsFixed(1)}ms');
      }
      if (s.rasterP95 > budget.timingFailMs) {
        fail('raster p95 ${s.rasterP95.toStringAsFixed(1)}ms');
      } else if (s.rasterP95 > budget.timingWarnMs) {
        warn('raster p95 ${s.rasterP95.toStringAsFixed(1)}ms');
      }
      if (s.overBudget > 0 && s.verdict == Verdict.ok) {
        warn('${s.overBudget} frame(s) over 16.6ms');
      }
    }
  }

  Map<String, Object?> toJson() => {
    'mode': mode,
    'structural_metrics': structural,
    'timing_metrics': timed,
    'window_area': windowArea,
    'surfaces': {
      for (final status in statuses.values)
        status.name: {
          'reached': status.reached,
          'settled': status.settled,
          'notes': status.notes,
        },
    },
    'phases': [for (final s in summaries) s.toJson()],
    'fixture_misses': misses,
    'rebuild_histograms': rebuildHistograms,
    'paint_histograms': paintHistograms,
    'repaint_histograms': repaintHistograms,
  };

  String toJsonString() =>
      const JsonEncoder.withIndent('  ').convert(toJson());

  String toMarkdown() {
    final buffer = StringBuffer();
    buffer.writeln('# Frontend performance sweep ($mode)');
    buffer.writeln();
    buffer.writeln(
      '- surfaces: ${statuses.length}, phases: ${summaries.length}, '
      'fail: ${failures.length}, warn: ${warnings.length}',
    );
    buffer.writeln(
      '- structural metrics: ${structural ? 'yes (debug hooks)' : 'no'}; '
      'timing metrics: ${timed ? 'yes (FrameTiming)' : 'no'}',
    );
    final unreached = statuses.values.where((s) => !s.reached).toList();
    if (unreached.isNotEmpty) {
      buffer.writeln('- NOT reached: ${unreached.map((s) => s.name).join(', ')}');
    }
    final unsettled = statuses.values.where((s) => s.reached && !s.settled);
    if (unsettled.isNotEmpty) {
      buffer.writeln('- never settled: ${unsettled.map((s) => s.name).join(', ')}');
    }
    buffer.writeln();
    buffer.writeln('## Phases');
    buffer.writeln();
    buffer.write('| surface | phase | frames | rebuilds avg/max | paints avg/max ');
    buffer.write('| redrawn pictures avg/max | saveLayers ');
    if (timed) {
      buffer.write('| build p50/p95/max ms | raster p50/p95/max ms | >16ms ');
    }
    buffer.writeln('| verdict |');
    buffer.write('|---|---|---:|---:|---:|---:|---:|');
    if (timed) {
      buffer.write('---:|---:|---:|');
    }
    buffer.writeln('---|');
    for (final s in summaries) {
      buffer.write(
        '| ${s.surface} | ${s.phase} | ${s.frames} '
        '| ${s.rebuildsAvg.toStringAsFixed(1)}/${s.rebuildsMax} '
        '| ${s.paintsAvg.toStringAsFixed(0)}/${s.paintsMax} '
        '| ${s.picturesAvg.toStringAsFixed(1)}/${s.picturesMax} '
        '| ${s.saveLayersMax} ',
      );
      if (timed) {
        buffer.write(
          '| ${s.buildP50.toStringAsFixed(1)}/${s.buildP95.toStringAsFixed(1)}/${s.buildMax.toStringAsFixed(1)} '
          '| ${s.rasterP50.toStringAsFixed(1)}/${s.rasterP95.toStringAsFixed(1)}/${s.rasterMax.toStringAsFixed(1)} '
          '| ${s.overBudget} ',
        );
      }
      final verdict = switch (s.verdict) {
        Verdict.ok => 'ok',
        Verdict.warn => 'WARN',
        Verdict.fail => 'FAIL',
      };
      buffer.writeln(
        '| $verdict${s.reasons.isEmpty ? '' : ': ${s.reasons.join('; ')}'} |',
      );
    }
    final flagged = summaries.where((s) => s.verdict != Verdict.ok).toList();
    if (flagged.isNotEmpty && structural) {
      buffer.writeln();
      buffer.writeln('## What rebuilt / painted in flagged phases');
      for (final s in flagged) {
        final rebuilt = rebuildHistograms[s.key];
        final painted = paintHistograms[s.key];
        buffer.writeln();
        buffer.writeln('### ${s.key}');
        if (rebuilt != null && rebuilt.isNotEmpty) {
          buffer.writeln('- rebuilt: ${_top(rebuilt, 8)}');
        }
        if (painted != null && painted.isNotEmpty) {
          buffer.writeln('- painted: ${_top(painted, 8)}');
        }
        final repainted = repaintHistograms[s.key];
        if (repainted != null && repainted.isNotEmpty && s.frames > 0) {
          final owners = repainted.entries.toList()
            ..sort((a, b) => b.value.compareTo(a.value));
          buffer.writeln('- repainted (avg % of window per frame, by owner):');
          for (final owner in owners.take(6)) {
            final perFrame = windowArea > 0
                ? owner.value / s.frames / windowArea * 100
                : 0.0;
            buffer.writeln(
              '  - ${perFrame.toStringAsFixed(1)}% `${owner.key}`',
            );
          }
        }
      }
    }
    final noted = statuses.values.where((s) => s.notes.isNotEmpty).toList();
    if (noted.isNotEmpty) {
      buffer.writeln();
      buffer.writeln('## Surface notes');
      for (final status in noted) {
        buffer.writeln('- ${status.name}: ${status.notes.join('; ')}');
      }
    }
    if (misses.isNotEmpty) {
      buffer.writeln();
      buffer.writeln('## Fixture misses (${misses.length})');
      for (final miss in misses) {
        buffer.writeln('- `$miss`');
      }
    }
    return buffer.toString();
  }

  static String _top(Map<String, int> histogram, int count) {
    final entries = histogram.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return entries
        .take(count)
        .map((e) => '${e.key}×${e.value}')
        .join(', ');
  }
}
