import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/ai_memory.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';
import '../view_models/ai_memory_view_model.dart';

/// Opens the memory screen: everything the assistant carries into new
/// conversations, so people can see it, correct it and remove it.
Future<void> showAiMemorySheet(
  BuildContext context,
  AiMemoryViewModel viewModel,
) {
  unawaited(viewModel.load());
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => AiMemorySheet(viewModel: viewModel),
  );
}

class AiMemorySheet extends StatelessWidget {
  const AiMemorySheet({super.key, required this.viewModel});

  final AiMemoryViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.85,
        ),
        child: ListenableBuilder(
          listenable: viewModel,
          builder: (context, _) {
            final Widget body;
            if (viewModel.isLoading && viewModel.isEmpty) {
              body = Padding(
                padding: spacing.pagePadding,
                child: const Center(child: PointySpinner()),
              );
            } else if (viewModel.failed) {
              body = Padding(
                padding: spacing.pagePadding,
                child: Column(
                  children: [
                    Text(
                      l10n.aiMemoryLoadFailed,
                      style: TextStyle(color: colors.mutedInk),
                    ),
                    SizedBox(height: spacing.sm),
                    OutlinedButton(
                      onPressed: () => unawaited(viewModel.load()),
                      child: Text(l10n.retryButton),
                    ),
                  ],
                ),
              );
            } else if (viewModel.isEmpty) {
              body = Padding(
                padding: spacing.pagePadding,
                child: Text(
                  l10n.aiMemoryEmpty,
                  style: TextStyle(color: colors.mutedInk),
                ),
              );
            } else {
              body = Flexible(
                child: ListView(
                  shrinkWrap: true,
                  padding: EdgeInsets.only(bottom: spacing.md),
                  children: [
                    ..._section(
                      context,
                      l10n.aiMemoryShopSection,
                      viewModel.shopMemories,
                    ),
                    ..._section(
                      context,
                      l10n.aiMemoryPersonalSection,
                      viewModel.personalMemories,
                    ),
                  ],
                ),
              );
            }
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    spacing.lg,
                    0,
                    spacing.lg,
                    spacing.sm,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(l10n.aiMemoryTitle, style: textTheme.titleMedium),
                      SizedBox(height: spacing.xs),
                      Text(
                        l10n.aiMemorySubtitle,
                        style: textTheme.bodySmall?.copyWith(
                          color: colors.mutedInk,
                        ),
                      ),
                    ],
                  ),
                ),
                body,
              ],
            );
          },
        ),
      ),
    );
  }

  List<Widget> _section(
    BuildContext context,
    String title,
    List<AiMemory> memories,
  ) {
    if (memories.isEmpty) {
      return const [];
    }
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    return [
      Padding(
        padding: EdgeInsets.fromLTRB(
          spacing.lg,
          spacing.sm,
          spacing.lg,
          spacing.xs,
        ),
        child: Text(
          title,
          style: Theme.of(
            context,
          ).textTheme.labelLarge?.copyWith(color: colors.mutedInk),
        ),
      ),
      for (final memory in memories)
        _MemoryTile(
          key: ValueKey(memory.id),
          memory: memory,
          viewModel: viewModel,
        ),
    ];
  }
}

class _MemoryTile extends StatelessWidget {
  const _MemoryTile({super.key, required this.memory, required this.viewModel});

  final AiMemory memory;
  final AiMemoryViewModel viewModel;

  Future<void> _edit(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final content = await showDialog<String>(
      context: context,
      builder: (_) => _EditMemoryDialog(initial: memory.content),
    );
    if (content == null) {
      return;
    }
    if (!await viewModel.update(memory, content)) {
      messenger.showSnackBar(SnackBar(content: Text(l10n.aiMemorySaveFailed)));
    }
  }

  Future<void> _delete(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.delete_outline),
        title: Text(l10n.aiMemoryDeleteTitle),
        content: Text(memory.content),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.cancelButton),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.deleteButton),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }
    if (!await viewModel.delete(memory)) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.aiMemoryDeleteFailed)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    return ListTile(
      leading: Icon(
        memory.isShop ? Icons.storefront_outlined : Icons.person_outline,
        color: colors.mutedInk,
      ),
      title: Text(memory.content),
      trailing: memory.editable
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: l10n.editButton,
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: () => unawaited(_edit(context)),
                ),
                IconButton(
                  tooltip: l10n.deleteButton,
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => unawaited(_delete(context)),
                ),
              ],
            )
          : Tooltip(
              message: l10n.aiMemoryManagerOnly,
              child: Icon(Icons.lock_outline, size: 18, color: colors.mutedInk),
            ),
    );
  }
}

/// Owns its text controller, so the field outlives the dialog's closing
/// animation instead of being disposed under it.
class _EditMemoryDialog extends StatefulWidget {
  const _EditMemoryDialog({required this.initial});

  final String initial;

  @override
  State<_EditMemoryDialog> createState() => _EditMemoryDialogState();
}

class _EditMemoryDialogState extends State<_EditMemoryDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      title: Text(l10n.aiMemoryEditTitle),
      content: TextField(
        key: const ValueKey('ai_memory_edit_field'),
        controller: _controller,
        autofocus: true,
        minLines: 2,
        maxLines: 5,
        maxLength: 400,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancelButton),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: Text(l10n.saveButton),
        ),
      ],
    );
  }
}
