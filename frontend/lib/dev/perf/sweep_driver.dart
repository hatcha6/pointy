// Dev-only: drives the real app through screens and dialogs while the
// FrameProbe watches. Works on a WidgetTester (hermetic, `flutter test`) and on
// a LiveWidgetController (a running profile build) alike — the only thing the
// caller supplies is how to pump one frame.

import 'package:flutter/material.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/shared/components/components.dart';

import 'frame_probe.dart';

typedef PumpFrame = Future<void> Function(Duration duration);

/// Outcome of one measured surface, beyond the frame numbers.
class SurfaceStatus {
  SurfaceStatus(this.name);

  final String name;
  bool reached = false;
  bool settled = true;
  final List<String> notes = [];
}

class SweepDriver {
  SweepDriver({
    required this.controller,
    required this.probe,
    required PumpFrame pumpFrame,
    this.frameInterval = const Duration(milliseconds: 16),
    this.log,
    this.takeException,
  }) : _pumpFrame = pumpFrame;

  final WidgetController controller;
  final FrameProbe probe;
  final PumpFrame _pumpFrame;
  final Duration frameInterval;
  final void Function(String message)? log;

  /// Under `flutter test`, a layout overflow or any other framework error is
  /// held as a pending exception that fails the test at the end. The sweep
  /// measures cost, not correctness, so it drains them per surface and
  /// records them as notes instead (still visible in the report).
  final Object? Function()? takeException;

  void _drainExceptions() {
    final take = takeException;
    if (take == null) {
      return;
    }
    for (var i = 0; i < 20; i++) {
      final error = take();
      if (error == null) {
        return;
      }
      final text = error.toString().split('\n').first;
      if (!status.notes.contains('framework error: $text')) {
        status.notes.add('framework error: $text');
      }
    }
  }

  final Map<String, SurfaceStatus> statuses = {};

  /// Extra numbers a phase wants the report to know (e.g. the scrolled
  /// viewport's area, to judge whether more than the list repainted).
  final Map<String, Map<String, Object?>> phaseMeta = {};

  String surface = 'startup';
  String phase = 'boot';

  SurfaceStatus get status => statuses.putIfAbsent(surface, () => SurfaceStatus(surface));

  void _log(String message) => log?.call(message);

  // ---------------------------------------------------------------- frames

  Future<void> frame() => _pumpFrame(frameInterval);

  Future<void> frames(int count) async {
    for (var i = 0; i < count; i++) {
      await frame();
    }
  }

  bool get isLoading {
    return controller.any(find.byType(PointySpinner)) ||
        controller.any(find.byType(PointySkeleton)) ||
        controller.any(find.byType(PointyLoadingArea));
  }

  /// Pump until nothing wants another frame and no loading placeholder is on
  /// screen, for three frames in a row. False when [timeout] passed first —
  /// the surface still gets measured, but the report says it never settled.
  Future<bool> settle({
    Duration timeout = const Duration(seconds: 12),
    bool waitForLoading = true,
  }) async {
    final maxFrames = timeout.inMilliseconds ~/ frameInterval.inMilliseconds;
    var quiet = 0;
    for (var i = 0; i < maxFrames; i++) {
      await frame();
      final busy =
          controller.binding.hasScheduledFrame ||
          (waitForLoading && isLoading);
      quiet = busy ? 0 : quiet + 1;
      if (quiet >= 3) {
        return true;
      }
    }
    return false;
  }

  void beginPhase(String name) {
    phase = name;
    probe.beginPhase(surface, name);
  }

  /// Run [body] under its own phase label, then drop back to `between` so
  /// whatever the caller does next is not billed to it.
  Future<void> measurePhase(String name, Future<void> Function() body) async {
    beginPhase(name);
    try {
      await body();
    } finally {
      beginPhase('between');
    }
  }

  // ------------------------------------------------------------- surfaces

  /// The standard measurement of one screen: reach it (load), rest on it
  /// (idle), scroll its main list, then run [extras] for dialogs and details.
  Future<void> measureSurface(
    String name, {
    required Future<void> Function() reach,
    bool scroll = true,
    int idleFrames = 30,
    Future<void> Function()? extras,
  }) async {
    surface = name;
    final status = this.status;
    _log('▶ $name');
    try {
      // The route transition is ~300ms of whole-screen animation by design;
      // keep it apart from the loading state that follows, which is where a
      // skeleton or spinner must not repaint the page behind it.
      beginPhase('transition');
      await reach();
      status.reached = true;
      await frames(22);
      beginPhase('load');
      status.settled = await settle();
      if (!status.settled) {
        status.notes.add('did not settle within the load timeout');
      }
      beginPhase('idle');
      await frames(idleFrames);
      if (scroll) {
        await scrollMain();
      }
      if (extras != null) {
        await extras();
      }
    } catch (error, stackTrace) {
      status.notes.add('error: $error');
      _log('  ✗ $name: $error\n$stackTrace');
    } finally {
      _drainExceptions();
      beginPhase('between');
    }
  }

  /// Fling the largest vertical scrollable down then back up, measuring the
  /// frames in between under the `scroll` phase.
  Future<void> scrollMain({String phaseName = 'scroll'}) async {
    final target = _largestVerticalScrollable();
    if (target == null) {
      status.notes.add('no vertical scrollable to fling');
      return;
    }
    final box = controller.renderObject(target) as RenderBox;
    final viewportArea = box.size.width * box.size.height;
    final position = controller.state<ScrollableState>(target).position;
    if (!position.hasContentDimensions ||
        position.maxScrollExtent <= 0) {
      status.notes.add('main list fits the viewport (nothing to scroll)');
      phaseMeta['$surface/$phaseName'] = {
        'viewport_area': viewportArea,
        'scrollable': false,
      };
      return;
    }
    phaseMeta['$surface/$phaseName'] = {
      'viewport_area': viewportArea,
      'scrollable': true,
      'extent': position.maxScrollExtent,
    };
    await measurePhase(phaseName, () async {
      await controller.fling(target, const Offset(0, -600), 2500);
      await settle(
        timeout: const Duration(seconds: 4),
        waitForLoading: false,
      );
      await controller.fling(target, const Offset(0, 600), 2500);
      await settle(
        timeout: const Duration(seconds: 4),
        waitForLoading: false,
      );
    });
  }

  Finder? _largestVerticalScrollable() {
    Finder? best;
    var bestArea = 0.0;
    final finder = find.byType(Scrollable);
    var index = 0;
    for (final element in finder.evaluate()) {
      final widget = element.widget as Scrollable;
      final vertical =
          widget.axisDirection == AxisDirection.down ||
          widget.axisDirection == AxisDirection.up;
      final renderObject = element.renderObject;
      if (vertical &&
          renderObject is RenderBox &&
          renderObject.hasSize &&
          renderObject.attached &&
          _isHittable(renderObject)) {
        final area = renderObject.size.width * renderObject.size.height;
        if (area > bestArea) {
          bestArea = area;
          best = finder.at(index);
        }
      }
      index += 1;
    }
    return best;
  }

  /// A scrollable behind a dialog, sheet, or a pushed route is still in the
  /// tree; only one the pointer can actually reach counts as "the list".
  bool _isHittable(RenderBox box) {
    try {
      final center = box.localToGlobal(box.size.center(Offset.zero));
      final result = controller.hitTestOnBinding(center);
      return result.path.any((entry) => identical(entry.target, box));
    } catch (_) {
      return false;
    }
  }

  // -------------------------------------------------------------- actions

  bool any(Finder finder) => controller.any(finder);

  Future<bool> tap(Finder finder, {String? what}) async {
    if (!controller.any(finder)) {
      status.notes.add('missing: ${what ?? finder.toString()}');
      _log('  · missing ${what ?? finder.toString()}');
      return false;
    }
    await controller.ensureVisible(finder.first);
    await frame();
    await controller.tap(finder.first, warnIfMissed: false);
    await settle();
    return true;
  }

  Future<bool> tapText(String text) => tap(find.text(text), what: "'$text'");

  Future<bool> tapTooltip(String tooltip) =>
      tap(find.byTooltip(tooltip), what: 'tooltip $tooltip');

  Future<bool> tapIcon(IconData icon) =>
      tap(find.byIcon(icon), what: 'icon $icon');

  Future<bool> tapKey(String key) =>
      tap(find.byKey(ValueKey(key)), what: 'key $key');

  /// Types into the first editable text inside [finder], the way a real
  /// keyboard would (through the EditableText input client), so `onChanged`
  /// and debounced searches fire.
  Future<bool> enterText(Finder finder, String text) async {
    final editable = find.descendant(
      of: finder,
      matching: find.byType(EditableText),
      matchRoot: true,
    );
    if (!controller.any(editable)) {
      status.notes.add('missing text field: ${finder.toString()}');
      return false;
    }
    final state = controller.state<EditableTextState>(editable.first);
    state.requestKeyboard();
    await frame();
    state.updateEditingValue(
      TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      ),
    );
    await settle();
    return true;
  }

  /// Types one character at a time, measuring what each keystroke costs.
  Future<bool> typeSearch(Finder finder, String text) async {
    final editable = find.descendant(
      of: finder,
      matching: find.byType(EditableText),
      matchRoot: true,
    );
    if (!controller.any(editable)) {
      status.notes.add('missing search field: ${finder.toString()}');
      return false;
    }
    final state = controller.state<EditableTextState>(editable.first);
    state.requestKeyboard();
    await frame();
    await measurePhase('typing', () async {
      final buffer = StringBuffer();
      for (final rune in text.runes) {
        buffer.writeCharCode(rune);
        final typed = buffer.toString();
        state.updateEditingValue(
          TextEditingValue(
            text: typed,
            selection: TextSelection.collapsed(offset: typed.length),
          ),
        );
        await frames(6);
      }
      await settle();
    });
    return true;
  }

  NavigatorState get navigator =>
      controller.state<NavigatorState>(find.byType(Navigator).first);

  /// Pop the top route (a dialog, sheet, or pushed detail screen).
  Future<void> closeTop({String phaseName = 'close'}) async {
    await measurePhase(phaseName, () async {
      await navigator.maybePop();
      await settle();
    });
  }

  bool get _hasOverlay {
    return controller.any(find.byType(Dialog)) ||
        controller.any(find.byType(AlertDialog)) ||
        controller.any(find.byType(SimpleDialog)) ||
        controller.any(find.byType(BottomSheet)) ||
        controller.any(find.byType(Drawer));
  }

  /// Recovery after a failed step: close whatever dialog, sheet or drawer is
  /// still open so the next surface can be navigated to.
  Future<void> dismissOverlays() async {
    for (var i = 0; i < 4 && _hasOverlay; i++) {
      final nav = navigator;
      if (!nav.canPop()) {
        break;
      }
      await nav.maybePop();
      await settle(timeout: const Duration(seconds: 3));
    }
  }

  /// Open something (dialog, sheet, details screen) under `open:<name>`,
  /// rest on it, optionally scroll it, then close it under `close:<name>`.
  Future<void> openAndClose(
    String name, {
    required Future<bool> Function() open,
    bool scroll = false,
    int idleFrames = 20,
    Future<void> Function()? inside,
    Future<void> Function()? close,
  }) async {
    var opened = false;
    await measurePhase('open:$name', () async {
      opened = await open();
      await settle();
    });
    if (!opened) {
      return;
    }
    beginPhase('idle:$name');
    await frames(idleFrames);
    if (scroll) {
      await scrollMain(phaseName: 'scroll:$name');
    }
    if (inside != null) {
      await inside();
    }
    if (close != null) {
      await measurePhase('close:$name', () async {
        await close();
        await settle();
      });
    } else {
      await closeTop(phaseName: 'close:$name');
    }
  }

  // ----------------------------------------------------------- navigation

  static const _navigationGroups = [
    'الرئيسية',
    'المبيعات',
    'المخزون والمشتريات',
    'الأشخاص والرواتب',
    'التقارير والمراجعة',
    'الإعدادات',
  ];

  /// Open a top-level destination through the drawer/rail, whichever the
  /// current width shows — the same path a user takes.
  Future<void> navigate(String label) async {
    // Scoped to the rail/drawer. A bare `find.text(label)` also matches the
    // *content* of whatever screen is showing — the dashboard has a section
    // headed "المنتجات" — and `destination().last` then tapped the card
    // instead of the tile, so every surface after the dashboard was measured
    // while still on the dashboard.
    Finder destination() {
      final inChrome = find.descendant(
        of: find.byType(PointyNavigationRailSurface),
        matching: find.text(label),
      );
      if (controller.any(inChrome)) {
        return inChrome;
      }
      final inDrawer = find.descendant(
        of: find.byType(Drawer),
        matching: find.text(label),
      );
      if (controller.any(inDrawer)) {
        return inDrawer;
      }
      return find.text(label);
    }

    await _returnToShell();
    if (!controller.any(destination())) {
      await _expandNavigationGroups(destination);
    }
    if (!controller.any(destination())) {
      final expandRail = find.byTooltip('توسيع التنقل');
      final openDrawer = find.byTooltip('فتح القائمة');
      if (controller.any(expandRail)) {
        await controller.tap(expandRail.first, warnIfMissed: false);
      } else if (controller.any(openDrawer)) {
        await controller.tap(openDrawer.first, warnIfMissed: false);
      }
      await settle(timeout: const Duration(seconds: 3));
      await _expandNavigationGroups(destination);
    }
    if (!controller.any(destination())) {
      // The rail/drawer is a ListView with an app-lifetime scroll offset, so
      // destinations past the fold are not built until scrolled to.
      await _scrollNavigationTo(destination);
    }
    if (!controller.any(destination())) {
      _log('  · nav diagnostics: ${_navigationDiagnostics()}');
      throw StateError('navigation label "$label" not found');
    }
    await controller.ensureVisible(destination().last);
    await frame();
    await controller.tap(destination().last, warnIfMissed: false);
  }

  bool get _hasNavigationChrome {
    return controller.any(find.byType(PointyNavigationRailSurface)) ||
        controller.any(find.byType(Drawer)) ||
        controller.any(find.byTooltip('فتح القائمة')) ||
        controller.any(find.byTooltip('توسيع التنقل')) ||
        controller.any(find.byTooltip('طي التنقل'));
  }

  /// Some screens (the returns desk, details screens, dialogs) have a back
  /// button and no drawer: pop until the shell's navigation is back.
  Future<void> _returnToShell() async {
    for (var i = 0; i < 4 && !_hasNavigationChrome; i++) {
      final nav = navigator;
      if (!nav.canPop()) {
        return;
      }
      await nav.maybePop();
      await settle(timeout: const Duration(seconds: 3));
    }
  }

  String _navigationDiagnostics() {
    final rail = find.byType(PointyNavigationRailSurface);
    final drawer = find.byType(Drawer);
    final texts = <String>[];
    for (final surface in [rail, drawer]) {
      if (!controller.any(surface)) {
        continue;
      }
      for (final element
          in find.descendant(of: surface, matching: find.byType(Text)).evaluate()) {
        final data = (element.widget as Text).data;
        if (data != null && data.isNotEmpty) {
          texts.add(data);
        }
      }
    }
    if (texts.isEmpty) {
      for (final element in find.byType(Text).evaluate()) {
        final data = (element.widget as Text).data;
        if (data != null && data.isNotEmpty) {
          texts.add(data);
        }
      }
    }
    return 'rail=${controller.any(rail)} drawer=${controller.any(drawer)} '
        'expand=${controller.any(find.byTooltip('توسيع التنقل'))} '
        'collapse=${controller.any(find.byTooltip('طي التنقل'))} '
        'menu=${controller.any(find.byTooltip('فتح القائمة'))} '
        'dialog=$_hasOverlay texts=${texts.take(40).toList()}';
  }

  Future<void> _scrollNavigationTo(Finder Function() destination) async {
    final surfaces = [
      find.byType(PointyNavigationRailSurface),
      find.byType(Drawer),
    ];
    for (final surface in surfaces) {
      if (!controller.any(surface)) {
        continue;
      }
      final scrollable = find.descendant(
        of: surface,
        matching: find.byType(Scrollable),
      );
      if (!controller.any(scrollable)) {
        continue;
      }
      final position = controller.state<ScrollableState>(scrollable.first).position;
      if (position.hasContentDimensions) {
        position.jumpTo(0);
        await frame();
      }
      if (controller.any(destination())) {
        return;
      }
      try {
        await controller.scrollUntilVisible(
          destination(),
          80,
          scrollable: scrollable.first,
          maxScrolls: 60,
        );
      } on StateError {
        // Fall through: the caller reports the label as missing.
      }
      return;
    }
  }

  Future<void> _expandNavigationGroups(Finder Function() destination) async {
    for (final groupLabel in _navigationGroups) {
      if (controller.any(destination())) {
        return;
      }
      final group = find.text(groupLabel);
      if (!controller.any(group)) {
        continue;
      }
      await controller.ensureVisible(group.first);
      await frame();
      if (controller.any(destination())) {
        return;
      }
      await controller.tap(group.first, warnIfMissed: false);
      await settle(timeout: const Duration(seconds: 3));
    }
  }

  /// Sign in on a live backend (record mode only).
  Future<void> login(String username, String password) async {
    final button = find.text('دخول');
    if (!controller.any(button)) {
      return;
    }
    await enterText(
      find.widgetWithText(TextFormField, 'اسم المستخدم'),
      username,
    );
    await enterText(find.widgetWithText(TextFormField, 'كلمة المرور'), password);
    await controller.tap(button.first, warnIfMissed: false);
    await settle(timeout: const Duration(seconds: 30));
  }
}
