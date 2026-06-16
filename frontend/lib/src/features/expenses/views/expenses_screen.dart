import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../core/result.dart';
import '../../../data/models/expense.dart';
import '../../../data/models/expense_category.dart';
import '../../../data/models/expense_ledger_entry.dart';
import '../../../shared/app_navigation_drawer.dart';
import '../../../shared/authorization_guards.dart';
import '../../../shared/components/components.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../view_models/expense_categories_view_model.dart';
import '../view_models/expenses_view_model.dart';
import 'expense_categories_page.dart';

/// The unified expenses screen: a month-bounded ledger of every kind of money
/// leaving the shop, with source filters and inline recording/editing of
/// ad-hoc expenses.
class ExpensesScreen extends StatefulWidget {
  const ExpensesScreen({
    super.key,
    required this.viewModel,
    required this.categoriesViewModel,
    required this.capabilities,
    required this.navigation,
  });

  final ExpensesViewModel viewModel;
  final ExpenseCategoriesViewModel categoriesViewModel;
  final AuthorizationCapabilities capabilities;
  final AppNavigation navigation;

  @override
  State<ExpensesScreen> createState() => _ExpensesScreenState();
}

class _ExpensesScreenState extends State<ExpensesScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      unawaited(widget.viewModel.load());
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.viewModel,
      builder: (context, _) {
        final l10n = AppLocalizations.of(context)!;
        final viewModel = widget.viewModel;
        final canManage = widget.capabilities.canManageExpenses;

        return PointyScaffold(
          drawer: AppNavigationDrawer(
            selectedDestination: AppNavigationDestination.expenses,
            navigation: widget.navigation,
          ),
          appBar: AppBar(
            leading: const PointyNavigationMenuButton(),
            title: Text(l10n.expensesTitle),
            actions: [
              if (canManage)
                IconButton(
                  tooltip: l10n.expenseAddButton,
                  onPressed: viewModel.isMutating
                      ? null
                      : () => _openEditor(context),
                  icon: const Icon(Icons.add),
                ),
              if (canManage)
                IconButton(
                  tooltip: l10n.expenseCategoriesSectionTitle,
                  onPressed: viewModel.isMutating
                      ? null
                      : () => _openCategories(context),
                  icon: const Icon(Icons.sell_outlined),
                ),
              IconButton(
                tooltip: l10n.expensesRefreshTooltip,
                onPressed: viewModel.isLoading ? null : viewModel.load,
                icon: const Icon(Icons.sync),
              ),
            ],
          ),
          body: AuthorizationGuard(
            capabilities: widget.capabilities,
            capability: AppCapability.viewExpenses,
            child: _buildBody(context, l10n),
          ),
        );
      },
    );
  }

  Widget _buildBody(BuildContext context, AppLocalizations l10n) {
    final viewModel = widget.viewModel;
    final spacing = AdaptiveSpacing.of(context);

    return Column(
      children: [
        Padding(
          padding: spacing.pagePadding,
          child: AdaptiveMaxWidth(
            width: AppContentWidth.list,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _PeriodHeader(viewModel: viewModel),
                const SizedBox(height: 12),
                _SourceFilters(viewModel: viewModel),
              ],
            ),
          ),
        ),
        const Divider(height: 1),
        Expanded(child: _buildList(context, l10n)),
      ],
    );
  }

  Widget _buildList(BuildContext context, AppLocalizations l10n) {
    final viewModel = widget.viewModel;
    final spacing = AdaptiveSpacing.of(context);

    if (viewModel.isLoading && viewModel.ledger.entries.isEmpty) {
      return const PointyLoadingArea();
    }

    if (viewModel.hasLoadError && viewModel.ledger.entries.isEmpty) {
      return PointyErrorState(
        title: l10n.expensesLoadError,
        icon: Icons.receipt_long_outlined,
        action: FilledButton.icon(
          onPressed: viewModel.load,
          icon: const Icon(Icons.sync),
          label: Text(l10n.retryButton),
        ),
      );
    }

    final entries = viewModel.visibleEntries;
    if (entries.isEmpty) {
      return PointyEmptyState(
        icon: Icons.receipt_long_outlined,
        title: viewModel.ledger.entries.isEmpty
            ? l10n.expensesEmptyMessage
            : l10n.expensesNoMatchingMessage,
        action: widget.capabilities.canManageExpenses
            ? FilledButton.icon(
                onPressed: () => _openEditor(context),
                icon: const Icon(Icons.add),
                label: Text(l10n.expenseAddButton),
              )
            : null,
      );
    }

    return ListView.separated(
      padding: spacing.pagePadding,
      itemCount: entries.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final entry = entries[index];
        return AdaptiveMaxWidth(
          width: AppContentWidth.list,
          child: _LedgerEntryTile(
            entry: entry,
            canManage: widget.capabilities.canManageExpenses,
            isBusy: viewModel.isMutating,
            onEdit: () => _editEntry(context, entry),
            onDelete: () => _confirmDelete(context, entry),
          ),
        );
      },
    );
  }

  Future<void> _editEntry(
    BuildContext context,
    ExpenseLedgerEntry entry,
  ) async {
    if (!entry.isEditable || entry.relatedId == null) {
      return;
    }
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final result = await widget.viewModel.loadExpense(entry.relatedId!);
    if (!context.mounted) {
      return;
    }
    switch (result) {
      case Ok<Expense>():
        await _openEditor(context, expense: result.value);
      case Error<Expense>():
        messenger.showSnackBar(
          SnackBar(content: Text(l10n.expenseLoadDetailsError)),
        );
    }
  }

  Future<void> _openCategories(BuildContext context) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            ExpenseCategoriesPage(viewModel: widget.categoriesViewModel),
      ),
    );
    // Categories drive the editor dropdown — refresh so new ones show up.
    await widget.viewModel.load();
  }

  Future<void> _openEditor(BuildContext context, {Expense? expense}) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final categories = widget.viewModel.activeCategories;
    if (categories.isEmpty && expense == null) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.expenseNeedsCategoryMessage)),
      );
      return;
    }
    final draft = await showDialog<ExpenseDraft>(
      context: context,
      builder: (_) =>
          _ExpenseEditorDialog(expense: expense, categories: categories),
    );
    if (draft == null) {
      return;
    }
    final saved = expense == null
        ? await widget.viewModel.createExpense(draft)
        : await widget.viewModel.updateExpense(expense.id, draft);
    if (!saved) {
      messenger.showSnackBar(SnackBar(content: Text(l10n.expenseSaveError)));
    }
  }

  Future<void> _confirmDelete(
    BuildContext context,
    ExpenseLedgerEntry entry,
  ) async {
    if (entry.relatedId == null) {
      return;
    }
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        icon: const Icon(Icons.delete_outline),
        title: Text(l10n.expenseDeleteTitle),
        content: Text(l10n.expenseDeleteMessage),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.cancelButton),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.deleteButton),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }
    final deleted = await widget.viewModel.deleteExpense(entry.relatedId!);
    if (!deleted) {
      messenger.showSnackBar(SnackBar(content: Text(l10n.expenseDeleteError)));
    }
  }
}

class _PeriodHeader extends StatelessWidget {
  const _PeriodHeader({required this.viewModel});

  final ExpensesViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            IconButton(
              tooltip: l10n.expensesPreviousMonth,
              onPressed: viewModel.isLoading
                  ? null
                  : viewModel.showPreviousMonth,
              icon: const Icon(Icons.chevron_left),
            ),
            Expanded(
              child: Column(
                children: [
                  Text(
                    formatMonthYear(viewModel.periodStart),
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    l10n.expensesPeriodTotal(
                      formatMoney(viewModel.visibleTotal),
                    ),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: context.pointyColors.mutedInk,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: l10n.expensesNextMonth,
              onPressed: viewModel.isLoading || viewModel.isCurrentMonth
                  ? null
                  : viewModel.showNextMonth,
              icon: const Icon(Icons.chevron_right),
            ),
          ],
        ),
      ),
    );
  }
}

class _SourceFilters extends StatelessWidget {
  const _SourceFilters({required this.viewModel});

  final ExpensesViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    const sources = [
      ExpenseLedgerSource.expense,
      ExpenseLedgerSource.registerPayout,
      ExpenseLedgerSource.purchase,
      ExpenseLedgerSource.payroll,
      ExpenseLedgerSource.commission,
    ];
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      children: [
        for (final source in sources)
          FilterChip(
            label: Text(expenseSourceLabel(l10n, source)),
            selected: viewModel.isSourceVisible(source),
            onSelected: (_) => viewModel.toggleSource(source),
          ),
      ],
    );
  }
}

class _LedgerEntryTile extends StatelessWidget {
  const _LedgerEntryTile({
    required this.entry,
    required this.canManage,
    required this.isBusy,
    required this.onEdit,
    required this.onDelete,
  });

  final ExpenseLedgerEntry entry;
  final bool canManage;
  final bool isBusy;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final color = expenseSourceColor(entry.source);
    final subtitleParts = <String>[
      formatDate(entry.date),
      if (entry.category != null && entry.category!.isNotEmpty) entry.category!,
      if (entry.source == ExpenseLedgerSource.expense &&
          entry.paymentMethod.isNotEmpty)
        expensePaymentMethodLabel(l10n, entry.paymentMethod),
    ];
    final editable = canManage && entry.isEditable;

    return ListTile(
      leading: CircleAvatar(
        radius: 18,
        backgroundColor: color.withValues(alpha: 0.16),
        child: Icon(expenseSourceIcon(entry.source), size: 18, color: color),
      ),
      title: Text(
        entry.description.isEmpty
            ? expenseSourceLabel(l10n, entry.source)
            : entry.description,
      ),
      subtitle: Text(subtitleParts.join(' · ')),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(formatMoney(entry.amount), style: theme.textTheme.titleMedium),
          if (editable) ...[
            const SizedBox(width: 4),
            IconButton(
              tooltip: l10n.editButton,
              onPressed: isBusy ? null : onEdit,
              icon: const Icon(Icons.edit_outlined),
            ),
            IconButton(
              tooltip: l10n.deleteButton,
              onPressed: isBusy ? null : onDelete,
              icon: const Icon(Icons.delete_outline),
            ),
          ] else
            _SourceBadge(
              label: expenseSourceLabel(l10n, entry.source),
              color: color,
            ),
        ],
      ),
      onTap: editable && !isBusy ? onEdit : null,
    );
  }
}

class _SourceBadge extends StatelessWidget {
  const _SourceBadge({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsetsDirectional.only(start: 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(color: color),
        ),
      ),
    );
  }
}

// --- source presentation helpers --------------------------------------------

String expenseSourceLabel(AppLocalizations l10n, ExpenseLedgerSource source) {
  return switch (source) {
    ExpenseLedgerSource.expense => l10n.expenseSourceAdHoc,
    ExpenseLedgerSource.registerPayout => l10n.expenseSourceRegisterPayout,
    ExpenseLedgerSource.purchase => l10n.expenseSourcePurchase,
    ExpenseLedgerSource.payroll => l10n.expenseSourcePayroll,
    ExpenseLedgerSource.commission => l10n.expenseSourceCommission,
    ExpenseLedgerSource.unknown => l10n.expenseSourceOther,
  };
}

IconData expenseSourceIcon(ExpenseLedgerSource source) {
  return switch (source) {
    ExpenseLedgerSource.expense => Icons.receipt_outlined,
    ExpenseLedgerSource.registerPayout => Icons.point_of_sale_outlined,
    ExpenseLedgerSource.purchase => Icons.local_shipping_outlined,
    ExpenseLedgerSource.payroll => Icons.badge_outlined,
    ExpenseLedgerSource.commission => Icons.credit_card_outlined,
    ExpenseLedgerSource.unknown => Icons.payments_outlined,
  };
}

Color expenseSourceColor(ExpenseLedgerSource source) {
  return switch (source) {
    ExpenseLedgerSource.expense => Colors.teal,
    ExpenseLedgerSource.registerPayout => Colors.orange,
    ExpenseLedgerSource.purchase => Colors.indigo,
    ExpenseLedgerSource.payroll => Colors.purple,
    ExpenseLedgerSource.commission => Colors.blueGrey,
    ExpenseLedgerSource.unknown => Colors.grey,
  };
}

String expensePaymentMethodLabel(AppLocalizations l10n, String method) {
  return switch (method) {
    'cash' => l10n.expensePaymentCash,
    'card' => l10n.expensePaymentCard,
    'transfer' => l10n.expensePaymentTransfer,
    _ => method,
  };
}

class _ExpenseEditorDialog extends StatefulWidget {
  const _ExpenseEditorDialog({required this.expense, required this.categories});

  final Expense? expense;
  final List<ExpenseCategory> categories;

  @override
  State<_ExpenseEditorDialog> createState() => _ExpenseEditorDialogState();
}

class _ExpenseEditorDialogState extends State<_ExpenseEditorDialog> {
  late final TextEditingController _descriptionController =
      TextEditingController(text: widget.expense?.description ?? '');
  late final TextEditingController _amountController = TextEditingController(
    text: widget.expense == null
        ? ''
        : widget.expense!.amount.toStringAsFixed(2),
  );
  late final TextEditingController _referenceController = TextEditingController(
    text: widget.expense?.reference ?? '',
  );
  late final TextEditingController _notesController = TextEditingController(
    text: widget.expense?.notes ?? '',
  );

  late int? _categoryId = _initialCategoryId();
  late ExpensePaymentMethod _method =
      widget.expense?.paymentMethod ?? ExpensePaymentMethod.cash;
  late DateTime _spentAt = widget.expense?.spentAt ?? DateTime.now();
  bool _payFromRegister = false;

  int? _initialCategoryId() {
    final existing = widget.expense?.categoryId;
    if (existing != null &&
        widget.categories.any((category) => category.id == existing)) {
      return existing;
    }
    return widget.categories.isNotEmpty ? widget.categories.first.id : null;
  }

  @override
  void dispose() {
    _descriptionController.dispose();
    _amountController.dispose();
    _referenceController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  bool get _isValid {
    final amount = double.tryParse(_amountController.text.trim());
    return _categoryId != null &&
        _descriptionController.text.trim().isNotEmpty &&
        amount != null &&
        amount > 0;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      icon: const Icon(Icons.receipt_outlined),
      title: Text(
        widget.expense == null ? l10n.expenseAddButton : l10n.expenseEditTitle,
      ),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DropdownButtonFormField<int>(
                initialValue: _categoryId,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: l10n.expenseCategoryLabel,
                  isDense: true,
                ),
                items: [
                  for (final category in widget.categories)
                    DropdownMenuItem(
                      value: category.id,
                      child: Text(category.name),
                    ),
                ],
                onChanged: (value) => setState(() => _categoryId = value),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _descriptionController,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: l10n.expenseDescriptionLabel,
                  isDense: true,
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _amountController,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: InputDecoration(
                  labelText: l10n.expenseAmountLabel,
                  isDense: true,
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<ExpensePaymentMethod>(
                initialValue: _method,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: l10n.expensePaymentMethodLabel,
                  isDense: true,
                ),
                items: [
                  DropdownMenuItem(
                    value: ExpensePaymentMethod.cash,
                    child: Text(l10n.expensePaymentCash),
                  ),
                  DropdownMenuItem(
                    value: ExpensePaymentMethod.card,
                    child: Text(l10n.expensePaymentCard),
                  ),
                  DropdownMenuItem(
                    value: ExpensePaymentMethod.transfer,
                    child: Text(l10n.expensePaymentTransfer),
                  ),
                ],
                onChanged: (value) => setState(
                  () => _method = value ?? ExpensePaymentMethod.cash,
                ),
              ),
              const SizedBox(height: 8),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(l10n.expenseDateLabel),
                subtitle: Text(formatDate(_spentAt)),
                trailing: const Icon(Icons.calendar_today_outlined),
                onTap: _pickDate,
              ),
              TextField(
                controller: _referenceController,
                decoration: InputDecoration(
                  labelText: l10n.expenseReferenceLabel,
                  isDense: true,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _notesController,
                minLines: 1,
                maxLines: 3,
                decoration: InputDecoration(
                  labelText: l10n.expenseNotesLabel,
                  isDense: true,
                ),
              ),
              // Drawer linkage is decided per-expense, only for cash and only
              // for new expenses (an existing expense's pay-out already happened).
              if (widget.expense == null &&
                  _method == ExpensePaymentMethod.cash)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(l10n.expensePayFromRegisterLabel),
                  subtitle: Text(l10n.expensePayFromRegisterHint),
                  value: _payFromRegister,
                  onChanged: (value) =>
                      setState(() => _payFromRegister = value),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancelButton),
        ),
        FilledButton(
          onPressed: _isValid ? _submit : null,
          child: Text(l10n.saveButton),
        ),
      ],
    );
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _spentAt,
      firstDate: DateTime(now.year - 5),
      lastDate: now,
    );
    if (picked != null) {
      setState(() => _spentAt = picked);
    }
  }

  void _submit() {
    Navigator.of(context).pop(
      ExpenseDraft(
        categoryId: _categoryId!,
        description: _descriptionController.text.trim(),
        amount: double.parse(_amountController.text.trim()),
        paymentMethod: _method,
        spentAt: _spentAt,
        reference: _referenceController.text.trim(),
        notes: _notesController.text.trim(),
        payFromRegister:
            widget.expense == null &&
            _method == ExpensePaymentMethod.cash &&
            _payFromRegister,
      ),
    );
  }
}
