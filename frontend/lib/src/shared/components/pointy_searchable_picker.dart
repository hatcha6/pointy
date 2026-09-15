import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../design/design.dart';
import '../query_controls/debounced_search_field.dart';
import '../tutor/anchors.dart';
import '../tutor/tutor_target.dart';

/// One selectable row in a [PointySearchablePicker] menu.
@immutable
class PointyPickerEntry<T extends Object> {
  const PointyPickerEntry({
    required this.value,
    required this.label,
    this.subtitle,
    this.keywords = '',
  });

  final T value;
  final String label;

  /// Secondary line under the label — e.g. a preview of an option's values.
  final String? subtitle;

  /// Extra text searched alongside [label] and [subtitle]: codes, synonyms.
  final String keywords;

  bool matches(String normalizedQuery) {
    if (normalizedQuery.isEmpty) {
      return true;
    }
    return normalizeForSearch(label).contains(normalizedQuery) ||
        normalizeForSearch(subtitle ?? '').contains(normalizedQuery) ||
        normalizeForSearch(keywords).contains(normalizedQuery);
  }
}

/// Folds the spelling variants Arabic typists use interchangeably so that
/// "احمر" finds "أحمر" and "قطن " finds "قُطن". Latin text only gets the usual
/// case fold.
String normalizeForSearch(String value) {
  final buffer = StringBuffer();
  for (final rune in value.toLowerCase().runes) {
    final folded = switch (rune) {
      0x0622 || 0x0623 || 0x0625 || 0x0671 => 0x0627, // آ إ أ ٱ -> ا
      0x0649 => 0x064A, // ى -> ي
      0x0629 => 0x0647, // ة -> ه
      0x0640 => -1, // tatweel
      // Harakat, shadda, sukun and the Quranic marks above them.
      >= 0x064B && <= 0x0652 => -1,
      0x0670 => -1, // dagger alef
      _ => rune,
    };
    if (folded >= 0) {
      buffer.writeCharCode(folded);
    }
  }
  return buffer.toString().trim();
}

/// A combobox that filters an in-memory list as the user types and — when the
/// typed text matches nothing — offers to create it inline.
///
/// Built for "add one of the things you already saved" fields: previously
/// created variant options and their values. It replaces the walls of chips
/// those fields used to render, which grew unreadable as a shop accumulated
/// options.
class PointySearchablePicker<T extends Object> extends StatefulWidget {
  const PointySearchablePicker({
    super.key,
    required this.entries,
    required this.onSelected,
    required this.hintText,
    required this.clearTooltip,
    required this.noMatchText,
    this.emptyText,
    this.onCreate,
    this.createLabel,
    this.enabled = true,
    this.fieldKey,
    this.maxMenuHeight = 288,
  });

  final List<PointyPickerEntry<T>> entries;
  final ValueChanged<T> onSelected;

  final String hintText;
  final String clearTooltip;

  /// Shown in the menu when the typed query matches nothing.
  final String noMatchText;

  /// Shown in the menu when there is nothing left to pick at all. Falls back to
  /// [noMatchText] when null.
  final String? emptyText;

  /// Creates a brand new entry from what the user typed. When null the picker
  /// only offers what already exists.
  final ValueChanged<String>? onCreate;

  /// Label for the create row, e.g. `(typed) => 'Create "$typed"'`. Required
  /// whenever [onCreate] is set.
  final String Function(String typed)? createLabel;

  final bool enabled;
  final Key? fieldKey;
  final double maxMenuHeight;

  @override
  State<PointySearchablePicker<T>> createState() =>
      _PointySearchablePickerState<T>();
}

class _PointySearchablePickerState<T extends Object>
    extends State<PointySearchablePicker<T>> {
  final _link = LayerLink();
  final _portal = OverlayPortalController();
  final _focusNode = FocusNode();
  final _menuScrollController = ScrollController();

  /// Fired to clear the search field after a pick — [DebouncedSearchField]
  /// owns its own controller, so this is how the text is reset from here.
  final _resetSignal = _ResetSignal();

  var _query = '';
  var _highlighted = 0;

  /// The field's own width, so the menu lines up with it exactly. Captured
  /// during layout because the menu renders in the overlay, outside the form.
  double _fieldWidth = 0;

  /// Decided when the menu opens: a field near the bottom of the window drops
  /// its menu upward instead of off-screen.
  var _openUpward = false;
  double _availableMenuHeight = 288;

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_handleFocusChange);
  }

  @override
  void dispose() {
    _focusNode.removeListener(_handleFocusChange);
    _focusNode.dispose();
    _resetSignal.dispose();
    _menuScrollController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant PointySearchablePicker<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled && _portal.isShowing) {
      _close();
    }
  }

  void _handleFocusChange() {
    if (_focusNode.hasFocus) {
      _open();
    }
  }

  /// Rows currently offered, in the order they are rendered — the source of
  /// truth for both the menu and keyboard highlighting.
  List<_MenuRow<T>> get _rows => _rowsFor(_query);

  List<_MenuRow<T>> _rowsFor(String query) {
    final normalized = normalizeForSearch(query);
    final matched = [
      for (final entry in widget.entries)
        if (entry.matches(normalized)) _MenuRow<T>.entry(entry),
    ];
    // Creating is only offered for a name that does not already exist, so the
    // menu never invites a duplicate of the row right above it.
    final typed = query.trim();
    final canCreate =
        widget.onCreate != null &&
        typed.isNotEmpty &&
        !widget.entries.any(
          (entry) => normalizeForSearch(entry.label) == normalized,
        );
    return [...matched, if (canCreate) _MenuRow<T>.create(typed)];
  }

  void _open() {
    if (!widget.enabled || _portal.isShowing) {
      return;
    }
    _measure();
    setState(() {
      _highlighted = 0;
      _portal.show();
    });
  }

  void _close({bool unfocus = false}) {
    if (_portal.isShowing) {
      setState(_portal.hide);
    }
    if (unfocus && _focusNode.hasFocus) {
      _focusNode.unfocus();
    }
  }

  /// Measures the room under the field so the menu never opens off-screen.
  void _measure() {
    final box = context.findRenderObject() as RenderBox?;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize || overlay == null) {
      _openUpward = false;
      _availableMenuHeight = widget.maxMenuHeight;
      return;
    }
    final top = box.localToGlobal(Offset.zero, ancestor: overlay).dy;
    final below = overlay.size.height - (top + box.size.height) - 16;
    final above = top - 16;
    _openUpward = below < 160 && above > below;
    _availableMenuHeight = (_openUpward ? above : below).clamp(
      120.0,
      widget.maxMenuHeight,
    );
  }

  void _select(_MenuRow<T> row) {
    _resetSignal.fire();
    _query = '';
    _close(unfocus: true);
    switch (row) {
      case _EntryRow<T>(:final entry):
        widget.onSelected(entry.value);
      case _CreateRow<T>(:final typed):
        widget.onCreate?.call(typed);
    }
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final rows = _rows;
    switch (event.logicalKey) {
      case LogicalKeyboardKey.escape:
        if (!_portal.isShowing) {
          return KeyEventResult.ignored;
        }
        _close(unfocus: true);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowDown:
      case LogicalKeyboardKey.arrowUp:
        if (rows.isEmpty) {
          return KeyEventResult.handled;
        }
        if (!_portal.isShowing) {
          _open();
          return KeyEventResult.handled;
        }
        final step = event.logicalKey == LogicalKeyboardKey.arrowDown ? 1 : -1;
        setState(() {
          _highlighted = (_highlighted + step) % rows.length;
          if (_highlighted < 0) {
            _highlighted += rows.length;
          }
        });
        _scrollHighlightedIntoView();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.enter:
      case LogicalKeyboardKey.numpadEnter:
        if (_portal.isShowing && _highlighted < rows.length) {
          _select(rows[_highlighted]);
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      default:
        return KeyEventResult.ignored;
    }
  }

  void _scrollHighlightedIntoView() {
    if (!_menuScrollController.hasClients) {
      return;
    }
    const rowHeight = _menuRowHeight;
    final target = _highlighted * rowHeight;
    final position = _menuScrollController.position;
    if (target < position.pixels) {
      position.jumpTo(target.clamp(0.0, position.maxScrollExtent));
    } else if (target + rowHeight >
        position.pixels + position.viewportDimension) {
      position.jumpTo(
        (target + rowHeight - position.viewportDimension).clamp(
          0.0,
          position.maxScrollExtent,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return TapRegion(
      groupId: _portal,
      onTapOutside: (_) => _close(unfocus: true),
      child: CompositedTransformTarget(
        link: _link,
        child: OverlayPortal(
          controller: _portal,
          overlayChildBuilder: _buildMenu,
          child: LayoutBuilder(
            builder: (context, constraints) {
              _fieldWidth = constraints.maxWidth;
              return _buildField(context);
            },
          ),
        ),
      ),
    );
  }

  Widget _buildField(BuildContext context) {
    return Listener(
      // A tap on an already-focused field reopens a menu the user dismissed
      // with Escape; focus alone would not fire again.
      onPointerDown: (_) => _open(),
      child: Focus(
        onKeyEvent: _handleKey,
        child: DebouncedSearchField(
          fieldKey: widget.fieldKey,
          focusNode: _focusNode,
          resetSignal: _resetSignal,
          value: '',
          hintText: widget.hintText,
          clearTooltip: widget.clearTooltip,
          enabled: widget.enabled,
          // The list being filtered is already in memory, so this only has to
          // coalesce a burst of keystrokes into one rebuild — a search-request
          // debounce would feel like lag here.
          debounceDuration: const Duration(milliseconds: 120),
          onChanged: (value) {
            if (!mounted) {
              return;
            }
            setState(() {
              _query = value;
              _highlighted = 0;
            });
            if (value.isNotEmpty) {
              _open();
            }
          },
          // The on-screen keyboard's action key, where no raw Enter reaches
          // the shortcut handler above.
          onSubmitted: (value) {
            final rows = _rowsFor(value);
            if (_highlighted < rows.length) {
              _select(rows[_highlighted]);
            }
            return false;
          },
        ),
      ),
    );
  }

  Widget _buildMenu(BuildContext context) {
    final colors = context.pointyColors;
    final rows = _rows;

    return TapRegion(
      groupId: _portal,
      // The menu is the same width as the field and anchored to its left edge,
      // which lands on the same rect in both text directions.
      child: CompositedTransformFollower(
        link: _link,
        targetAnchor: _openUpward ? Alignment.topLeft : Alignment.bottomLeft,
        followerAnchor: _openUpward ? Alignment.bottomLeft : Alignment.topLeft,
        offset: Offset(0, _openUpward ? -4 : 4),
        // The overlay lays its children out with tight constraints, so the menu
        // has to be aligned back down to its own size — against the anchored
        // corner, or it lands a screen away from the field.
        child: Align(
          alignment: _openUpward ? Alignment.bottomLeft : Alignment.topLeft,
          child: SizedBox(
            width: _fieldWidth,
            child: Material(
              elevation: 8,
              color: colors.surface,
              shadowColor: colors.ink.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(PointyRadii.input),
              clipBehavior: Clip.antiAlias,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: _availableMenuHeight),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(color: colors.line),
                    borderRadius: BorderRadius.circular(PointyRadii.input),
                  ),
                  child: rows.isEmpty
                      ? _EmptyMenuMessage(
                          text: _query.trim().isEmpty
                              ? (widget.emptyText ?? widget.noMatchText)
                              : widget.noMatchText,
                        )
                      : ListView.builder(
                          controller: _menuScrollController,
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          shrinkWrap: true,
                          itemCount: rows.length,
                          itemBuilder: (context, index) => _MenuRowTile<T>(
                            row: rows[index],
                            isHighlighted: index == _highlighted,
                            createLabel: widget.createLabel,
                            onTap: () => _select(rows[index]),
                          ),
                        ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Clears the search field from outside [DebouncedSearchField], which owns its
/// own controller.
class _ResetSignal extends ChangeNotifier {
  void fire() => notifyListeners();
}

const double _menuRowHeight = 48;

sealed class _MenuRow<T extends Object> {
  const _MenuRow();

  factory _MenuRow.entry(PointyPickerEntry<T> entry) = _EntryRow<T>;
  factory _MenuRow.create(String typed) = _CreateRow<T>;
}

class _EntryRow<T extends Object> extends _MenuRow<T> {
  const _EntryRow(this.entry);
  final PointyPickerEntry<T> entry;
}

class _CreateRow<T extends Object> extends _MenuRow<T> {
  const _CreateRow(this.typed);
  final String typed;
}

class _MenuRowTile<T extends Object> extends StatelessWidget {
  const _MenuRowTile({
    required this.row,
    required this.isHighlighted,
    required this.createLabel,
    required this.onTap,
  });

  final _MenuRow<T> row;
  final bool isHighlighted;
  final String Function(String typed)? createLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final isCreate = row is _CreateRow<T>;
    final label = switch (row) {
      _EntryRow<T>(:final entry) => entry.label,
      _CreateRow<T>(:final typed) => createLabel?.call(typed) ?? typed,
    };
    final subtitle = switch (row) {
      _EntryRow<T>(:final entry) => entry.subtitle,
      _CreateRow<T>() => null,
    };

    return TutorTarget(
      // By label, because that is what a lesson can name: "pick المقاس".
      anchor: TutorAnchor.searchablePickerRow,
      id: label,
      child: InkWell(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: _menuRowHeight),
          padding: const EdgeInsetsDirectional.fromSTEB(12, 8, 12, 8),
          color: isHighlighted ? colors.primaryContainer : null,
          child: Row(
            children: [
              Icon(
                isCreate ? Icons.add_circle_outline : Icons.label_outline,
                size: 18,
                color: isCreate ? colors.primaryStrong : colors.mutedInk,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: isCreate ? FontWeight.w600 : null,
                        color: isCreate ? colors.primaryStrong : null,
                      ),
                    ),
                    if (subtitle != null && subtitle.isNotEmpty)
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.mutedInk,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyMenuMessage extends StatelessWidget {
  const _EmptyMenuMessage({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
      child: Text(
        text,
        style: Theme.of(
          context,
        ).textTheme.bodySmall?.copyWith(color: context.pointyColors.mutedInk),
      ),
    );
  }
}
