import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../components/pointy_error_state.dart';
import '../design/design.dart';
import '../infinite_scroll_grid.dart';
import '../query_controls/debounced_search_field.dart';
import '../responsive/responsive.dart';

typedef AsyncSelectionPageLoader<T extends Object> =
    Future<AsyncSelectionPage<T>> Function(String search, int page);

class AsyncSelectionPage<T extends Object> {
  const AsyncSelectionPage({required this.options, required this.hasMore});

  final List<AsyncSelectionOption<T>> options;
  final bool hasMore;
}

class AsyncSelectionOption<T extends Object> {
  const AsyncSelectionOption({
    required this.id,
    required this.label,
    required this.subtitle,
  });

  final T id;
  final String label;
  final String subtitle;

  String displayLabel(String Function(T id) fallbackLabelForId) {
    return label.isEmpty ? fallbackLabelForId(id) : label;
  }
}

class AsyncSelectionPickerStrings<T extends Object> {
  const AsyncSelectionPickerStrings({
    required this.title,
    required this.searchHint,
    required this.emptyText,
    required this.clearText,
    required this.clearSearchTooltip,
    required this.loadErrorText,
    required this.confirmText,
    required this.fallbackLabelForId,
  });

  final String title;
  final String searchHint;
  final String emptyText;
  final String clearText;
  final String clearSearchTooltip;
  final String loadErrorText;
  final String confirmText;
  final String Function(T id) fallbackLabelForId;
}

class AsyncSelectionFieldStrings<T extends Object> {
  const AsyncSelectionFieldStrings({
    required this.label,
    required this.emptyText,
    required this.helperText,
    required this.clearTooltip,
    required this.openPickerTooltip,
    required this.fallbackLabelForId,
  });

  final String label;
  final String emptyText;
  final String helperText;
  final String clearTooltip;
  final String openPickerTooltip;
  final String Function(T id) fallbackLabelForId;
}

Future<List<AsyncSelectionOption<T>>?>
showAsyncMultiSelectPicker<T extends Object>({
  required BuildContext context,
  required AsyncSelectionPickerStrings<T> strings,
  required List<AsyncSelectionOption<T>> selected,
  required AsyncSelectionPageLoader<T> loadPage,
  Key searchFieldKey = const ValueKey('async_selection_search_field'),
  Key applyButtonKey = const ValueKey('async_selection_apply_button'),
  Key Function(T id)? optionKeyForId,
  double heightFactor = 0.82,
  bool singleSelection = false,
  String initialSearch = '',
}) {
  return showAdaptiveModalBottomSheet<List<AsyncSelectionOption<T>>>(
    context: context,
    size: AdaptiveModalSize.expanded,
    maxHeightFactor: heightFactor,
    builder: (context) {
      return _AsyncMultiSelectPickerSheet<T>(
        strings: strings,
        selected: selected,
        loadPage: loadPage,
        searchFieldKey: searchFieldKey,
        applyButtonKey: applyButtonKey,
        optionKeyForId: optionKeyForId,
        singleSelection: singleSelection,
        initialSearch: initialSearch,
      );
    },
  );
}

class _AsyncMultiSelectPickerSheet<T extends Object> extends StatefulWidget {
  const _AsyncMultiSelectPickerSheet({
    required this.strings,
    required this.selected,
    required this.loadPage,
    required this.searchFieldKey,
    required this.applyButtonKey,
    required this.optionKeyForId,
    required this.singleSelection,
    required this.initialSearch,
  });

  final AsyncSelectionPickerStrings<T> strings;
  final List<AsyncSelectionOption<T>> selected;
  final AsyncSelectionPageLoader<T> loadPage;
  final Key searchFieldKey;
  final Key applyButtonKey;
  final Key Function(T id)? optionKeyForId;
  final bool singleSelection;
  final String initialSearch;

  @override
  State<_AsyncMultiSelectPickerSheet<T>> createState() =>
      _AsyncMultiSelectPickerSheetState<T>();
}

class _AsyncMultiSelectPickerSheetState<T extends Object>
    extends State<_AsyncMultiSelectPickerSheet<T>> {
  var _search = '';
  var _options = <AsyncSelectionOption<T>>[];
  var _selected = <T, AsyncSelectionOption<T>>{};
  var _isLoading = false;
  var _isLoadingMore = false;
  var _hasMore = true;
  var _hasError = false;
  var _nextPage = 1;

  @override
  void initState() {
    super.initState();
    _selected = {for (final item in widget.selected) item.id: item};
    _search = widget.initialSearch;
    _load(reset: true);
  }

  @override
  Widget build(BuildContext context) {
    final strings = widget.strings;
    final l10n = AppLocalizations.of(context)!;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  strings.title,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              TextButton(
                onPressed: _selected.isEmpty
                    ? null
                    : () => setState(() => _selected = {}),
                child: Text(strings.clearText),
              ),
            ],
          ),
          const SizedBox(height: 8),
          DebouncedSearchField(
            value: _search,
            hintText: strings.searchHint,
            clearTooltip: strings.clearSearchTooltip,
            fieldKey: widget.searchFieldKey,
            // Stay enabled while results load: disabling a focused TextField mid-
            // keystroke drops the keyboard/focus, so every search interrupted the
            // user's typing. The list shows its own loading state instead.
            onChanged: (value) {
              _search = value;
              _load(reset: true);
            },
          ),
          if (_selected.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final item in _selected.values)
                  InputChip(
                    label: Text(item.displayLabel(strings.fallbackLabelForId)),
                    onDeleted: () {
                      setState(() {
                        _selected.remove(item.id);
                      });
                    },
                  ),
              ],
            ),
          ],
          // A failed *next* page keeps the results already on screen, so the
          // failure is reported inline — but with its own retry, because the
          // load-more trigger is switched off once a page fails.
          if (_hasError && _options.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      strings.loadErrorText,
                      style: TextStyle(color: context.pointyColors.danger),
                    ),
                  ),
                  TextButton(
                    onPressed: _isLoadingMore ? null : _retry,
                    child: Text(l10n.retryButton),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 8),
          Expanded(
            // A failed first page empties the list, so the list's own empty
            // state would say "no results" — telling the user their search
            // matched nothing when the truth is we never got to ask. Report
            // the failure instead, and offer the retry: without it the only
            // way to load again is to edit the search text.
            child: _hasError && _options.isEmpty
                ? PointyErrorState(
                    icon: Icons.cloud_off_outlined,
                    title: strings.loadErrorText,
                    action: FilledButton.icon(
                      onPressed: _isLoading ? null : _retry,
                      icon: const Icon(Icons.refresh),
                      label: Text(l10n.retryButton),
                    ),
                  )
                : InfiniteScrollList<AsyncSelectionOption<T>>(
                    items: _options,
                    onLoadMore: () => _load(reset: false),
                    hasMore: _hasMore,
                    isLoadingInitial: _isLoading,
                    isLoadingMore: _isLoadingMore,
                    emptyBuilder: (context) =>
                        Center(child: Text(strings.emptyText)),
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, option) {
                      final isSelected = _selected.containsKey(option.id);
                      return CheckboxListTile(
                        key: widget.optionKeyForId?.call(option.id),
                        value: isSelected,
                        controlAffinity: ListTileControlAffinity.leading,
                        title: Text(
                          option.displayLabel(strings.fallbackLabelForId),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: option.subtitle.isEmpty
                            ? null
                            : Text(
                                option.subtitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                        onChanged: (_) => _toggle(option),
                      );
                    },
                  ),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            key: widget.applyButtonKey,
            onPressed: () {
              Navigator.of(context).pop(_selected.values.toList());
            },
            icon: const Icon(Icons.check),
            label: Text(strings.confirmText),
          ),
        ],
      ),
    );
  }

  /// Re-runs the load that failed. A first page that failed left the list
  /// empty, so it restarts from page one; a failed *next* page keeps what is
  /// already on screen and asks for that page again — which needs [_hasMore]
  /// switched back on, since the failure turned it off to stop the list
  /// re-triggering the same broken request.
  Future<void> _retry() async {
    final reset = _options.isEmpty;
    if (!reset) {
      setState(() => _hasMore = true);
    }
    await _load(reset: reset);
  }

  Future<void> _load({required bool reset}) async {
    if (reset) {
      setState(() {
        _isLoading = true;
        _hasError = false;
        _hasMore = true;
        _nextPage = 1;
      });
    } else {
      if (_isLoading || _isLoadingMore || !_hasMore) {
        return;
      }
      setState(() => _isLoadingMore = true);
    }

    try {
      final page = await widget.loadPage(_search, _nextPage);
      if (!mounted) {
        return;
      }
      setState(() {
        for (final option in page.options) {
          final selected = _selected[option.id];
          if (selected != null && selected.label.isEmpty) {
            _selected[option.id] = option;
          }
        }
        _options = reset ? page.options : [..._options, ...page.options];
        _hasMore = page.hasMore;
        _nextPage += 1;
        // A page that just arrived clears the previous failure, whichever
        // path asked for it: without this a successful mid-list retry
        // appends its rows while the red failure line stays above them,
        // so the screen reports a failure and its result at once.
        _hasError = false;
        _isLoading = false;
        _isLoadingMore = false;
      });
    } on Exception {
      if (!mounted) {
        return;
      }
      setState(() {
        if (reset) {
          _options = [];
        }
        _hasError = true;
        _hasMore = false;
        _isLoading = false;
        _isLoadingMore = false;
      });
    }
  }

  void _toggle(AsyncSelectionOption<T> option) {
    setState(() {
      if (_selected.containsKey(option.id)) {
        _selected.remove(option.id);
      } else {
        if (widget.singleSelection) {
          _selected = {};
        }
        _selected[option.id] = option;
      }
    });
  }
}

class AsyncSelectionField<T extends Object> extends StatelessWidget {
  const AsyncSelectionField({
    super.key,
    required this.fieldKey,
    required this.strings,
    required this.selected,
    required this.onPick,
    required this.onClear,
    required this.validator,
  });

  final Key fieldKey;
  final AsyncSelectionFieldStrings<T> strings;
  final List<AsyncSelectionOption<T>> selected;
  final VoidCallback onPick;
  final VoidCallback? onClear;
  final String? Function(List<AsyncSelectionOption<T>> selected) validator;

  @override
  Widget build(BuildContext context) {
    return FormField<List<AsyncSelectionOption<T>>>(
      initialValue: selected,
      validator: (_) => validator(selected),
      builder: (field) {
        return Material(
          color: context.pointyColors.surface,
          borderRadius: BorderRadius.circular(8),
          child: InkWell(
            key: fieldKey,
            onTap: onPick,
            child: InputDecorator(
              decoration: InputDecoration(
                labelText: strings.label,
                helperText: strings.helperText,
                errorText: field.errorText,
                isDense: true,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: selected.isEmpty
                        ? Text(
                            strings.emptyText,
                            style: TextStyle(
                              color: context.pointyColors.mutedInk,
                            ),
                          )
                        : Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              for (final item in selected)
                                Chip(
                                  visualDensity: VisualDensity.compact,
                                  label: Text(
                                    item.displayLabel(
                                      strings.fallbackLabelForId,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                  ),
                  if (onClear != null)
                    IconButton(
                      tooltip: strings.clearTooltip,
                      onPressed: onClear,
                      icon: const Icon(Icons.close),
                    ),
                  IconButton(
                    tooltip: strings.openPickerTooltip,
                    onPressed: onPick,
                    icon: const Icon(Icons.arrow_drop_down),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
