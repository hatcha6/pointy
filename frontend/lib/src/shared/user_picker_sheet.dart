import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../core/result.dart';
import '../data/models/pos_user.dart';
import '../data/repositories/user_repository.dart';
import 'async_selection/async_selection.dart';

/// One person picked from the shop's users, or null when the sheet is
/// dismissed. Carries the name so the caller can label the choice without
/// fetching the user again.
class PickedUser {
  const PickedUser({required this.id, required this.name});

  final int id;
  final String name;
}

/// Search-as-you-type picker over the shop's users, paginated.
///
/// Wraps the shared async picker rather than re-implementing the search,
/// paging and empty states — the same component the payroll forms pick an
/// employee's login with.
Future<PickedUser?> showUserPickerSheet({
  required BuildContext context,
  required UserRepository repository,
  int? selectedId,
  String? selectedName,
}) async {
  final l10n = AppLocalizations.of(context)!;
  final picked = await showAsyncMultiSelectPicker<int>(
    context: context,
    strings: AsyncSelectionPickerStrings<int>(
      title: l10n.userPickerTitle,
      searchHint: l10n.userPickerSearchHint,
      emptyText: l10n.userPickerEmpty,
      clearText: l10n.userPickerClear,
      clearSearchTooltip: l10n.clearSearchTooltip,
      loadErrorText: l10n.userPickerLoadError,
      confirmText: l10n.confirmButton,
      fallbackLabelForId: (id) => l10n.userFallbackLabel(id),
    ),
    selected: [
      if (selectedId != null)
        AsyncSelectionOption<int>(
          id: selectedId,
          label: selectedName ?? '',
          subtitle: '',
        ),
    ],
    loadPage: (search, page) => _loadPage(repository, search, page),
    optionKeyForId: (id) => ValueKey('user_picker_option_$id'),
    heightFactor: 0.74,
    singleSelection: true,
  );

  if (picked == null || picked.isEmpty) {
    return null;
  }
  final option = picked.last;
  return PickedUser(
    id: option.id,
    name: option.displayLabel((id) => l10n.userFallbackLabel(id)),
  );
}

Future<AsyncSelectionPage<int>> _loadPage(
  UserRepository repository,
  String search,
  int page,
) async {
  final result = await repository.loadUsers(search: search, page: page);
  return switch (result) {
    Ok<PosUserPage>(value: final userPage) => AsyncSelectionPage<int>(
      options: [
        for (final user in userPage.users)
          AsyncSelectionOption<int>(
            id: user.id,
            label: user.label,
            subtitle: user.username,
          ),
      ],
      hasMore: userPage.hasMore,
    ),
    Error<PosUserPage>(:final exception) => throw exception,
  };
}
