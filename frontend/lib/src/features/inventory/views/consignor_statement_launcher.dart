import 'package:flutter/material.dart';

import '../../../core/authorization.dart';
import '../../../core/result.dart';
import '../../../data/models/consignor_statement.dart';
import '../../../data/repositories/consignment_repository.dart';
import '../view_models/consignment_document_printer.dart';
import '../view_models/consignor_statement_view_model.dart';
import 'consignor_statement_screen.dart';

/// Everything a screen needs to open a consignor's statement, in one handle.
///
/// The payables list and the customer page both reach the statement; neither
/// should have to know which repositories a statement prints with. Built once
/// by the app shell and only for a user who may see consignment liabilities,
/// so a null launcher is the permission check.
class ConsignorStatementLauncher {
  const ConsignorStatementLauncher({
    required this.repository,
    required this.capabilities,
    this.printer = const ConsignmentDocumentPrinter(),
  });

  final ConsignmentRepository repository;
  final AuthorizationCapabilities capabilities;
  final ConsignmentDocumentPrinter printer;

  Future<void> open(
    BuildContext context, {
    required int consignorId,
    String consignorName = '',
  }) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _OwnedStatement(
          launcher: this,
          consignorId: consignorId,
          consignorName: consignorName,
        ),
      ),
    );
  }

  /// The headline alone — whether this customer ever consigned anything, and
  /// what is owed them — for a page that only shows a summary.
  Future<Result<ConsignorStatementPage>> loadSummary(int consignorId) {
    return repository.loadStatement(consignorId, summaryOnly: true);
  }
}

/// The route's own view model: created with the page, disposed with it.
class _OwnedStatement extends StatefulWidget {
  const _OwnedStatement({
    required this.launcher,
    required this.consignorId,
    required this.consignorName,
  });

  final ConsignorStatementLauncher launcher;
  final int consignorId;
  final String consignorName;

  @override
  State<_OwnedStatement> createState() => _OwnedStatementState();
}

class _OwnedStatementState extends State<_OwnedStatement> {
  late final ConsignorStatementViewModel _viewModel =
      ConsignorStatementViewModel(
        widget.launcher.repository,
        consignorId: widget.consignorId,
        consignorName: widget.consignorName,
        printer: widget.launcher.printer,
      );

  @override
  void dispose() {
    _viewModel.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ConsignorStatementScreen(
      viewModel: _viewModel,
      capabilities: widget.launcher.capabilities,
    );
  }
}
