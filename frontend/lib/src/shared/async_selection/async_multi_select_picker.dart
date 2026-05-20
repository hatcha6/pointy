import 'package:flutter/material.dart';

import '../infinite_scroll_grid.dart';
import '../query_controls/debounced_search_field.dart';

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
}) {
  return showModalBottomSheet<List<AsyncSelectionOption<T>>>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (context) {
      return FractionallySizedBox(
        heightFactor: heightFactor,
        child: _AsyncMultiSelectPickerSheet<T>(
          strings: strings,
          selected: selected,
          loadPage: loadPage,
          searchFieldKey: searchFieldKey,
          applyButtonKey: applyButtonKey,
          optionKeyForId: optionKeyForId,
        ),
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
  });

  final AsyncSelectionPickerStrings<T> strings;
  final List<AsyncSelectionOption<T>> selected;
  final AsyncSelectionPageLoader<T> loadPage;
  final Key searchFieldKey;
  final Key applyButtonKey;
  final Key Function(T id)? optionKeyForId;

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
    _load(reset: true);
  }

  @override
  Widget build(BuildContext context) {
    final strings = widget.strings;

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
            enabled: !_isLoading,
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
          if (_hasError)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                strings.loadErrorText,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          const SizedBox(height: 8),
          Expanded(
            child: InfiniteScrollList<AsyncSelectionOption<T>>(
              items: _options,
              onLoadMore: () => _load(reset: false),
              hasMore: _hasMore,
              isLoadingInitial: _isLoading,
              isLoadingMore: _isLoadingMore,
              emptyBuilder: (context) => Center(child: Text(strings.emptyText)),
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
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(8),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: fieldKey,
            onTap: onPick,
            child: InputDecorator(
              decoration: InputDecoration(
                labelText: strings.label,
                helperText: strings.helperText,
                errorText: field.errorText,
                border: const OutlineInputBorder(),
                enabledBorder: const OutlineInputBorder(),
                isDense: true,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: selected.isEmpty
                        ? Text(
                            strings.emptyText,
                            style: TextStyle(
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
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
