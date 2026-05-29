import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../core/result.dart';
import '../data/models/contact.dart';
import '../data/repositories/contact_repository.dart';
import 'components/components.dart';
import 'responsive/responsive.dart';

class ContactSelectionTile extends StatelessWidget {
  const ContactSelectionTile({
    super.key,
    required this.label,
    required this.value,
    required this.placeholder,
    required this.icon,
    required this.enabled,
    required this.onSelect,
    required this.onClear,
    this.allowClear = true,
    this.padding = const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    this.iconSize,
    this.iconSpacing = 10,
    this.actionVisualDensity,
    this.selectActionIcon,
    this.clearActionIcon = Icons.close,
  });

  final String label;
  final String value;
  final String placeholder;
  final IconData icon;
  final bool enabled;
  final VoidCallback onSelect;
  final VoidCallback onClear;
  final bool allowClear;
  final EdgeInsetsGeometry padding;
  final double? iconSize;
  final double iconSpacing;
  final VisualDensity? actionVisualDensity;
  final IconData? selectActionIcon;
  final IconData clearActionIcon;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colorScheme = Theme.of(context).colorScheme;
    final hasValue = value.trim().isNotEmpty;
    final iconColor = enabled
        ? colorScheme.onSurfaceVariant
        : colorScheme.onSurface.withValues(alpha: 0.38);

    return Material(
      color: colorScheme.surface,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: enabled ? onSelect : null,
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: colorScheme.outlineVariant),
          ),
          child: Row(
            children: [
              Icon(icon, size: iconSize, color: iconColor),
              SizedBox(width: iconSpacing),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                    Text(
                      hasValue ? value : placeholder,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
              if (hasValue && allowClear)
                IconButton(
                  tooltip: l10n.clearContactTooltip,
                  visualDensity: actionVisualDensity,
                  onPressed: enabled ? onClear : null,
                  icon: Icon(clearActionIcon),
                )
              else if (selectActionIcon != null)
                IconButton(
                  tooltip: l10n.changeContactAction,
                  visualDensity: actionVisualDensity,
                  onPressed: enabled ? onSelect : null,
                  icon: Icon(selectActionIcon),
                )
              else
                TextButton(
                  onPressed: enabled ? onSelect : null,
                  child: Text(l10n.changeContactAction),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

Future<Customer?> showCustomerPickerSheet({
  required BuildContext context,
  required ContactRepository repository,
}) {
  return showAdaptiveModalBottomSheet<Customer?>(
    context: context,
    size: AdaptiveModalSize.standard,
    maxHeightFactor: 0.9,
    builder: (context) => _CustomerPicker(repository: repository),
  );
}

Future<SupplierContact?> showSupplierPickerSheet({
  required BuildContext context,
  required ContactRepository repository,
}) {
  return showAdaptiveModalBottomSheet<SupplierContact?>(
    context: context,
    size: AdaptiveModalSize.standard,
    maxHeightFactor: 0.9,
    builder: (context) => _SupplierPicker(repository: repository),
  );
}

Future<Customer?> showCreateCustomerSheet({
  required BuildContext context,
  required ContactRepository repository,
}) {
  return showAdaptiveModalBottomSheet<Customer?>(
    context: context,
    size: AdaptiveModalSize.standard,
    maxHeightFactor: 0.92,
    builder: (context) {
      return Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: CustomerForm(
          repository: repository,
          onSaved: (customer) => Navigator.of(context).pop(customer),
        ),
      );
    },
  );
}

Future<SupplierContact?> showCreateSupplierSheet({
  required BuildContext context,
  required ContactRepository repository,
}) {
  return showAdaptiveModalBottomSheet<SupplierContact?>(
    context: context,
    size: AdaptiveModalSize.standard,
    maxHeightFactor: 0.92,
    builder: (context) {
      return Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SupplierForm(
          repository: repository,
          onSaved: (supplier) => Navigator.of(context).pop(supplier),
        ),
      );
    },
  );
}

class _CustomerPicker extends StatefulWidget {
  const _CustomerPicker({required this.repository});

  final ContactRepository repository;

  @override
  State<_CustomerPicker> createState() => _CustomerPickerState();
}

class _CustomerPickerState extends State<_CustomerPicker> {
  var _query = const ContactQuery();
  var _customers = <Customer>[];
  var _isLoading = true;
  var _isLoadingMore = false;
  var _hasMore = true;
  var _hasError = false;
  var _nextPage = 1;

  @override
  void initState() {
    super.initState();
    _load(reset: true);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return _PickerShell(
      title: l10n.chooseCustomerTitle,
      searchHint: l10n.contactSearchHint,
      createLabel: l10n.createNewCustomerAction,
      onSearchChanged: (search) {
        _query = _query.copyWith(search: search);
        _load(reset: true);
      },
      onCreate: () async {
        final created = await showCreateCustomerSheet(
          context: context,
          repository: widget.repository,
        );
        if (!context.mounted || created == null) {
          return;
        }
        Navigator.of(context).pop(created);
      },
      child: PointyDataList<Customer>(
        items: _customers,
        onLoadMore: () => _load(reset: false),
        hasMore: _hasMore,
        isLoadingInitial: _isLoading,
        isLoadingMore: _isLoadingMore,
        hasError: _hasError,
        errorBuilder: (context) => PointyErrorState(
          title: l10n.contactsLoadError,
          icon: Icons.person_search_outlined,
        ),
        emptyBuilder: (context) => PointyEmptyState(
          icon: Icons.person_outline,
          title: l10n.emptyCustomers,
        ),
        padding: EdgeInsets.zero,
        framed: false,
        itemBuilder: (context, customer) {
          return PointyDataRow(
            leading: const Icon(Icons.person_outline),
            title: customer.fullName,
            subtitle: [
              if (customer.phone.isNotEmpty) customer.phone,
              if (customer.email.isNotEmpty) customer.email,
            ].join(' • '),
            onTap: () => Navigator.of(context).pop(customer),
          );
        },
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

    final result = await widget.repository.loadCustomers(
      query: _query,
      page: _nextPage,
    );
    if (!mounted) {
      return;
    }
    switch (result) {
      case Ok<CustomerPage>():
        setState(() {
          _customers = reset
              ? result.value.customers
              : [..._customers, ...result.value.customers];
          _hasMore = result.value.hasMore;
          _nextPage += 1;
          _isLoading = false;
          _isLoadingMore = false;
        });
      case Error<CustomerPage>():
        setState(() {
          if (reset) {
            _customers = [];
          }
          _isLoading = false;
          _isLoadingMore = false;
          _hasMore = false;
          _hasError = true;
        });
    }
  }
}

class _SupplierPicker extends StatefulWidget {
  const _SupplierPicker({required this.repository});

  final ContactRepository repository;

  @override
  State<_SupplierPicker> createState() => _SupplierPickerState();
}

class _SupplierPickerState extends State<_SupplierPicker> {
  var _query = const ContactQuery();
  var _suppliers = <SupplierContact>[];
  var _isLoading = true;
  var _isLoadingMore = false;
  var _hasMore = true;
  var _hasError = false;
  var _nextPage = 1;

  @override
  void initState() {
    super.initState();
    _load(reset: true);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return _PickerShell(
      title: l10n.chooseSupplierTitle,
      searchHint: l10n.contactSearchHint,
      createLabel: l10n.createNewSupplierAction,
      onSearchChanged: (search) {
        _query = _query.copyWith(search: search);
        _load(reset: true);
      },
      onCreate: () async {
        final created = await showCreateSupplierSheet(
          context: context,
          repository: widget.repository,
        );
        if (!context.mounted || created == null) {
          return;
        }
        Navigator.of(context).pop(created);
      },
      child: PointyDataList<SupplierContact>(
        items: _suppliers,
        onLoadMore: () => _load(reset: false),
        hasMore: _hasMore,
        isLoadingInitial: _isLoading,
        isLoadingMore: _isLoadingMore,
        hasError: _hasError,
        errorBuilder: (context) => PointyErrorState(
          title: l10n.contactsLoadError,
          icon: Icons.person_search_outlined,
        ),
        emptyBuilder: (context) => PointyEmptyState(
          icon: Icons.local_shipping_outlined,
          title: l10n.emptySuppliers,
        ),
        padding: EdgeInsets.zero,
        framed: false,
        itemBuilder: (context, supplier) {
          return PointyDataRow(
            leading: const Icon(Icons.local_shipping_outlined),
            title: supplier.name,
            subtitle: [
              if (supplier.contactName.isNotEmpty) supplier.contactName,
              if (supplier.phone.isNotEmpty) supplier.phone,
              if (supplier.email.isNotEmpty) supplier.email,
            ].join(' • '),
            onTap: () => Navigator.of(context).pop(supplier),
          );
        },
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

    final result = await widget.repository.loadSuppliers(
      query: _query,
      page: _nextPage,
    );
    if (!mounted) {
      return;
    }
    switch (result) {
      case Ok<SupplierPage>():
        setState(() {
          _suppliers = reset
              ? result.value.suppliers
              : [..._suppliers, ...result.value.suppliers];
          _hasMore = result.value.hasMore;
          _nextPage += 1;
          _isLoading = false;
          _isLoadingMore = false;
        });
      case Error<SupplierPage>():
        setState(() {
          if (reset) {
            _suppliers = [];
          }
          _isLoading = false;
          _isLoadingMore = false;
          _hasMore = false;
          _hasError = true;
        });
    }
  }
}

class _PickerShell extends StatelessWidget {
  const _PickerShell({
    required this.title,
    required this.searchHint,
    required this.createLabel,
    required this.onSearchChanged,
    required this.onCreate,
    required this.child,
  });

  final String title;
  final String searchHint;
  final String createLabel;
  final ValueChanged<String> onSearchChanged;
  final VoidCallback onCreate;
  final Widget child;

  @override
  Widget build(BuildContext context) {
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
            ResponsiveActionBar(
              leading: Text(
                title,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              actions: [
                FilledButton.icon(
                  onPressed: onCreate,
                  icon: const Icon(Icons.add),
                  label: Text(createLabel),
                ),
              ],
            ),
            SizedBox(height: spacing.md),
            TextField(
              decoration: InputDecoration(
                hintText: searchHint,
                prefixIcon: const Icon(Icons.search),
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: onSearchChanged,
            ),
            SizedBox(height: spacing.sm),
            Expanded(child: child),
          ],
        ),
      ),
    );
  }
}

class CustomerForm extends StatefulWidget {
  const CustomerForm({
    super.key,
    required this.repository,
    required this.onSaved,
  });

  final ContactRepository repository;
  final ValueChanged<Customer> onSaved;

  @override
  State<CustomerForm> createState() => _CustomerFormState();
}

class _CustomerFormState extends State<CustomerForm> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();
  final _emailController = TextEditingController();
  final _birthdayController = TextEditingController();
  final _notesController = TextEditingController();
  CustomerGender _gender = CustomerGender.unspecified;
  bool _marketingConsent = false;
  bool _isActive = true;
  bool _isSaving = false;
  bool _hasError = false;

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    _emailController.dispose();
    _birthdayController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      child: Form(
        key: _formKey,
        child: ListView(
          shrinkWrap: true,
          children: [
            Text(
              l10n.addCustomerButton,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _nameController,
              autofocus: true,
              decoration: InputDecoration(
                labelText: l10n.customerFullNameLabel,
              ),
              validator: _requiredValidator,
            ),
            const SizedBox(height: 10),
            TextFormField(
              controller: _phoneController,
              decoration: InputDecoration(labelText: l10n.phoneOptionalLabel),
              keyboardType: TextInputType.phone,
            ),
            const SizedBox(height: 10),
            TextFormField(
              controller: _emailController,
              decoration: InputDecoration(labelText: l10n.emailOptionalLabel),
              keyboardType: TextInputType.emailAddress,
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<CustomerGender>(
              initialValue: _gender,
              decoration: InputDecoration(labelText: l10n.genderLabel),
              items: [
                for (final gender in CustomerGender.values)
                  DropdownMenuItem(
                    value: gender,
                    child: Text(genderLabel(l10n, gender)),
                  ),
              ],
              onChanged: (value) {
                if (value != null) {
                  setState(() => _gender = value);
                }
              },
            ),
            const SizedBox(height: 10),
            TextFormField(
              controller: _birthdayController,
              decoration: InputDecoration(
                labelText: l10n.birthdayOptionalLabel,
                hintText: l10n.birthdayHint,
              ),
              keyboardType: TextInputType.datetime,
              validator: _dateValidator,
            ),
            CheckboxListTile(
              value: _marketingConsent,
              onChanged: (value) {
                setState(() => _marketingConsent = value ?? false);
              },
              contentPadding: EdgeInsets.zero,
              title: Text(l10n.marketingConsentLabel),
            ),
            CheckboxListTile(
              value: _isActive,
              onChanged: (value) {
                setState(() => _isActive = value ?? true);
              },
              contentPadding: EdgeInsets.zero,
              title: Text(l10n.activeContactLabel),
            ),
            TextFormField(
              controller: _notesController,
              minLines: 2,
              maxLines: 4,
              decoration: InputDecoration(labelText: l10n.notesOptionalLabel),
            ),
            if (_hasError) ...[
              const SizedBox(height: 8),
              Text(
                l10n.customerCreateError,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _isSaving ? null : _submit,
              icon: _isSaving
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save_outlined),
              label: Text(
                _isSaving ? l10n.savingButton : l10n.saveCustomerButton,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String? _requiredValidator(String? value) {
    if (value == null || value.trim().isEmpty) {
      return AppLocalizations.of(context)!.requiredField;
    }
    return null;
  }

  String? _dateValidator(String? value) {
    if (value == null || value.trim().isEmpty) {
      return null;
    }
    return DateTime.tryParse(value.trim()) == null
        ? AppLocalizations.of(context)!.invalidDate
        : null;
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    setState(() {
      _isSaving = true;
      _hasError = false;
    });
    final result = await widget.repository.createCustomer(
      CustomerDraft(
        fullName: _nameController.text.trim(),
        phone: _phoneController.text.trim(),
        email: _emailController.text.trim(),
        gender: _gender,
        birthday: DateTime.tryParse(_birthdayController.text.trim()),
        marketingConsent: _marketingConsent,
        notes: _notesController.text.trim(),
        isActive: _isActive,
      ),
    );
    if (!mounted) {
      return;
    }
    switch (result) {
      case Ok<Customer>():
        widget.onSaved(result.value);
      case Error<Customer>():
        setState(() {
          _isSaving = false;
          _hasError = true;
        });
    }
  }
}

class SupplierForm extends StatefulWidget {
  const SupplierForm({
    super.key,
    required this.repository,
    required this.onSaved,
  });

  final ContactRepository repository;
  final ValueChanged<SupplierContact> onSaved;

  @override
  State<SupplierForm> createState() => _SupplierFormState();
}

class _SupplierFormState extends State<SupplierForm> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _contactNameController = TextEditingController();
  final _phoneController = TextEditingController();
  final _emailController = TextEditingController();
  final _addressController = TextEditingController();
  final _notesController = TextEditingController();
  bool _isActive = true;
  bool _isSaving = false;
  bool _hasError = false;

  @override
  void dispose() {
    _nameController.dispose();
    _contactNameController.dispose();
    _phoneController.dispose();
    _emailController.dispose();
    _addressController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      child: Form(
        key: _formKey,
        child: ListView(
          shrinkWrap: true,
          children: [
            Text(
              l10n.addSupplierButton,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _nameController,
              autofocus: true,
              decoration: InputDecoration(labelText: l10n.supplierNameLabel),
              validator: _requiredValidator,
            ),
            const SizedBox(height: 10),
            TextFormField(
              controller: _contactNameController,
              decoration: InputDecoration(labelText: l10n.contactPersonLabel),
            ),
            const SizedBox(height: 10),
            TextFormField(
              controller: _phoneController,
              decoration: InputDecoration(labelText: l10n.phoneOptionalLabel),
              keyboardType: TextInputType.phone,
            ),
            const SizedBox(height: 10),
            TextFormField(
              controller: _emailController,
              decoration: InputDecoration(labelText: l10n.emailOptionalLabel),
              keyboardType: TextInputType.emailAddress,
            ),
            const SizedBox(height: 10),
            TextFormField(
              controller: _addressController,
              decoration: InputDecoration(labelText: l10n.addressOptionalLabel),
            ),
            CheckboxListTile(
              value: _isActive,
              onChanged: (value) {
                setState(() => _isActive = value ?? true);
              },
              contentPadding: EdgeInsets.zero,
              title: Text(l10n.activeContactLabel),
            ),
            TextFormField(
              controller: _notesController,
              minLines: 2,
              maxLines: 4,
              decoration: InputDecoration(labelText: l10n.notesOptionalLabel),
            ),
            if (_hasError) ...[
              const SizedBox(height: 8),
              Text(
                l10n.supplierCreateError,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _isSaving ? null : _submit,
              icon: _isSaving
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save_outlined),
              label: Text(
                _isSaving ? l10n.savingButton : l10n.saveSupplierButton,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String? _requiredValidator(String? value) {
    if (value == null || value.trim().isEmpty) {
      return AppLocalizations.of(context)!.requiredField;
    }
    return null;
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    setState(() {
      _isSaving = true;
      _hasError = false;
    });
    final result = await widget.repository.createSupplier(
      SupplierDraft(
        name: _nameController.text.trim(),
        contactName: _contactNameController.text.trim(),
        phone: _phoneController.text.trim(),
        email: _emailController.text.trim(),
        address: _addressController.text.trim(),
        notes: _notesController.text.trim(),
        isActive: _isActive,
      ),
    );
    if (!mounted) {
      return;
    }
    switch (result) {
      case Ok<SupplierContact>():
        widget.onSaved(result.value);
      case Error<SupplierContact>():
        setState(() {
          _isSaving = false;
          _hasError = true;
        });
    }
  }
}

String genderLabel(AppLocalizations l10n, CustomerGender gender) {
  return switch (gender) {
    CustomerGender.unspecified => l10n.genderUnspecified,
    CustomerGender.female => l10n.genderFemale,
    CustomerGender.male => l10n.genderMale,
    CustomerGender.nonBinary => l10n.genderNonBinary,
    CustomerGender.preferNotToSay => l10n.genderPreferNotToSay,
  };
}
