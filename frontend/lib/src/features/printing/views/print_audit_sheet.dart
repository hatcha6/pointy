import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/result.dart';
import '../../../data/models/print_audit_event.dart';
import '../../../data/repositories/printing_repository.dart';
import '../../../shared/components/components.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';

Future<void> showPrintAuditSheet({
  required BuildContext context,
  required PrintingRepository printingRepository,
  required PrintAuditDocumentType documentType,
  required int documentId,
  required String documentNumber,
}) {
  return showAdaptiveModalBottomSheet<void>(
    context: context,
    size: AdaptiveModalSize.expanded,
    maxHeightFactor: 0.82,
    builder: (context) => PrintAuditSheet(
      printingRepository: printingRepository,
      documentType: documentType,
      documentId: documentId,
      documentNumber: documentNumber,
    ),
  );
}

class PrintAuditSheet extends StatefulWidget {
  const PrintAuditSheet({
    super.key,
    required this.printingRepository,
    required this.documentType,
    required this.documentId,
    required this.documentNumber,
  });

  final PrintingRepository printingRepository;
  final PrintAuditDocumentType documentType;
  final int documentId;
  final String documentNumber;

  @override
  State<PrintAuditSheet> createState() => _PrintAuditSheetState();
}

class _PrintAuditSheetState extends State<PrintAuditSheet> {
  List<PrintAuditEvent> _events = const [];
  bool _isLoading = true;
  bool _hasError = false;

  @override
  void initState() {
    super.initState();
    _loadEvents();
  }

  Future<void> _loadEvents() async {
    setState(() {
      _isLoading = true;
      _hasError = false;
    });
    final result = await widget.printingRepository.loadPrintAuditEvents(
      documentType: widget.documentType,
      documentId: widget.documentId,
    );
    if (!mounted) {
      return;
    }
    switch (result) {
      case Ok<List<PrintAuditEvent>>(value: final events):
        setState(() {
          _events = events;
          _isLoading = false;
        });
      case Error<List<PrintAuditEvent>>():
        setState(() {
          _events = const [];
          _isLoading = false;
          _hasError = true;
        });
    }
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
                  l10n.printAuditSheetTitle(widget.documentNumber),
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
                ),
              ),
              IconButton(
                tooltip: l10n.printAuditRefreshTooltip,
                onPressed: _isLoading ? null : _loadEvents,
                icon: const Icon(Icons.sync),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(child: _content(l10n)),
        ],
      ),
    );
  }

  Widget _content(AppLocalizations l10n) {
    if (_isLoading) {
      return PointyLoadingArea(label: l10n.printAuditLoading);
    }
    if (_hasError) {
      return PointyErrorState(
        title: l10n.printAuditLoadError,
        action: OutlinedButton.icon(
          onPressed: _loadEvents,
          icon: const Icon(Icons.sync),
          label: Text(l10n.retryButton),
        ),
      );
    }
    if (_events.isEmpty) {
      return PointyEmptyState(
        icon: Icons.manage_search_outlined,
        title: l10n.printAuditEmptyTitle,
        message: l10n.printAuditEmptyMessage,
      );
    }
    return ListView.separated(
      itemCount: _events.length,
      separatorBuilder: (context, index) => const SizedBox(height: 8),
      itemBuilder: (context, index) =>
          _PrintAuditEventTile(event: _events[index]),
    );
  }
}

class _PrintAuditEventTile extends StatelessWidget {
  const _PrintAuditEventTile({required this.event});

  final PrintAuditEvent event;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final statusLabel = _statusLabel(l10n, event.status);
    final actionLabel = _actionLabel(l10n, event.action);

    return PointyDataRow(
      leading: Icon(_actionIcon(event.action)),
      title: l10n.printAuditEventTitle(actionLabel, statusLabel),
      subtitle: _subtitle(l10n),
      badges: [
        PointyStatusPill(
          label: statusLabel,
          icon: _statusIcon(event.status),
          color: _statusColor(context, event.status),
        ),
      ],
    );
  }

  String _subtitle(AppLocalizations l10n) {
    final deliveryChannel = _deliveryChannelLabel(l10n);
    final printerLabel = _printerLabel();
    final endpointSummary = _endpointSummary();
    return [
      if (event.performedAt != null)
        l10n.printAuditTimeValue(formatDateTime(event.performedAt!)),
      l10n.printAuditActorValue(_actorLabel(l10n)),
      if (event.deviceName.trim().isNotEmpty)
        l10n.printAuditDeviceValue(event.deviceName.trim()),
      if (deliveryChannel != null) l10n.printAuditChannelValue(deliveryChannel),
      if (printerLabel != null) l10n.printAuditPrinterValue(printerLabel),
      if (endpointSummary != null)
        l10n.printAuditEndpointValue(endpointSummary),
      if (event.printJobId != null) l10n.printAuditJobValue(event.printJobId!),
      if (event.message.trim().isNotEmpty)
        l10n.printAuditMessageValue(event.message.trim()),
    ].join(' • ');
  }

  String _actorLabel(AppLocalizations l10n) {
    final username = event.username?.trim() ?? '';
    if (username.isNotEmpty) {
      return username;
    }
    final agent = event.agentIdentifier?.trim() ?? '';
    if (agent.isNotEmpty) {
      return agent;
    }
    return l10n.printAuditUnknownActor;
  }

  String? _deliveryChannelLabel(AppLocalizations l10n) {
    final channel = event.metadata['delivery_channel']?.toString();
    return switch (channel) {
      'native_share_sheet' => l10n.printAuditChannelNativeShare,
      'file_save_dialog' => l10n.printAuditChannelFileSave,
      'browser_download' => l10n.printAuditChannelBrowserDownload,
      String() when channel.trim().isNotEmpty => channel,
      _ => null,
    };
  }

  String? _printerLabel() {
    final name = event.printerName.trim();
    if (name.isNotEmpty && name != 'PDF') {
      return name;
    }
    final defaultEndpoint = event.metadata['default_printer_endpoint'];
    if (defaultEndpoint is Map<String, Object?>) {
      return _endpointName(defaultEndpoint);
    }
    if (defaultEndpoint is Map) {
      return _endpointName({
        for (final entry in defaultEndpoint.entries)
          entry.key.toString(): entry.value,
      });
    }
    return null;
  }

  String? _endpointSummary() {
    final endpoint = event.printerEndpoint;
    final parts = [
      endpoint['kind']?.toString(),
      endpoint['output_mode']?.toString(),
      endpoint['address']?.toString(),
      if (endpoint['paper_width_mm'] != null) '${endpoint['paper_width_mm']}mm',
    ].whereType<String>().where((part) => part.trim().isNotEmpty).toList();
    if (parts.isEmpty) {
      return null;
    }
    return parts.join(' / ');
  }

  String? _endpointName(Map<String, Object?> endpoint) {
    for (final key in ['name', 'address', 'kind']) {
      final value = endpoint[key]?.toString().trim() ?? '';
      if (value.isNotEmpty) {
        return value;
      }
    }
    return null;
  }
}

String _actionLabel(AppLocalizations l10n, PrintAuditAction action) {
  return switch (action) {
    PrintAuditAction.print => l10n.printAuditActionPrint,
    PrintAuditAction.share => l10n.printAuditActionShare,
  };
}

String _statusLabel(AppLocalizations l10n, PrintAuditStatus status) {
  return switch (status) {
    PrintAuditStatus.requested => l10n.printAuditStatusRequested,
    PrintAuditStatus.completed => l10n.printAuditStatusCompleted,
    PrintAuditStatus.canceled => l10n.printAuditStatusCanceled,
    PrintAuditStatus.failed => l10n.printAuditStatusFailed,
  };
}

IconData _actionIcon(PrintAuditAction action) {
  return switch (action) {
    PrintAuditAction.print => Icons.print_outlined,
    PrintAuditAction.share => Icons.ios_share_outlined,
  };
}

IconData _statusIcon(PrintAuditStatus status) {
  return switch (status) {
    PrintAuditStatus.completed => Icons.check_circle_outline,
    PrintAuditStatus.canceled => Icons.remove_circle_outline,
    PrintAuditStatus.failed => Icons.error_outline,
    PrintAuditStatus.requested => Icons.schedule_outlined,
  };
}

Color _statusColor(BuildContext context, PrintAuditStatus status) {
  final colors = context.pointyColors;
  return switch (status) {
    PrintAuditStatus.completed => colors.primaryStrong,
    PrintAuditStatus.canceled => colors.accentAmber,
    PrintAuditStatus.failed => colors.danger,
    PrintAuditStatus.requested => colors.success,
  };
}
