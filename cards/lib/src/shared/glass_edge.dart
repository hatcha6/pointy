import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

/// iOS's soft scroll edge, behind a pinned header: what scrolls beneath is
/// sharp where the box ends and grows blurrier, and more of the page's own
/// colour, up to the box's top edge.
///
/// A blur under a fade mask cannot do it: the mask's layer holds none of
/// the backdrop, so only the tint shows. This runs its own shader on the
/// backdrop instead, its blur growing toward the top. Where shaders cannot
/// filter (the web, Skia), the colour alone fades in.
class GlassEdge extends StatefulWidget {
  const GlassEdge({super.key, this.amount = 1, this.sigma = 18, this.tint});

  /// 0 for none (nothing has scrolled under yet), up to 1: the blur and the
  /// colour grow together.
  final double amount;

  /// The blur at the top edge, in logical pixels.
  final double sigma;

  /// The colour at the top edge; the page's background by default.
  final Color? tint;

  @override
  State<GlassEdge> createState() => _GlassEdgeState();
}

ui.FragmentProgram? _program;
Future<void>? _loading;

class _GlassEdgeState extends State<GlassEdge> {
  @override
  void initState() {
    super.initState();
    if (ui.ImageFilter.isShaderFilterSupported && _program == null) {
      _loading ??= ui.FragmentProgram.fromAsset('shaders/glass_edge.frag')
          .then((program) => _program = program);
      _loading!.then((_) {
        if (mounted) {
          setState(() {});
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final tint =
        widget.tint ??
        Theme.of(context).scaffoldBackgroundColor.withValues(alpha: 0.78);
    final program = _program;
    if (widget.amount <= 0) {
      return const SizedBox.expand();
    }
    return IgnorePointer(
      child: program == null
          ? DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    tint.withValues(alpha: 0.96 * widget.amount),
                    tint.withValues(alpha: 0.9 * widget.amount),
                    tint.withValues(alpha: 0),
                  ],
                  stops: const [0, 0.5, 1],
                ),
              ),
              child: const SizedBox.expand(),
            )
          : _GlassEdgeBackdrop(
              program: program,
              sigma: widget.sigma * widget.amount,
              tint: tint.withValues(alpha: tint.a * widget.amount),
              devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
            ),
    );
  }
}

class _GlassEdgeBackdrop extends LeafRenderObjectWidget {
  const _GlassEdgeBackdrop({
    required this.program,
    required this.sigma,
    required this.tint,
    required this.devicePixelRatio,
  });

  final ui.FragmentProgram program;
  final double sigma;
  final Color tint;
  final double devicePixelRatio;

  @override
  _RenderGlassEdge createRenderObject(BuildContext context) => _RenderGlassEdge(
    program: program,
    sigma: sigma,
    tint: tint,
    devicePixelRatio: devicePixelRatio,
  );

  @override
  void updateRenderObject(BuildContext context, _RenderGlassEdge renderObject) {
    renderObject
      ..sigma = sigma
      ..tint = tint
      ..devicePixelRatio = devicePixelRatio;
  }
}

// The shader's float uniforms after the engine's `u_size` (0 and 1).
const _uBand = 2;
const _uSigma = 6;
const _uVertical = 7;
const _uTint = 8;
const _uScale = 12;

/// The blur's two rounds each way (see the shader): a small one that takes
/// out the detail the large one's taps would skip, then the large one; their
/// squares add up to the whole blur.
const _smallRound = 0.2;
final _largeRound = math.sqrt(1 - _smallRound * _smallRound);

class _RenderGlassEdge extends RenderBox {
  _RenderGlassEdge({
    required ui.FragmentProgram program,
    required this._sigma,
    required this._tint,
    required this._devicePixelRatio,
  }) : _rounds = [for (var i = 0; i < 4; i++) program.fragmentShader()];

  /// Small across, large across, small down, large down.
  final List<ui.FragmentShader> _rounds;
  final _clip = LayerHandle<ClipRectLayer>();
  final _backdrop = LayerHandle<BackdropFilterLayer>();

  /// Where the box was on screen when last painted: the shader works in
  /// screen pixels, and a parent can move the box without repainting it (a
  /// page sliding in, the header before it pins).
  Rect? _painted;
  bool _attached = false;

  double _sigma;
  set sigma(double value) {
    if (value != _sigma) {
      _sigma = value;
      markNeedsPaint();
    }
  }

  Color _tint;
  set tint(Color value) {
    if (value != _tint) {
      _tint = value;
      markNeedsPaint();
    }
  }

  double _devicePixelRatio;
  set devicePixelRatio(double value) {
    if (value != _devicePixelRatio) {
      _devicePixelRatio = value;
      markNeedsPaint();
    }
  }

  @override
  bool get sizedByParent => true;

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;

  @override
  bool get alwaysNeedsCompositing => true;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _attached = true;
    _follow();
  }

  @override
  void detach() {
    _attached = false;
    super.detach();
  }

  void _follow() {
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!_attached) {
        return;
      }
      if (hasSize && _painted != null && _onScreen() != _painted) {
        markNeedsPaint();
      }
      _follow();
    });
  }

  Rect _onScreen() =>
      MatrixUtils.transformRect(getTransformTo(null), Offset.zero & size);

  void _set(
    ui.FragmentShader shader,
    Rect band, {
    required bool vertical,
    required double scale,
    bool tint = false,
  }) {
    // The page's colour goes on once, in the last round.
    final color = tint ? _tint : const Color(0x00000000);
    shader
      ..setFloat(_uBand, band.left)
      ..setFloat(_uBand + 1, band.top)
      ..setFloat(_uBand + 2, band.width)
      ..setFloat(_uBand + 3, band.height)
      ..setFloat(_uSigma, _sigma * _devicePixelRatio)
      ..setFloat(_uVertical, vertical ? 1 : 0)
      ..setFloat(_uTint, color.r * color.a)
      ..setFloat(_uTint + 1, color.g * color.a)
      ..setFloat(_uTint + 2, color.b * color.a)
      ..setFloat(_uTint + 3, color.a)
      ..setFloat(_uScale, scale);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final screen = _painted = _onScreen();
    final band = Rect.fromLTRB(
      screen.left * _devicePixelRatio,
      screen.top * _devicePixelRatio,
      screen.right * _devicePixelRatio,
      screen.bottom * _devicePixelRatio,
    );
    _set(_rounds[0], band, vertical: false, scale: _smallRound);
    _set(_rounds[1], band, vertical: false, scale: _largeRound);
    _set(_rounds[2], band, vertical: true, scale: _smallRound);
    _set(_rounds[3], band, vertical: true, scale: _largeRound, tint: true);
    final backdrop = _backdrop.layer ??= BackdropFilterLayer();
    backdrop.filter = _rounds
        .map(ui.ImageFilter.shader)
        .reduce(
          (inner, outer) => ui.ImageFilter.compose(outer: outer, inner: inner),
        );
    // The clip keeps the filter to the band: that is what keeps it cheap.
    _clip.layer = context.pushClipRect(
      needsCompositing,
      offset,
      Offset.zero & size,
      (context, offset) => context.pushLayer(backdrop, (_, _) {}, offset),
      oldLayer: _clip.layer,
    );
  }

  @override
  void dispose() {
    _clip.layer = null;
    _backdrop.layer = null;
    for (final round in _rounds) {
      round.dispose();
    }
    super.dispose();
  }
}
