import 'package:flutter/widgets.dart';

import 'anchors.dart';

/// One registered target: an anchor plus an optional instance id.
///
/// The id is what makes "tap خبز" a lesson step rather than "tap one of the
/// twelve product tiles". Without it a lesson can only name a *kind* of widget,
/// so the spotlight lands on whichever instance happened to mount first and the
/// narration names something else.
@immutable
class TutorTargetId {
  const TutorTargetId(this.anchor, [this.id]);

  final TutorAnchor anchor;
  final String? id;

  @override
  bool operator ==(Object other) =>
      other is TutorTargetId && other.anchor == anchor && other.id == id;

  @override
  int get hashCode => Object.hash(anchor, id);

  @override
  String toString() => id == null ? anchor.name : '${anchor.name}#$id';
}

/// Where mounted [TutorTarget]s report themselves during a lesson.
///
/// Scoped to a [TutorScope] rather than global: the lesson runner hosts a
/// second, sandboxed copy of the app, and a process-wide registry would collect
/// the real app's widgets underneath it too.
class TutorRegistry extends ChangeNotifier {
  final Map<TutorTargetId, List<BuildContext>> _targets = {};

  bool _notifyScheduled = false;
  bool _disposed = false;

  /// Coalesced, always out-of-band.
  ///
  /// Targets unregister from `dispose()`, which runs while the framework has
  /// the tree locked — notifying there marks listening widgets as needing
  /// build and throws. Deferring to after the frame also collapses the burst of
  /// registrations a screen produces on mount into one notification.
  void _scheduleNotify() {
    if (_notifyScheduled || _disposed) {
      return;
    }
    _notifyScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _notifyScheduled = false;
      if (!_disposed) {
        notifyListeners();
      }
    });
  }

  void register(TutorTargetId target, BuildContext context) {
    (_targets[target] ??= []).add(context);
    _scheduleNotify();
  }

  void unregister(TutorTargetId target, BuildContext context) {
    final contexts = _targets[target];
    if (contexts == null) {
      return;
    }
    contexts.remove(context);
    if (contexts.isEmpty) {
      _targets.remove(target);
    }
    _scheduleNotify();
  }

  /// How many widgets currently carry [anchor] — narrowed to one instance when
  /// [id] is given. A lesson asserting "خبز is in the cart" asserts on this.
  int countOf(TutorAnchor anchor, {String? id}) {
    if (id != null) {
      return _targets[TutorTargetId(anchor, id)]?.length ?? 0;
    }
    var total = 0;
    for (final entry in _targets.entries) {
      if (entry.key.anchor == anchor) {
        total += entry.value.length;
      }
    }
    return total;
  }

  bool isMounted(TutorAnchor anchor, {String? id}) =>
      countOf(anchor, id: id) > 0;

  /// The first mounted context for the target, for spotlighting. Null when it
  /// is not on screen — which the coach panel must handle rather than draw a
  /// spotlight over empty space.
  BuildContext? contextOf(TutorAnchor anchor, {String? id}) {
    for (final entry in _targets.entries) {
      if (entry.key.anchor != anchor) {
        continue;
      }
      if (id != null && entry.key.id != id) {
        continue;
      }
      for (final context in entry.value) {
        if (context.mounted) {
          return context;
        }
      }
    }
    return null;
  }

  /// The laid-out box of the target, or null when it is not on screen.
  RenderBox? renderBoxOf(TutorAnchor anchor, {String? id}) {
    final box = contextOf(anchor, id: id)?.findRenderObject();
    if (box is! RenderBox || !box.hasSize || !box.attached) {
      return null;
    }
    return box;
  }

  /// The text currently in the first editable field under the target.
  ///
  /// A step that says "type 50" has to be able to assert that 50 was typed.
  /// Without this the only expectations available are about *other* widgets
  /// appearing, which are frequently already true — and a lesson whose step is
  /// satisfied before the learner acts silently skips itself.
  String? textOf(TutorAnchor anchor, {String? id}) {
    final context = contextOf(anchor, id: id);
    if (context is! Element) {
      return null;
    }
    String? found;
    void visit(Element element) {
      if (found != null) {
        return;
      }
      final widget = element.widget;
      if (widget is EditableText) {
        found = widget.controller.text;
        return;
      }
      element.visitChildren(visit);
    }

    context.visitChildren(visit);
    return found;
  }

  Set<TutorAnchor> get mountedAnchors =>
      _targets.keys.map((target) => target.anchor).toSet();

  @override
  void dispose() {
    _disposed = true;
    _targets.clear();
    super.dispose();
  }
}

/// Makes a [TutorRegistry] available to the [TutorTarget]s beneath it.
///
/// Outside a scope — which is the whole shipping app — a [TutorTarget] is a
/// pass-through: no state, no registration, no listeners.
class TutorScope extends InheritedWidget {
  const TutorScope({super.key, required this.registry, required super.child});

  final TutorRegistry registry;

  static TutorRegistry? maybeOf(BuildContext context) {
    return context.getInheritedWidgetOfExactType<TutorScope>()?.registry;
  }

  @override
  bool updateShouldNotify(TutorScope oldWidget) =>
      registry != oldWidget.registry;
}

/// Marks a real widget in a real screen as something a lesson may point at.
///
/// Costs one stateless element outside a lesson and nothing else — no rebuilds,
/// no behaviour, no layout change. Inside a lesson it registers its context so
/// the coach panel can spotlight it and the runner can assert it exists.
///
/// Pass [id] wherever the same anchor appears more than once (a product tile, a
/// cart line) so a lesson can name *which* one.
class TutorTarget extends StatelessWidget {
  const TutorTarget({
    super.key,
    required this.anchor,
    required this.child,
    this.id,
  });

  final TutorAnchor anchor;
  final String? id;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // `getInheritedWidgetOfExactType` reads without subscribing: a target must
    // not rebuild when the registry changes, or spotlighting one widget would
    // rebuild every other target on screen.
    final registry = TutorScope.maybeOf(context);
    if (registry == null) {
      return child;
    }
    return _RegisteredTutorTarget(
      registry: registry,
      target: TutorTargetId(anchor, id),
      child: child,
    );
  }
}

class _RegisteredTutorTarget extends StatefulWidget {
  const _RegisteredTutorTarget({
    required this.registry,
    required this.target,
    required this.child,
  });

  final TutorRegistry registry;
  final TutorTargetId target;
  final Widget child;

  @override
  State<_RegisteredTutorTarget> createState() => _RegisteredTutorTargetState();
}

class _RegisteredTutorTargetState extends State<_RegisteredTutorTarget> {
  @override
  void initState() {
    super.initState();
    // After the frame: registering during build would notify listeners while
    // the tree is still being built.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        widget.registry.register(widget.target, context);
      }
    });
  }

  @override
  void didUpdateWidget(_RegisteredTutorTarget oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A recycled row can be handed a different id (the catalog grid reuses
    // elements as it scrolls). Re-key it, or the registry keeps claiming the
    // old product sits here.
    if (oldWidget.target != widget.target) {
      oldWidget.registry.unregister(oldWidget.target, context);
      widget.registry.register(widget.target, context);
    }
  }

  @override
  void dispose() {
    widget.registry.unregister(widget.target, context);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
