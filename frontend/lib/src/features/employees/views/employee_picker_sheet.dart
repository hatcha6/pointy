import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/result.dart';
import '../../../data/models/employee.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/query_controls/debounced_search_field.dart';
import '../../../shared/query_controls/query_empty_state.dart';
import '../../../shared/responsive/responsive.dart';
import 'payroll_labels.dart';

typedef EmployeePageLoader =
    Future<Result<EmployeePage>> Function(String search, int page);

/// Chooses whose loan it is, searching the whole staff list on the server.
///
/// Staff payroll no longer pays are listed, not hidden, but cannot be chosen,
/// and say why: a name that went missing from the list would be a mystery,
/// while one that is there and greyed out answers the question itself.
Future<Employee?> showEmployeePickerSheet(
  BuildContext context, {
  required EmployeePageLoader loadPage,
  int? selectedId,
}) {
  return showAdaptiveModalBottomSheet<Employee?>(
    context: context,
    size: AdaptiveModalSize.standard,
    maxHeightFactor: 0.9,
    builder: (_) =>
        _EmployeePickerSheet(loadPage: loadPage, selectedId: selectedId),
  );
}

class _EmployeePickerSheet extends StatefulWidget {
  const _EmployeePickerSheet({required this.loadPage, this.selectedId});

  final EmployeePageLoader loadPage;
  final int? selectedId;

  @override
  State<_EmployeePickerSheet> createState() => _EmployeePickerSheetState();
}

class _EmployeePickerSheetState extends State<_EmployeePickerSheet> {
  var _search = '';
  var _employees = <Employee>[];
  var _isLoading = true;
  var _isLoadingMore = false;
  var _hasMore = true;
  var _hasError = false;
  var _loadMoreFailed = false;
  var _nextPage = 1;
  // Stale pages from a search the user has already typed past are dropped.
  var _ticket = 0;

  @override
  void initState() {
    super.initState();
    _load(reset: true);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.86,
      ),
      child: Padding(
        padding: EdgeInsetsDirectional.fromSTEB(
          spacing.lg,
          0,
          spacing.lg,
          spacing.lg,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.employeePickerTitle,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            SizedBox(height: spacing.md),
            DebouncedSearchField(
              fieldKey: const ValueKey('employee_picker_search'),
              value: _search,
              hintText: l10n.employeePickerSearchHint,
              clearTooltip: l10n.clearSearchTooltip,
              onChanged: (value) {
                _search = value;
                _load(reset: true);
              },
            ),
            SizedBox(height: spacing.sm),
            Expanded(
              child: PointyDataList<Employee>(
                items: _employees,
                onLoadMore: () => _load(reset: false),
                hasMore: _hasMore,
                isLoadingInitial: _isLoading,
                isLoadingMore: _isLoadingMore,
                hasError: _hasError,
                loadMoreFailed: _loadMoreFailed,
                loadMoreErrorMessage: l10n.employeesLoadError,
                errorBuilder: (context) => PointyErrorState(
                  title: l10n.employeesLoadError,
                  icon: Icons.person_search_outlined,
                  action: FilledButton.tonalIcon(
                    onPressed: () => _load(reset: true),
                    icon: const Icon(Icons.sync),
                    label: Text(l10n.retryButton),
                  ),
                ),
                emptyBuilder: (context) => QueryEmptyState(
                  icon: Icons.badge_outlined,
                  search: _search,
                  hasFilters: false,
                  emptyTitle: l10n.employeePickerEmpty,
                  onClear: () {
                    _search = '';
                    _load(reset: true);
                  },
                ),
                padding: EdgeInsets.zero,
                framed: false,
                itemBuilder: (context, employee) => _EmployeeOption(
                  employee: employee,
                  selected: employee.id == widget.selectedId,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _load({required bool reset}) async {
    final ticket = ++_ticket;
    if (reset) {
      setState(() {
        _isLoading = true;
        _hasError = false;
        _hasMore = true;
        _loadMoreFailed = false;
        _nextPage = 1;
      });
    } else {
      if (_isLoading || _isLoadingMore || !_hasMore) {
        return;
      }
      setState(() {
        _isLoadingMore = true;
        _loadMoreFailed = false;
      });
    }

    final result = await widget.loadPage(_search, _nextPage);
    if (!mounted || ticket != _ticket) {
      return;
    }
    setState(() {
      switch (result) {
        case Ok<EmployeePage>(value: final page):
          _employees = reset
              ? page.employees
              : [..._employees, ...page.employees];
          _hasMore = page.hasMore;
          _nextPage += 1;
        case Error<EmployeePage>():
          if (reset) {
            _employees = [];
            _hasError = true;
          } else {
            // Keep what is on screen and offer the page again; a failed page
            // must not look like the end of the list.
            _loadMoreFailed = true;
          }
      }
      _isLoading = false;
      _isLoadingMore = false;
    });
  }
}

class _EmployeeOption extends StatelessWidget {
  const _EmployeeOption({required this.employee, required this.selected});

  final Employee employee;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final details = [
      if (employee.employeeNumber.isNotEmpty) employee.employeeNumber,
      if (employee.jobTitle.isNotEmpty) employee.jobTitle,
    ];
    final choosable = employee.isOnPayroll;

    final row = PointyDataRow(
      key: ValueKey('employee_option_${employee.id}'),
      leading: EmployeeInitialAvatar(name: employee.fullName),
      title: employee.fullName,
      subtitle: details.isEmpty ? null : details.join(' · '),
      selected: selected,
      minHeight: 60,
      onTap: choosable ? () => Navigator.of(context).pop(employee) : null,
      badges: [
        if (!choosable)
          PointyStatusPill(
            label: l10n.employeeOffPayrollLabel,
            icon: Icons.block_outlined,
            color: colors.mutedInk,
          )
        else if (employee.status != EmployeeStatus.active)
          PointyStatusPill(
            label: employeeStatusLabel(l10n, employee.status),
            icon: Icons.circle_outlined,
            color: employeeStatusColor(context, employee.status),
          ),
      ],
    );
    return choosable ? row : Opacity(opacity: 0.6, child: row);
  }
}

/// A round badge with the first letter of [name] — tells people apart in a
/// list faster than the same icon repeated down every row.
class EmployeeInitialAvatar extends StatelessWidget {
  const EmployeeInitialAvatar({super.key, required this.name, this.radius});

  final String name;
  final double? radius;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final trimmed = name.trim();
    return CircleAvatar(
      radius: radius,
      backgroundColor: colors.subtleFill,
      foregroundColor: colors.primaryStrong,
      child: trimmed.isEmpty
          ? const Icon(Icons.person_outline)
          : Text(
              trimmed.characters.first,
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
    );
  }
}
