import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/migration.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../view_models/migration_view_model.dart';

class DataMigrationPage extends StatefulWidget {
  const DataMigrationPage({super.key, required this.viewModel});

  final MigrationViewModel viewModel;

  @override
  State<DataMigrationPage> createState() => _DataMigrationPageState();
}

class _DataMigrationPageState extends State<DataMigrationPage> {
  final _nameController = TextEditingController();
  final _hostController = TextEditingController();
  final _portController = TextEditingController();
  final _databaseController = TextEditingController();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  // Advanced (extra_options) — needed for legacy servers like SQL Server 2000.
  final _odbcDriverController = TextEditingController();
  final _tdsVersionController = TextEditingController();
  final _encodingController = TextEditingController();

  String? _systemKey;
  int? _seededSourceId;
  bool _seededEmpty = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(widget.viewModel.load());
      }
    });
  }

  @override
  void dispose() {
    _nameController.dispose();
    _hostController.dispose();
    _portController.dispose();
    _databaseController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _odbcDriverController.dispose();
    _tdsVersionController.dispose();
    _encodingController.dispose();
    super.dispose();
  }

  void _applyAdvancedOptions(Map<String, Object?> options) {
    _odbcDriverController.text = (options['odbc_driver'] ?? '').toString();
    _tdsVersionController.text = (options['tds_version'] ?? '').toString();
    _encodingController.text = (options['encoding'] ?? '').toString();
  }

  /// The advanced fields as a transport-options map (empty fields omitted).
  Map<String, Object?> _collectExtraOptions() {
    final options = <String, Object?>{};
    void put(String key, String value) {
      final trimmed = value.trim();
      if (trimmed.isNotEmpty) options[key] = trimmed;
    }

    put('odbc_driver', _odbcDriverController.text);
    put('tds_version', _tdsVersionController.text);
    put('encoding', _encodingController.text);
    return options;
  }

  /// Seed the form once per source (or once for the empty "create" state).
  void _maybeSeed() {
    final viewModel = widget.viewModel;
    final source = viewModel.selectedSource;
    if (source != null) {
      if (_seededSourceId == source.id) return;
      _seededSourceId = source.id;
      _seededEmpty = false;
      _nameController.text = source.name;
      _hostController.text = source.host;
      _portController.text = source.port?.toString() ?? '';
      _databaseController.text = source.databaseName;
      _usernameController.text = source.username;
      _passwordController.clear();
      _systemKey = source.systemKey;
      _applyAdvancedOptions(source.extraOptions);
    } else {
      if (_seededEmpty) return;
      _seededEmpty = true;
      _seededSourceId = null;
      _systemKey ??= viewModel.systems.isNotEmpty
          ? viewModel.systems.first.systemKey
          : null;
      // Pre-fill advanced options with the chosen connector's recommendation
      // (e.g. FreeTDS / TDS 7.0 for the Fahd SQL Server 2000 connector).
      _applyAdvancedOptions(_currentSystem?.recommendedOptions ?? const {});
    }
  }

  MigrationSystem? get _currentSystem {
    final key = _systemKey;
    if (key == null) return null;
    return widget.viewModel.systemFor(key);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.viewModel,
      builder: (context, _) {
        final l10n = AppLocalizations.of(context)!;
        final viewModel = widget.viewModel;
        _maybeSeed();

        return PointyScaffold(
          appBar: PointyAppBar(
            title: Text(l10n.migrationTitle),
            isLoading: viewModel.isLoading || viewModel.isMutating,
          ),
          body: _buildBody(context, l10n),
          bottomNavigationBar: viewModel.selectedSource == null
              ? null
              : _buildFooter(context, l10n),
        );
      },
    );
  }

  Widget _buildBody(BuildContext context, AppLocalizations l10n) {
    final viewModel = widget.viewModel;
    final spacing = AdaptiveSpacing.of(context);

    if (viewModel.isLoading && viewModel.catalog == null) {
      return const PointyLoadingArea();
    }
    if (viewModel.hasLoadError && viewModel.catalog == null) {
      return PointyErrorState(
        title: l10n.migrationLoadError,
        icon: Icons.cloud_sync_outlined,
        action: FilledButton.icon(
          onPressed: viewModel.load,
          icon: const Icon(Icons.sync),
          label: Text(l10n.retryButton),
        ),
      );
    }

    return SingleChildScrollView(
      padding: spacing.pagePadding,
      child: AdaptiveMaxWidth(
        width: AppContentWidth.form,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PointyDetailHero(
              icon: Icons.cloud_sync_outlined,
              title: l10n.migrationTitle,
              description: l10n.migrationHeroDescription,
            ),
            SizedBox(height: spacing.md),
            _connectionCard(context, l10n),
            SizedBox(height: spacing.md),
            if (viewModel.selectedSource != null) ...[
              _compatibilityCard(context, l10n),
              SizedBox(height: spacing.md),
              _entitiesCard(context, l10n),
              SizedBox(height: spacing.md),
              _runCard(context, l10n),
            ],
          ],
        ),
      ),
    );
  }

  // --- connection ------------------------------------------------------
  Widget _connectionCard(BuildContext context, AppLocalizations l10n) {
    final viewModel = widget.viewModel;
    final spacing = AdaptiveSpacing.of(context);
    final transport = _currentSystem?.requiredTransport ?? '';
    final isSqlite = transport == 'sqlite';

    return _SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.migrationConnectionSectionTitle,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          SizedBox(height: spacing.xs),
          Text(
            l10n.migrationConnectionSectionSubtitle,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          SizedBox(height: spacing.sm),
          TextField(
            controller: _nameController,
            decoration: InputDecoration(
              labelText: l10n.migrationSourceNameLabel,
              prefixIcon: const Icon(Icons.label_outline),
            ),
          ),
          SizedBox(height: spacing.sm),
          DropdownButtonFormField<String>(
            value: _systemKey,
            isExpanded: true,
            decoration: InputDecoration(
              labelText: l10n.migrationSystemLabel,
              prefixIcon: const Icon(Icons.dvr_outlined),
            ),
            items: [
              for (final system in viewModel.systems)
                DropdownMenuItem(
                  value: system.systemKey,
                  child: Text(
                    system.displayName,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: (value) => setState(() {
              _systemKey = value;
              // On a new source, follow the connector's recommended options.
              if (viewModel.selectedSource == null) {
                _applyAdvancedOptions(
                  _currentSystem?.recommendedOptions ?? const {},
                );
              }
            }),
          ),
          if (_currentSystem?.implemented == false) ...[
            SizedBox(height: spacing.sm),
            PointyInlineMessage.warning(
              message: l10n.migrationStubSystemNotice,
            ),
          ],
          SizedBox(height: spacing.sm),
          if (isSqlite)
            TextField(
              controller: _databaseController,
              textDirection: TextDirection.ltr,
              decoration: InputDecoration(
                labelText: l10n.migrationDatabaseFileLabel,
                prefixIcon: const Icon(Icons.folder_outlined),
              ),
            )
          else ...[
            Row(
              children: [
                Expanded(
                  flex: 3,
                  child: TextField(
                    controller: _hostController,
                    textDirection: TextDirection.ltr,
                    decoration: InputDecoration(
                      labelText: l10n.migrationHostLabel,
                      prefixIcon: const Icon(Icons.dns_outlined),
                    ),
                  ),
                ),
                SizedBox(width: spacing.sm),
                Expanded(
                  child: TextField(
                    controller: _portController,
                    keyboardType: TextInputType.number,
                    textDirection: TextDirection.ltr,
                    decoration: InputDecoration(
                      labelText: l10n.migrationPortLabel,
                    ),
                  ),
                ),
              ],
            ),
            if (transport == 'mssql') ...[
              SizedBox(height: spacing.xs),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: OutlinedButton.icon(
                  onPressed: viewModel.isDiscovering
                      ? null
                      : () => _scanNetwork(context),
                  icon: viewModel.isDiscovering
                      ? const _Spinner()
                      : const Icon(Icons.wifi_find_outlined),
                  label: Text(l10n.migrationScanButton),
                ),
              ),
            ],
            SizedBox(height: spacing.sm),
            TextField(
              controller: _databaseController,
              textDirection: TextDirection.ltr,
              decoration: InputDecoration(
                labelText: l10n.migrationDatabaseLabel,
                prefixIcon: const Icon(Icons.storage_outlined),
              ),
            ),
            SizedBox(height: spacing.sm),
            TextField(
              controller: _usernameController,
              textDirection: TextDirection.ltr,
              decoration: InputDecoration(
                labelText: l10n.migrationUsernameLabel,
                prefixIcon: const Icon(Icons.person_outline),
              ),
            ),
            SizedBox(height: spacing.sm),
            TextField(
              controller: _passwordController,
              obscureText: true,
              textDirection: TextDirection.ltr,
              decoration: InputDecoration(
                labelText: l10n.migrationPasswordLabel,
                helperText: viewModel.selectedSource?.hasPassword == true
                    ? l10n.migrationPasswordKeepHint
                    : null,
                prefixIcon: const Icon(Icons.key_outlined),
              ),
            ),
          ],
          if (transport == 'mssql') _buildAdvancedOptions(context, l10n),
          SizedBox(height: spacing.sm),
          Wrap(
            spacing: spacing.sm,
            runSpacing: spacing.sm,
            children: [
              FilledButton.icon(
                onPressed: viewModel.isMutating ? null : () => _save(context),
                icon: const Icon(Icons.save_outlined),
                label: Text(l10n.migrationSaveSourceButton),
              ),
              if (viewModel.selectedSource != null) ...[
                OutlinedButton.icon(
                  onPressed: viewModel.isTesting ? null : () => _test(context),
                  icon: viewModel.isTesting
                      ? const _Spinner()
                      : const Icon(Icons.network_check_outlined),
                  label: Text(l10n.migrationTestButton),
                ),
                OutlinedButton.icon(
                  onPressed: viewModel.isChecking
                      ? null
                      : () => _check(context),
                  icon: viewModel.isChecking
                      ? const _Spinner()
                      : const Icon(Icons.fact_check_outlined),
                  label: Text(l10n.migrationCheckButton),
                ),
              ],
            ],
          ),
          if (viewModel.connectionTest != null) ...[
            SizedBox(height: spacing.sm),
            PointyInlineMessage(
              tone: PointyInlineMessageTone.success,
              icon: Icons.check_circle_outline,
              message: l10n.migrationTestSuccess(
                viewModel.connectionTest!.tableCount,
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Optional transport options (ODBC driver / TDS version / text encoding),
  /// collapsed by default. These are essential for very old SQL Server backends
  /// (e.g. Fahd on SQL Server 2000, which needs the FreeTDS driver + TDS 7.0).
  Widget _buildAdvancedOptions(BuildContext context, AppLocalizations l10n) {
    final spacing = AdaptiveSpacing.of(context);
    return Padding(
      padding: EdgeInsets.only(top: spacing.xs),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: EdgeInsets.only(bottom: spacing.sm),
        leading: const Icon(Icons.tune_outlined),
        title: Text(l10n.migrationAdvancedSectionTitle),
        subtitle: Text(
          l10n.migrationAdvancedSectionSubtitle,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        children: [
          TextField(
            controller: _odbcDriverController,
            textDirection: TextDirection.ltr,
            decoration: InputDecoration(
              labelText: l10n.migrationOdbcDriverLabel,
              hintText: l10n.migrationOdbcDriverHint,
              prefixIcon: const Icon(Icons.cable_outlined),
            ),
          ),
          SizedBox(height: spacing.sm),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _tdsVersionController,
                  textDirection: TextDirection.ltr,
                  decoration: InputDecoration(
                    labelText: l10n.migrationTdsVersionLabel,
                    hintText: l10n.migrationTdsVersionHint,
                  ),
                ),
              ),
              SizedBox(width: spacing.sm),
              Expanded(
                child: TextField(
                  controller: _encodingController,
                  textDirection: TextDirection.ltr,
                  decoration: InputDecoration(
                    labelText: l10n.migrationEncodingLabel,
                    hintText: l10n.migrationEncodingHint,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // --- compatibility ---------------------------------------------------
  Widget _compatibilityCard(BuildContext context, AppLocalizations l10n) {
    final viewModel = widget.viewModel;
    final spacing = AdaptiveSpacing.of(context);
    final report = viewModel.compatibilityReport;
    final colors = context.pointyColors;

    if (report == null || !report.checked) {
      return _SectionCard(
        child: PointyDetailCallout(
          icon: Icons.help_outline,
          tone: PointyCalloutTone.neutral,
          title: l10n.migrationCompatTitle,
          message: l10n.migrationNotChecked,
        ),
      );
    }

    return _SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PointyDetailCallout(
            icon: report.compatible
                ? Icons.verified_outlined
                : Icons.error_outline,
            tone: report.compatible
                ? PointyCalloutTone.success
                : PointyCalloutTone.danger,
            title: report.compatible
                ? l10n.migrationCompatibleMessage
                : l10n.migrationIncompatibleMessage,
            message: report.detectedVersion != null
                ? l10n.migrationDetectedVersion(report.detectedVersion!)
                : null,
            trailing: PointyStatusPill(
              label: report.compatible
                  ? l10n.migrationCompatible
                  : l10n.migrationIncompatible,
              color: report.compatible ? colors.success : colors.danger,
            ),
          ),
          if (report.missingTables.isNotEmpty) ...[
            SizedBox(height: spacing.sm),
            Text(
              l10n.migrationMissingTables,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            SizedBox(height: spacing.xs),
            Wrap(
              spacing: spacing.xs,
              runSpacing: spacing.xs,
              children: [
                for (final table in report.missingTables)
                  PointyStatusPill(label: table, color: colors.danger),
              ],
            ),
          ],
        ],
      ),
    );
  }

  // --- entity selection ------------------------------------------------
  Widget _entitiesCard(BuildContext context, AppLocalizations l10n) {
    final viewModel = widget.viewModel;
    final spacing = AdaptiveSpacing.of(context);
    final entities = viewModel.supportedEntitiesForSelected;

    return _SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.migrationEntitiesSectionTitle,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          SizedBox(height: spacing.xs),
          Text(
            l10n.migrationEntitiesSectionSubtitle,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          SizedBox(height: spacing.sm),
          Wrap(
            spacing: spacing.sm,
            runSpacing: spacing.sm,
            children: [
              for (final entity in entities)
                FilterChip(
                  label: Text(_entityLabel(l10n, viewModel, entity)),
                  selected: viewModel.selectedEntities.contains(entity),
                  onSelected: (value) => viewModel.toggleEntity(entity, value),
                ),
            ],
          ),
          SizedBox(height: spacing.sm),
          Text(
            l10n.migrationStockSourceSectionTitle,
            style: Theme.of(context).textTheme.titleSmall,
          ),
          SizedBox(height: spacing.xs),
          for (final source in MigrationStockSource.values)
            _StockSourceOption(
              label: _stockSourceLabel(l10n, source),
              subtitle: _stockSourceSubtitle(l10n, source),
              selected: viewModel.stockSource == source,
              onTap: () => viewModel.setStockSource(source),
            ),
        ],
      ),
    );
  }

  // --- run + report ----------------------------------------------------
  Widget _runCard(BuildContext context, AppLocalizations l10n) {
    final viewModel = widget.viewModel;
    final spacing = AdaptiveSpacing.of(context);
    final active = viewModel.activeRun;
    final last = viewModel.lastRun;

    return _SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.migrationRunSectionTitle,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          SizedBox(height: spacing.sm),
          if (active != null) ...[
            _progress(context, l10n, active),
          ] else if (last != null) ...[
            _report(context, l10n, last),
          ] else
            Text(
              l10n.migrationDryRunHint,
              style: Theme.of(context).textTheme.bodySmall,
            ),
        ],
      ),
    );
  }

  Widget _progress(
    BuildContext context,
    AppLocalizations l10n,
    MigrationRun run,
  ) {
    final spacing = AdaptiveSpacing.of(context);
    final percent = run.progressPercent.clamp(0, 100) / 100.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              run.progressMessage.isEmpty
                  ? l10n.migrationRunningLabel
                  : run.progressMessage,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            Text('${run.progressPercent}%'),
          ],
        ),
        SizedBox(height: spacing.xs),
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: LinearProgressIndicator(value: percent == 0 ? null : percent),
        ),
      ],
    );
  }

  Widget _report(
    BuildContext context,
    AppLocalizations l10n,
    MigrationRun run,
  ) {
    final viewModel = widget.viewModel;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;

    final (label, color) = switch (run.status) {
      'succeeded' => (l10n.migrationRunSucceeded, colors.success),
      'partial' => (l10n.migrationRunPartial, colors.warning),
      _ => (l10n.migrationRunFailed, colors.danger),
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: PointyStatusPill(label: label, color: color, compact: false),
        ),
        if (run.errorMessage.isNotEmpty) ...[
          SizedBox(height: spacing.sm),
          PointyInlineMessage.error(message: run.errorMessage),
        ],
        SizedBox(height: spacing.sm),
        PointySummaryList(
          rows: [
            for (final summary in run.entitySummaries)
              PointySummaryRow(
                label: _entityLabel(l10n, viewModel, summary.entityType),
                value:
                    '${summary.created} ${l10n.migrationSummaryCreated} · '
                    '${summary.updated} ${l10n.migrationSummaryUpdated} · '
                    '${summary.failed} ${l10n.migrationSummaryFailed}',
                valueColor: summary.failed > 0 ? colors.danger : null,
              ),
          ],
        ),
        if (run.issueCount > 0) ...[
          SizedBox(height: spacing.sm),
          OutlinedButton.icon(
            onPressed: viewModel.isLoadingIssues
                ? null
                : () => viewModel.loadIssues(),
            icon: viewModel.isLoadingIssues
                ? const _Spinner()
                : const Icon(Icons.report_problem_outlined),
            label: Text(
              '${l10n.migrationViewIssuesButton} (${run.issueCount})',
            ),
          ),
          if (viewModel.issues.isNotEmpty) ...[
            SizedBox(height: spacing.sm),
            for (final issue in viewModel.issues)
              PointyDataRow(
                leading: Icon(
                  issue.severity == 'error'
                      ? Icons.error_outline
                      : Icons.warning_amber_outlined,
                  color: issue.severity == 'error'
                      ? colors.danger
                      : colors.warning,
                ),
                title:
                    '${_entityLabel(l10n, viewModel, issue.entityType)} · ${issue.code}',
                subtitle: issue.message,
              ),
          ],
        ],
      ],
    );
  }

  // --- footer (CTAs) ---------------------------------------------------
  Widget _buildFooter(BuildContext context, AppLocalizations l10n) {
    final viewModel = widget.viewModel;
    final system = _currentSystem;
    final canRun =
        system?.implemented == true &&
        viewModel.selectedEntities.isNotEmpty &&
        !(viewModel.activeRun?.isActive ?? false) &&
        !viewModel.isStartingRun;

    return PointyStickyActionFooter(
      summary: Text(
        viewModel.canImport
            ? l10n.migrationDryRunHint
            : l10n.migrationImportGatedHint,
        style: Theme.of(context).textTheme.bodySmall,
      ),
      primaryAction: FilledButton.icon(
        onPressed: (canRun && viewModel.canImport)
            ? () => _startRun(context, dryRun: false)
            : null,
        icon: const Icon(Icons.cloud_upload_outlined),
        label: Text(l10n.migrationImportButton),
      ),
      secondaryActions: [
        FilledButton.tonalIcon(
          onPressed: canRun ? () => _startRun(context, dryRun: true) : null,
          icon: const Icon(Icons.science_outlined),
          label: Text(l10n.migrationDryRunButton),
        ),
      ],
    );
  }

  // --- actions ---------------------------------------------------------
  Future<void> _save(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final system = _currentSystem;
    if (system == null) return;
    final saved = await widget.viewModel.saveSource(
      sourceId: widget.viewModel.selectedSource?.id,
      name: _nameController.text.trim(),
      systemKey: system.systemKey,
      transportKind: system.requiredTransport,
      host: _hostController.text.trim(),
      port: int.tryParse(_portController.text.trim()),
      databaseName: _databaseController.text.trim(),
      username: _usernameController.text.trim(),
      password: _passwordController.text,
      extraOptions: _collectExtraOptions(),
    );
    if (!mounted) return;
    _passwordController.clear();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          saved ? l10n.migrationSourceSaved : l10n.migrationSourceSaveError,
        ),
      ),
    );
  }

  Future<void> _test(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final test = await widget.viewModel.testConnection();
    if (!mounted) return;
    if (test == null) {
      messenger.showSnackBar(SnackBar(content: Text(l10n.migrationTestFailed)));
    }
  }

  Future<void> _check(BuildContext context) async {
    await widget.viewModel.checkCompatibility();
  }

  /// Discovers SQL Server instances on the LAN and lets the operator pick the
  /// client's POS box. Discovery sends no credentials; picking only prefills
  /// host/port — connecting (and any default-credential fallback) happens later
  /// via the Test/Check buttons against the chosen target.
  Future<void> _scanNetwork(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final servers = await widget.viewModel.discoverServers();
    if (!context.mounted) return;
    if (servers == null) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.migrationScanFailed)),
      );
      return;
    }
    final picked = await showDialog<DiscoveredServer>(
      context: context,
      builder: (context) => _ServerPickerDialog(servers: servers),
    );
    if (picked == null || !mounted) return;
    _hostController.text = picked.address;
    _portController.text = picked.tcpPort?.toString() ?? '';
    messenger.showSnackBar(
      SnackBar(content: Text(l10n.migrationScanSelected(picked.displayName))),
    );
  }

  Future<void> _startRun(BuildContext context, {required bool dryRun}) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final run = await widget.viewModel.startRun(dryRun: dryRun);
    if (!mounted) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          run == null
              ? l10n.migrationRunStartError
              : (dryRun
                    ? l10n.migrationDryRunStarted
                    : l10n.migrationImportStarted),
        ),
      ),
    );
  }
}

/// Localised label for an entity type, falling back to the backend's English
/// label (from the systems catalogue) for any type without an Arabic string.
String _entityLabel(
  AppLocalizations l10n,
  MigrationViewModel viewModel,
  String type,
) {
  return switch (type) {
    'unit' => l10n.migrationEntityUnit,
    'category' => l10n.migrationEntityCategory,
    'product' => l10n.migrationEntityProduct,
    'variant' => l10n.migrationEntityVariant,
    'product_unit' => l10n.migrationEntityProductUnit,
    'stock' => l10n.migrationEntityStock,
    'customer' => l10n.migrationEntityCustomer,
    'supplier' => l10n.migrationEntitySupplier,
    'purchase_order' => l10n.migrationEntityPurchaseOrder,
    'supplier_payment' => l10n.migrationEntitySupplierPayment,
    'sale' => l10n.migrationEntitySale,
    'payment' => l10n.migrationEntityPayment,
    'employee' => l10n.migrationEntityEmployee,
    'expense_category' => l10n.migrationEntityExpenseCategory,
    'expense' => l10n.migrationEntityExpense,
    _ => viewModel.entityLabel(type),
  };
}

String _stockSourceLabel(AppLocalizations l10n, MigrationStockSource source) {
  return switch (source) {
    MigrationStockSource.snapshot => l10n.migrationStockSourceSnapshotLabel,
    MigrationStockSource.reconstruct => l10n.migrationStockSourceReconstructLabel,
    MigrationStockSource.none => l10n.migrationStockSourceNoneLabel,
  };
}

String _stockSourceSubtitle(AppLocalizations l10n, MigrationStockSource source) {
  return switch (source) {
    MigrationStockSource.snapshot => l10n.migrationStockSourceSnapshotSubtitle,
    MigrationStockSource.reconstruct => l10n.migrationStockSourceReconstructSubtitle,
    MigrationStockSource.none => l10n.migrationStockSourceNoneSubtitle,
  };
}

/// A single tappable stock-source choice (title + explanation), styled like a
/// radio option without the deprecated [Radio] groupValue API.
class _StockSourceOption extends StatelessWidget {
  const _StockSourceOption({
    required this.label,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
        color: selected ? theme.colorScheme.primary : theme.disabledColor,
      ),
      title: Text(label),
      subtitle: Text(subtitle),
      selected: selected,
      onTap: onTap,
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final spacing = AdaptiveSpacing.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(padding: EdgeInsets.all(spacing.md), child: child),
    );
  }
}

/// Lists the SQL Server instances found on the LAN. Picking one returns it so
/// the caller can prefill host/port — no connection is made here.
class _ServerPickerDialog extends StatelessWidget {
  const _ServerPickerDialog({required this.servers});

  final List<DiscoveredServer> servers;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      title: Text(l10n.migrationScanTitle),
      content: SizedBox(
        width: 360,
        child: servers.isEmpty
            ? PointyInlineMessage(
                tone: PointyInlineMessageTone.neutral,
                icon: Icons.search_off_outlined,
                message: l10n.migrationScanEmpty,
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      l10n.migrationScanSubtitle,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: servers.length,
                      itemBuilder: (context, index) {
                        final server = servers[index];
                        final subtitle = [
                          server.address,
                          if (server.version.isNotEmpty) server.version,
                          if (server.tcpPort != null) 'tcp ${server.tcpPort}',
                        ].join(' · ');
                        return ListTile(
                          leading: const Icon(Icons.dns_outlined),
                          title: Text(
                            server.displayName,
                            textDirection: TextDirection.ltr,
                          ),
                          subtitle: Text(
                            subtitle,
                            textDirection: TextDirection.ltr,
                          ),
                          onTap: () => Navigator.of(context).pop(server),
                        );
                      },
                    ),
                  ),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
        ),
      ],
    );
  }
}

class _Spinner extends StatelessWidget {
  const _Spinner();

  @override
  Widget build(BuildContext context) {
    return const SizedBox.square(
      dimension: 18,
      child: CircularProgressIndicator(strokeWidth: 2),
    );
  }
}
