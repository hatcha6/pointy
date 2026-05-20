import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/result.dart';
import '../../../data/models/contact.dart';
import '../../../data/models/discount_rule.dart';
import '../../../data/models/product_query.dart';
import '../../../data/repositories/catalog_repository.dart';
import '../../../data/repositories/contact_repository.dart';
import '../../../shared/decimal_text_input_formatter.dart';
import '../../../shared/infinite_scroll_grid.dart';
import '../../../shared/query_controls/debounced_search_field.dart';
import '../view_models/discount_management_view_model.dart';

class DiscountRuleForm extends StatefulWidget {
  const DiscountRuleForm({
    super.key,
    required this.viewModel,
    required this.catalogRepository,
    required this.contactRepository,
    required this.onSaved,
    this.rule,
  });

  final DiscountManagementViewModel viewModel;
  final CatalogRepository catalogRepository;
  final ContactRepository contactRepository;
  final DiscountRule? rule;
  final VoidCallback onSaved;

  @override
  State<DiscountRuleForm> createState() => _DiscountRuleFormState();
}

class _DiscountRuleFormState extends State<DiscountRuleForm> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _descriptionController;
  late final TextEditingController _couponCodeController;
  late final TextEditingController _valueController;
  late final TextEditingController _maxDiscountController;
  late final TextEditingController _minSubtotalController;
  late final TextEditingController _minLineQuantityController;
  late final TextEditingController _priorityController;
  late final TextEditingController _usageLimitController;
  late final TextEditingController _perCustomerLimitController;
  late final TextEditingController _perSupplierLimitController;

  late DiscountChannel _channel;
  late DiscountApplicationType _applicationType;
  late DiscountScope _scope;
  late DiscountValueType _valueType;
  late bool _exclusive;
  late bool _isActive;
  late List<_DiscountConstraintSelection> _selectedProducts;
  late List<_DiscountConstraintSelection> _selectedCustomers;
  late List<_DiscountConstraintSelection> _selectedSuppliers;
  DateTime? _startsAt;
  DateTime? _endsAt;

  @override
  void initState() {
    super.initState();
    final rule = widget.rule;
    _nameController = TextEditingController(text: rule?.name ?? '');
    _descriptionController = TextEditingController(
      text: rule?.description ?? '',
    );
    _couponCodeController = TextEditingController(text: rule?.couponCode ?? '');
    _valueController = TextEditingController(
      text: rule == null ? '' : _formatDecimal(rule.value),
    );
    _maxDiscountController = TextEditingController(
      text: rule?.maxDiscountAmount == null
          ? ''
          : _formatMoney(rule!.maxDiscountAmount!),
    );
    _minSubtotalController = TextEditingController(
      text: rule == null ? '0.00' : _formatMoney(rule.minOrderSubtotal),
    );
    _minLineQuantityController = TextEditingController(
      text: rule?.minLineQuantity?.toString() ?? '',
    );
    _priorityController = TextEditingController(
      text: '${rule?.priority ?? 100}',
    );
    _usageLimitController = TextEditingController(
      text: rule?.usageLimit?.toString() ?? '',
    );
    _perCustomerLimitController = TextEditingController(
      text: rule?.perCustomerUsageLimit?.toString() ?? '',
    );
    _perSupplierLimitController = TextEditingController(
      text: rule?.perSupplierUsageLimit?.toString() ?? '',
    );
    _channel = rule?.channel ?? DiscountChannel.sales;
    _applicationType =
        rule?.applicationType ?? DiscountApplicationType.automatic;
    _scope = rule?.scope ?? DiscountScope.document;
    _valueType = rule?.valueType ?? DiscountValueType.percentage;
    _exclusive = rule?.exclusive ?? true;
    _isActive = rule?.isActive ?? true;
    _selectedProducts = _selectionsFromIds(rule?.products ?? const []);
    _selectedCustomers = _selectionsFromIds(rule?.customers ?? const []);
    _selectedSuppliers = _selectionsFromIds(rule?.suppliers ?? const []);
    _startsAt = rule?.startsAt;
    _endsAt = rule?.endsAt;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    _couponCodeController.dispose();
    _valueController.dispose();
    _maxDiscountController.dispose();
    _minSubtotalController.dispose();
    _minLineQuantityController.dispose();
    _priorityController.dispose();
    _usageLimitController.dispose();
    _perCustomerLimitController.dispose();
    _perSupplierLimitController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Form(
      key: _formKey,
      child: ListView(
        key: const ValueKey('discount_rule_form_scroll'),
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        children: [
          Text(
            widget.rule == null
                ? l10n.discountCreateTitle
                : l10n.discountEditTitle,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _nameController,
            textInputAction: TextInputAction.next,
            decoration: InputDecoration(
              labelText: l10n.discountNameLabel,
              border: const OutlineInputBorder(),
              isDense: true,
            ),
            validator: (value) => value == null || value.trim().isEmpty
                ? l10n.requiredFieldError
                : null,
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _descriptionController,
            maxLines: 2,
            decoration: InputDecoration(
              labelText: l10n.discountDescriptionLabel,
              border: const OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 16),
          _SectionTitle(title: l10n.discountBasicsSection),
          _SegmentedField<DiscountChannel>(
            label: l10n.discountChannelLabel,
            selected: _channel,
            values: DiscountChannel.values,
            labelFor: (value) => _channelLabel(l10n, value),
            onSelected: (value) => setState(() => _channel = value),
          ),
          const SizedBox(height: 12),
          _SegmentedField<DiscountApplicationType>(
            label: l10n.discountApplicationTypeLabel,
            selected: _applicationType,
            values: DiscountApplicationType.values,
            labelFor: (value) => _applicationLabel(l10n, value),
            onSelected: (value) => setState(() => _applicationType = value),
          ),
          if (_applicationType == DiscountApplicationType.couponCode) ...[
            const SizedBox(height: 12),
            TextFormField(
              controller: _couponCodeController,
              textCapitalization: TextCapitalization.characters,
              decoration: InputDecoration(
                labelText: l10n.discountCouponCodeLabel,
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              validator: (value) {
                if (_applicationType == DiscountApplicationType.couponCode &&
                    (value == null || value.trim().isEmpty)) {
                  return l10n.requiredFieldError;
                }
                return null;
              },
            ),
          ],
          const SizedBox(height: 12),
          _SegmentedField<DiscountScope>(
            label: l10n.discountScopeLabel,
            selected: _scope,
            values: DiscountScope.values,
            labelFor: (value) => _scopeLabel(l10n, value),
            onSelected: (value) => setState(() => _scope = value),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<DiscountValueType>(
            initialValue: _valueType,
            isExpanded: true,
            decoration: InputDecoration(
              labelText: l10n.discountValueTypeLabel,
              border: const OutlineInputBorder(),
              isDense: true,
            ),
            items: [
              for (final type in DiscountValueType.values)
                DropdownMenuItem(
                  value: type,
                  child: Text(_valueTypeLabel(l10n, type)),
                ),
            ],
            onChanged: (value) {
              if (value == null) {
                return;
              }
              setState(() {
                _valueType = value;
                if (value == DiscountValueType.fixedPrice ||
                    value == DiscountValueType.fixedUnitAmount) {
                  _scope = DiscountScope.line;
                }
              });
            },
          ),
          const SizedBox(height: 12),
          _ResponsiveFields(
            children: [
              TextFormField(
                controller: _valueController,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                inputFormatters: [DecimalTextInputFormatter()],
                decoration: InputDecoration(
                  labelText: l10n.discountValueLabel,
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
                validator: _validatePositiveDecimal,
              ),
              TextFormField(
                controller: _maxDiscountController,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                inputFormatters: [DecimalTextInputFormatter()],
                decoration: InputDecoration(
                  labelText: l10n.discountMaxAmountLabel,
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
                validator: _validateOptionalPositiveAmount,
              ),
              TextFormField(
                controller: _priorityController,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: InputDecoration(
                  labelText: l10n.discountPriorityLabel,
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
                validator: _validatePositiveInteger,
              ),
            ],
          ),
          const SizedBox(height: 12),
          SwitchListTile(
            value: _exclusive,
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(l10n.discountExclusiveLabel),
            subtitle: Text(l10n.discountExclusiveHelper),
            onChanged: (value) => setState(() => _exclusive = value),
          ),
          SwitchListTile(
            value: _isActive,
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(l10n.discountActiveLabel),
            onChanged: (value) => setState(() => _isActive = value),
          ),
          const SizedBox(height: 16),
          _SectionTitle(title: l10n.discountConditionsSection),
          _ResponsiveFields(
            children: [
              TextFormField(
                controller: _minSubtotalController,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                inputFormatters: [DecimalTextInputFormatter()],
                decoration: InputDecoration(
                  labelText: l10n.discountMinSubtotalLabel,
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
                validator: _validateOptionalNonNegativeDecimal,
              ),
              TextFormField(
                controller: _minLineQuantityController,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: InputDecoration(
                  labelText: l10n.discountMinLineQuantityLabel,
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
                validator: _validateOptionalPositiveInteger,
              ),
            ],
          ),
          const SizedBox(height: 12),
          _ResponsiveFields(
            children: [
              _DateField(
                label: l10n.discountStartsAtLabel,
                value: _startsAt,
                onPick: () => _pickDate(isStart: true),
                onClear: () => setState(() => _startsAt = null),
              ),
              _DateField(
                label: l10n.discountEndsAtLabel,
                value: _endsAt,
                onPick: () => _pickDate(isStart: false),
                onClear: () => setState(() => _endsAt = null),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _ResponsiveFields(
            children: [
              _ConstraintPickerField(
                key: ValueKey(
                  'products_${_selectedProducts.map((item) => item.id).join('_')}',
                ),
                fieldKey: const ValueKey('discount_product_picker_field'),
                label: l10n.discountProductIdsLabel,
                selected: _selectedProducts,
                emptyText: l10n.discountNoConstraintsSelected,
                onPick: () => _pickProducts(context),
                onClear: _selectedProducts.isEmpty
                    ? null
                    : () => setState(() => _selectedProducts = []),
                validator: (_) => null,
              ),
              _ConstraintPickerField(
                key: ValueKey(
                  'customers_${_selectedCustomers.map((item) => item.id).join('_')}',
                ),
                fieldKey: const ValueKey('discount_customer_picker_field'),
                label: l10n.discountCustomerIdsLabel,
                selected: _selectedCustomers,
                emptyText: l10n.discountNoConstraintsSelected,
                onPick: () => _pickCustomers(context),
                onClear: _selectedCustomers.isEmpty
                    ? null
                    : () => setState(() => _selectedCustomers = []),
                validator: (_) => _validateCustomerSelection(),
              ),
              _ConstraintPickerField(
                key: ValueKey(
                  'suppliers_${_selectedSuppliers.map((item) => item.id).join('_')}',
                ),
                fieldKey: const ValueKey('discount_supplier_picker_field'),
                label: l10n.discountSupplierIdsLabel,
                selected: _selectedSuppliers,
                emptyText: l10n.discountNoConstraintsSelected,
                onPick: () => _pickSuppliers(context),
                onClear: _selectedSuppliers.isEmpty
                    ? null
                    : () => setState(() => _selectedSuppliers = []),
                validator: (_) => _validateSupplierSelection(),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _SectionTitle(title: l10n.discountUsageSection),
          _ResponsiveFields(
            children: [
              TextFormField(
                controller: _usageLimitController,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: InputDecoration(
                  labelText: l10n.discountUsageLimitLabel,
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
                validator: _validateOptionalPositiveInteger,
              ),
              TextFormField(
                controller: _perCustomerLimitController,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: InputDecoration(
                  labelText: l10n.discountPerCustomerLimitLabel,
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
                validator: _validatePerCustomerLimit,
              ),
              TextFormField(
                controller: _perSupplierLimitController,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: InputDecoration(
                  labelText: l10n.discountPerSupplierLimitLabel,
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
                validator: _validatePerSupplierLimit,
              ),
            ],
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            key: const ValueKey('discount_rule_save_button'),
            onPressed: widget.viewModel.isSaving ? null : _submit,
            icon: widget.viewModel.isSaving
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save_outlined),
            label: Text(l10n.discountSaveButton),
          ),
        ],
      ),
    );
  }

  Future<void> _pickDate({required bool isStart}) async {
    final current = isStart ? _startsAt : _endsAt;
    final selected = await showDatePicker(
      context: context,
      initialDate: current ?? DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (selected == null || !mounted) {
      return;
    }
    setState(() {
      if (isStart) {
        _startsAt = DateTime(selected.year, selected.month, selected.day);
      } else {
        _endsAt = DateTime(selected.year, selected.month, selected.day, 23, 59);
      }
    });
  }

  Future<void> _submit() async {
    final l10n = AppLocalizations.of(context)!;
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    if (_endsAt != null && _startsAt != null && !_endsAt!.isAfter(_startsAt!)) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.discountDateRangeError)));
      return;
    }

    final draft = DiscountRuleDraft(
      name: _nameController.text,
      description: _descriptionController.text,
      channel: _channel,
      applicationType: _applicationType,
      couponCode: _couponCodeController.text,
      scope: _scope,
      valueType: _valueType,
      value: _valueController.text,
      maxDiscountAmount: _maxDiscountController.text,
      minOrderSubtotal: _minSubtotalController.text,
      minLineQuantity: _minLineQuantityController.text,
      priority: _priorityController.text,
      exclusive: _exclusive,
      isActive: _isActive,
      startsAt: _startsAt,
      endsAt: _endsAt,
      usageLimit: _usageLimitController.text,
      perCustomerUsageLimit: _perCustomerLimitController.text,
      perSupplierUsageLimit: _perSupplierLimitController.text,
      products: _selectedProducts.map((item) => item.id).toList(),
      customers: _selectedCustomers.map((item) => item.id).toList(),
      suppliers: _selectedSuppliers.map((item) => item.id).toList(),
      metadata: widget.rule?.metadata ?? const {},
    );

    final rule = widget.rule;
    final saved = rule == null
        ? await widget.viewModel.createRule(draft)
        : await widget.viewModel.updateRule(rule: rule, draft: draft);
    if (!mounted) {
      return;
    }
    if (saved) {
      widget.onSaved();
    } else {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.discountSaveError)));
    }
  }

  String? _validatePositiveDecimal(String? value) {
    final l10n = AppLocalizations.of(context)!;
    final parsed = double.tryParse((value ?? '').replaceAll(',', '.'));
    if (parsed == null || parsed <= 0) {
      return l10n.positiveNumberError;
    }
    if (_valueType == DiscountValueType.percentage && parsed > 100) {
      return l10n.discountPercentError;
    }
    if ((_valueType == DiscountValueType.fixedPrice ||
            _valueType == DiscountValueType.fixedUnitAmount) &&
        _scope != DiscountScope.line) {
      return l10n.discountLineOnlyValueTypeError;
    }
    return null;
  }

  String? _validateOptionalPositiveAmount(String? value) {
    if (value == null || value.trim().isEmpty) {
      return null;
    }
    final parsed = double.tryParse(value.replaceAll(',', '.'));
    if (parsed == null || parsed <= 0) {
      return AppLocalizations.of(context)!.positiveNumberError;
    }
    return null;
  }

  String? _validateOptionalNonNegativeDecimal(String? value) {
    if (value == null || value.trim().isEmpty) {
      return null;
    }
    final parsed = double.tryParse(value.replaceAll(',', '.'));
    if (parsed == null || parsed < 0) {
      return AppLocalizations.of(context)!.nonNegativeNumberError;
    }
    return null;
  }

  String? _validatePositiveInteger(String? value) {
    final parsed = int.tryParse(value ?? '');
    if (parsed == null || parsed <= 0) {
      return AppLocalizations.of(context)!.positiveIntegerError;
    }
    return null;
  }

  String? _validateOptionalPositiveInteger(String? value) {
    if (value == null || value.trim().isEmpty) {
      return null;
    }
    return _validatePositiveInteger(value);
  }

  String? _validateCustomerSelection() {
    if (_selectedCustomers.isNotEmpty &&
        _channel == DiscountChannel.purchasing) {
      return AppLocalizations.of(context)!.discountCustomerChannelError;
    }
    return null;
  }

  String? _validateSupplierSelection() {
    if (_selectedSuppliers.isNotEmpty && _channel == DiscountChannel.sales) {
      return AppLocalizations.of(context)!.discountSupplierChannelError;
    }
    return null;
  }

  String? _validatePerCustomerLimit(String? value) {
    final base = _validateOptionalPositiveInteger(value);
    if (base != null) {
      return base;
    }
    if ((value?.trim().isNotEmpty ?? false) &&
        _channel == DiscountChannel.purchasing) {
      return AppLocalizations.of(context)!.discountCustomerChannelError;
    }
    return null;
  }

  String? _validatePerSupplierLimit(String? value) {
    final base = _validateOptionalPositiveInteger(value);
    if (base != null) {
      return base;
    }
    if ((value?.trim().isNotEmpty ?? false) &&
        _channel == DiscountChannel.sales) {
      return AppLocalizations.of(context)!.discountSupplierChannelError;
    }
    return null;
  }

  Future<void> _pickProducts(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final picked = await _showDiscountConstraintPicker(
      context: context,
      title: l10n.discountProductPickerTitle,
      searchHint: l10n.discountProductPickerSearchHint,
      emptyText: l10n.discountProductPickerEmpty,
      selected: _selectedProducts,
      loadPage: (search, page) async {
        final result = await widget.catalogRepository.loadProducts(
          query: ProductQuery(
            search: search,
            availability: ProductAvailabilityFilter.all,
          ),
          page: page,
        );
        return switch (result) {
          Ok(value: final page) => _ConstraintPickerPage(
            options: [
              for (final product in page.products)
                _DiscountConstraintSelection(
                  id: product.id,
                  label: product.name,
                  subtitle: [
                    if (product.sku.isNotEmpty) product.sku,
                    if (product.barcode.isNotEmpty) product.barcode,
                  ].join(' • '),
                ),
            ],
            hasMore: page.hasMore,
          ),
          Error() => throw Exception('product picker failed'),
        };
      },
    );
    if (!mounted || picked == null) {
      return;
    }
    setState(() => _selectedProducts = picked);
  }

  Future<void> _pickCustomers(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final picked = await _showDiscountConstraintPicker(
      context: context,
      title: l10n.discountCustomerPickerTitle,
      searchHint: l10n.discountCustomerPickerSearchHint,
      emptyText: l10n.discountCustomerPickerEmpty,
      selected: _selectedCustomers,
      loadPage: (search, page) async {
        final result = await widget.contactRepository.loadCustomers(
          query: ContactQuery(search: search),
          page: page,
        );
        return switch (result) {
          Ok(value: final page) => _ConstraintPickerPage(
            options: [
              for (final customer in page.customers)
                _DiscountConstraintSelection(
                  id: customer.id,
                  label: customer.fullName,
                  subtitle: [
                    if (customer.phone.isNotEmpty) customer.phone,
                    if (customer.email.isNotEmpty) customer.email,
                  ].join(' • '),
                ),
            ],
            hasMore: page.hasMore,
          ),
          Error() => throw Exception('customer picker failed'),
        };
      },
    );
    if (!mounted || picked == null) {
      return;
    }
    setState(() => _selectedCustomers = picked);
  }

  Future<void> _pickSuppliers(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final picked = await _showDiscountConstraintPicker(
      context: context,
      title: l10n.discountSupplierPickerTitle,
      searchHint: l10n.discountSupplierPickerSearchHint,
      emptyText: l10n.discountSupplierPickerEmpty,
      selected: _selectedSuppliers,
      loadPage: (search, page) async {
        final result = await widget.contactRepository.loadSuppliers(
          query: ContactQuery(search: search),
          page: page,
        );
        return switch (result) {
          Ok(value: final page) => _ConstraintPickerPage(
            options: [
              for (final supplier in page.suppliers)
                _DiscountConstraintSelection(
                  id: supplier.id,
                  label: supplier.name,
                  subtitle: [
                    if (supplier.contactName.isNotEmpty) supplier.contactName,
                    if (supplier.phone.isNotEmpty) supplier.phone,
                  ].join(' • '),
                ),
            ],
            hasMore: page.hasMore,
          ),
          Error() => throw Exception('supplier picker failed'),
        };
      },
    );
    if (!mounted || picked == null) {
      return;
    }
    setState(() => _selectedSuppliers = picked);
  }

  List<_DiscountConstraintSelection> _selectionsFromIds(List<int> ids) {
    return [
      for (final id in ids)
        _DiscountConstraintSelection(id: id, label: '', subtitle: ''),
    ];
  }

  String _formatMoney(double value) => value.toStringAsFixed(2);
  String _formatDecimal(double value) => value.toStringAsFixed(4);

  String _channelLabel(AppLocalizations l10n, DiscountChannel channel) {
    return switch (channel) {
      DiscountChannel.sales => l10n.discountChannelSales,
      DiscountChannel.purchasing => l10n.discountChannelPurchasing,
      DiscountChannel.both => l10n.discountChannelBoth,
    };
  }

  String _applicationLabel(
    AppLocalizations l10n,
    DiscountApplicationType type,
  ) {
    return switch (type) {
      DiscountApplicationType.automatic => l10n.discountApplicationAutomatic,
      DiscountApplicationType.couponCode => l10n.discountApplicationCoupon,
    };
  }

  String _scopeLabel(AppLocalizations l10n, DiscountScope scope) {
    return switch (scope) {
      DiscountScope.document => l10n.discountScopeDocument,
      DiscountScope.line => l10n.discountScopeLine,
    };
  }

  String _valueTypeLabel(AppLocalizations l10n, DiscountValueType type) {
    return switch (type) {
      DiscountValueType.percentage => l10n.discountValueTypePercentage,
      DiscountValueType.fixedAmount => l10n.discountValueTypeFixedAmount,
      DiscountValueType.fixedUnitAmount =>
        l10n.discountValueTypeFixedUnitAmount,
      DiscountValueType.fixedPrice => l10n.discountValueTypeFixedPrice,
    };
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(title, style: Theme.of(context).textTheme.titleMedium),
    );
  }
}

class _SegmentedField<T> extends StatelessWidget {
  const _SegmentedField({
    required this.label,
    required this.selected,
    required this.values,
    required this.labelFor,
    required this.onSelected,
  });

  final String label;
  final T selected;
  final List<T> values;
  final String Function(T value) labelFor;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelMedium),
        const SizedBox(height: 6),
        SegmentedButton<T>(
          showSelectedIcon: false,
          segments: [
            for (final value in values)
              ButtonSegment<T>(value: value, label: Text(labelFor(value))),
          ],
          selected: {selected},
          onSelectionChanged: (values) => onSelected(values.first),
        ),
      ],
    );
  }
}

class _ResponsiveFields extends StatelessWidget {
  const _ResponsiveFields({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth >= 720
            ? (constraints.maxWidth - 24) / 3
            : constraints.maxWidth >= 480
            ? (constraints.maxWidth - 12) / 2
            : constraints.maxWidth;
        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final child in children) SizedBox(width: width, child: child),
          ],
        );
      },
    );
  }
}

class _DateField extends StatelessWidget {
  const _DateField({
    required this.label,
    required this.value,
    required this.onPick,
    required this.onClear,
  });

  final String label;
  final DateTime? value;
  final VoidCallback onPick;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final text = value == null
        ? l10n.discountNoDateSelected
        : '${value!.year}/${value!.month.toString().padLeft(2, '0')}/${value!.day.toString().padLeft(2, '0')}';
    return InputDecorator(
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
      child: Row(
        children: [
          Expanded(child: Text(text, overflow: TextOverflow.ellipsis)),
          IconButton(
            tooltip: l10n.discountPickDateTooltip,
            onPressed: onPick,
            icon: const Icon(Icons.calendar_month_outlined),
          ),
          if (value != null)
            IconButton(
              tooltip: l10n.clearButton,
              onPressed: onClear,
              icon: const Icon(Icons.close),
            ),
        ],
      ),
    );
  }
}

typedef _ConstraintPageLoader =
    Future<_ConstraintPickerPage> Function(String search, int page);

Future<List<_DiscountConstraintSelection>?> _showDiscountConstraintPicker({
  required BuildContext context,
  required String title,
  required String searchHint,
  required String emptyText,
  required List<_DiscountConstraintSelection> selected,
  required _ConstraintPageLoader loadPage,
}) {
  return showModalBottomSheet<List<_DiscountConstraintSelection>>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (context) {
      return FractionallySizedBox(
        heightFactor: 0.82,
        child: _ConstraintPickerSheet(
          title: title,
          searchHint: searchHint,
          emptyText: emptyText,
          selected: selected,
          loadPage: loadPage,
        ),
      );
    },
  );
}

class _ConstraintPickerPage {
  const _ConstraintPickerPage({required this.options, required this.hasMore});

  final List<_DiscountConstraintSelection> options;
  final bool hasMore;
}

class _DiscountConstraintSelection {
  const _DiscountConstraintSelection({
    required this.id,
    required this.label,
    required this.subtitle,
  });

  final int id;
  final String label;
  final String subtitle;

  String displayLabel(AppLocalizations l10n) {
    return label.isEmpty ? l10n.discountConstraintId(id) : label;
  }
}

class _ConstraintPickerSheet extends StatefulWidget {
  const _ConstraintPickerSheet({
    required this.title,
    required this.searchHint,
    required this.emptyText,
    required this.selected,
    required this.loadPage,
  });

  final String title;
  final String searchHint;
  final String emptyText;
  final List<_DiscountConstraintSelection> selected;
  final _ConstraintPageLoader loadPage;

  @override
  State<_ConstraintPickerSheet> createState() => _ConstraintPickerSheetState();
}

class _ConstraintPickerSheetState extends State<_ConstraintPickerSheet> {
  var _search = '';
  var _options = <_DiscountConstraintSelection>[];
  var _selected = <int, _DiscountConstraintSelection>{};
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
                  widget.title,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              TextButton(
                onPressed: _selected.isEmpty
                    ? null
                    : () => setState(() => _selected = {}),
                child: Text(l10n.clearButton),
              ),
            ],
          ),
          const SizedBox(height: 8),
          DebouncedSearchField(
            value: _search,
            hintText: widget.searchHint,
            clearTooltip: l10n.clearSearchTooltip,
            fieldKey: const ValueKey('discount_constraint_search_field'),
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
                    label: Text(item.displayLabel(l10n)),
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
                l10n.discountPickerLoadError,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          const SizedBox(height: 8),
          Expanded(
            child: InfiniteScrollList<_DiscountConstraintSelection>(
              items: _options,
              onLoadMore: () => _load(reset: false),
              hasMore: _hasMore,
              isLoadingInitial: _isLoading,
              isLoadingMore: _isLoadingMore,
              emptyBuilder: (context) => Center(child: Text(widget.emptyText)),
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, option) {
                final isSelected = _selected.containsKey(option.id);
                return CheckboxListTile(
                  key: ValueKey('discount_constraint_option_${option.id}'),
                  value: isSelected,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: Text(
                    option.displayLabel(l10n),
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
            key: const ValueKey('discount_constraint_apply_button'),
            onPressed: () {
              Navigator.of(context).pop(_selected.values.toList());
            },
            icon: const Icon(Icons.check),
            label: Text(l10n.confirmButton),
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

  void _toggle(_DiscountConstraintSelection option) {
    setState(() {
      if (_selected.containsKey(option.id)) {
        _selected.remove(option.id);
      } else {
        _selected[option.id] = option;
      }
    });
  }
}

class _ConstraintPickerField extends StatelessWidget {
  const _ConstraintPickerField({
    super.key,
    required this.fieldKey,
    required this.label,
    required this.selected,
    required this.emptyText,
    required this.onPick,
    required this.onClear,
    required this.validator,
  });

  final Key fieldKey;
  final String label;
  final List<_DiscountConstraintSelection> selected;
  final String emptyText;
  final VoidCallback onPick;
  final VoidCallback? onClear;
  final String? Function(List<_DiscountConstraintSelection> selected) validator;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return FormField<List<_DiscountConstraintSelection>>(
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
                labelText: label,
                helperText: l10n.discountPickerHelper,
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
                            emptyText,
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
                                  label: Text(item.displayLabel(l10n)),
                                ),
                            ],
                          ),
                  ),
                  if (onClear != null)
                    IconButton(
                      tooltip: l10n.clearButton,
                      onPressed: onClear,
                      icon: const Icon(Icons.close),
                    ),
                  IconButton(
                    tooltip: l10n.discountOpenPickerTooltip,
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
