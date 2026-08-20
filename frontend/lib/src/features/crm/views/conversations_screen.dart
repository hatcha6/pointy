import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../data/models/conversation.dart';
import '../../../data/repositories/contact_repository.dart';
import '../../../shared/app_navigation_drawer.dart';
import '../../../shared/components/components.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../view_models/conversations_view_model.dart';
import 'new_conversation_dialog.dart';

/// Top-level Conversations inbox: the list of customer SMS threads. Tapping a
/// thread opens [ConversationThreadScreen].
class ConversationsScreen extends StatefulWidget {
  const ConversationsScreen({
    super.key,
    required this.viewModel,
    required this.navigation,
    required this.capabilities,
    required this.contactRepository,
  });

  final ConversationsViewModel viewModel;
  final AppNavigation navigation;
  final AuthorizationCapabilities capabilities;
  final ContactRepository contactRepository;

  @override
  State<ConversationsScreen> createState() => _ConversationsScreenState();
}

class _ConversationsScreenState extends State<ConversationsScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(widget.viewModel.load());
    });
  }

  Future<void> _openThread(BuildContext context, Conversation conversation) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ConversationThreadScreen(
          viewModel: widget.viewModel.threadViewModel(conversation),
          canReply: widget.capabilities.canManageConversations,
        ),
      ),
    );
  }

  /// Compose a new thread: pick (or create) a customer with a phone, open the
  /// conversation on the backend, then drop straight into its chat view.
  Future<void> _startNewConversation(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final customer = await showNewConversationDialog(
      context: context,
      contactRepository: widget.contactRepository,
    );
    if (customer == null || !mounted) return;

    final conversation = await widget.viewModel.startConversation(customer);
    if (!mounted) return;
    if (conversation == null) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.newConversationError)),
      );
      return;
    }
    if (!context.mounted) return;
    await _openThread(context, conversation);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.viewModel,
      builder: (context, _) {
        final l10n = AppLocalizations.of(context)!;
        return PointyScaffold(
          drawer: AppNavigationDrawer(
            selectedDestination: AppNavigationDestination.conversations,
            navigation: widget.navigation,
          ),
          appBar: PointyAppBar(
            leading: const PointyNavigationMenuButton(),
            title: Text(l10n.conversationsTitle),
            isLoading: widget.viewModel.isLoading,
            actions: [
              IconButton(
                tooltip: l10n.retryButton,
                onPressed: widget.viewModel.load,
                icon: const Icon(Icons.sync),
              ),
            ],
          ),
          floatingActionButton: widget.capabilities.canManageConversations
              ? FloatingActionButton.extended(
                  key: const ValueKey('conversations_new_fab'),
                  onPressed: widget.viewModel.isStarting
                      ? null
                      : () => _startNewConversation(context),
                  icon: widget.viewModel.isStarting
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.add_comment_outlined),
                  label: Text(
                    widget.viewModel.isStarting
                        ? l10n.newConversationStarting
                        : l10n.newConversationTitle,
                  ),
                )
              : null,
          body: _buildBody(context, l10n),
        );
      },
    );
  }

  Widget _buildBody(BuildContext context, AppLocalizations l10n) {
    final viewModel = widget.viewModel;
    if (viewModel.isLoading && viewModel.isEmpty) {
      return const PointyLoadingArea();
    }
    if (viewModel.hasLoadError && viewModel.isEmpty) {
      return PointyErrorState(
        title: l10n.conversationsLoadError,
        icon: Icons.sms_failed_outlined,
        action: FilledButton.icon(
          onPressed: viewModel.load,
          icon: const Icon(Icons.sync),
          label: Text(l10n.retryButton),
        ),
      );
    }

    final spacing = AdaptiveSpacing.of(context);
    return RefreshIndicator(
      onRefresh: viewModel.load,
      child: ListView(
        padding: spacing.pagePadding,
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          if (viewModel.isEmpty)
            Padding(
              padding: EdgeInsets.only(top: spacing.xl),
              child: PointyEmptyState(
                icon: Icons.forum_outlined,
                title: l10n.conversationsEmpty,
              ),
            )
          else
            for (final conversation in viewModel.conversations)
              _ConversationTile(
                conversation: conversation,
                onTap: () => _openThread(context, conversation),
              ),
        ],
      ),
    );
  }
}

class _ConversationTile extends StatelessWidget {
  const _ConversationTile({required this.conversation, required this.onTap});

  final Conversation conversation;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final when = conversation.lastMessageAt;
    final subtitle = when != null
        ? '${conversation.phone} • ${formatDateTime(when)}'
        : conversation.phone;

    return PointyDataRow(
      leading: CircleAvatar(
        backgroundColor: conversation.hasUnread
            ? colors.primary
            : colors.surfaceSunken,
        child: Icon(
          Icons.person_outline,
          color: conversation.hasUnread ? Colors.white : colors.mutedInk,
        ),
      ),
      title: conversation.title,
      subtitle: subtitle,
      badges: [
        if (conversation.hasUnread)
          PointyStatusPill(
            label: l10n.conversationsUnreadBadge(conversation.unreadCount),
            icon: Icons.mark_chat_unread_outlined,
            color: colors.primary,
          ),
      ],
      onTap: onTap,
    );
  }
}

/// A single customer thread: the message history plus a reply composer (shown
/// only when the user may manage conversations).
class ConversationThreadScreen extends StatefulWidget {
  const ConversationThreadScreen({
    super.key,
    required this.viewModel,
    required this.canReply,
  });

  final ConversationThreadViewModel viewModel;
  final bool canReply;

  @override
  State<ConversationThreadScreen> createState() =>
      _ConversationThreadScreenState();
}

class _ConversationThreadScreenState extends State<ConversationThreadScreen> {
  final _composer = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(widget.viewModel.load());
    });
  }

  @override
  void dispose() {
    _composer.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _composer.text.trim();
    if (text.isEmpty) return;
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final ok = await widget.viewModel.sendReply(text);
    if (!mounted) return;
    if (ok) {
      _composer.clear();
    } else {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.conversationSendError)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.viewModel,
      builder: (context, _) {
        final l10n = AppLocalizations.of(context)!;
        return PointyScaffold(
          appBar: PointyAppBar(
            title: Text(widget.viewModel.title),
            isLoading: widget.viewModel.isLoading,
          ),
          body: Column(
            children: [
              Expanded(child: _buildMessages(context, l10n)),
              if (widget.canReply)
                _Composer(
                  controller: _composer,
                  isSending: widget.viewModel.isSending,
                  onSend: _send,
                )
              else
                _ReadOnlyHint(label: l10n.conversationReadOnly),
            ],
          ),
        );
      },
    );
  }

  Widget _buildMessages(BuildContext context, AppLocalizations l10n) {
    final viewModel = widget.viewModel;
    if (viewModel.isLoading && viewModel.messages.isEmpty) {
      return const PointyLoadingArea();
    }
    if (viewModel.hasLoadError && viewModel.messages.isEmpty) {
      return PointyErrorState(
        title: l10n.conversationsLoadError,
        icon: Icons.sms_failed_outlined,
        action: FilledButton.icon(
          onPressed: viewModel.load,
          icon: const Icon(Icons.sync),
          label: Text(l10n.retryButton),
        ),
      );
    }
    if (viewModel.messages.isEmpty) {
      return PointyEmptyState(
        icon: Icons.forum_outlined,
        title: l10n.conversationThreadEmpty,
      );
    }

    final spacing = AdaptiveSpacing.of(context);
    return ListView(
      padding: spacing.pagePadding,
      children: [
        for (final message in viewModel.messages)
          _MessageBubble(message: message),
      ],
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message});

  final ConversationMessage message;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);
    final textTheme = Theme.of(context).textTheme;
    final outbound = message.isOutbound;
    final bubbleColor = outbound ? colors.primary : colors.surfaceSunken;
    final textColor = outbound ? Colors.white : colors.ink;

    return Align(
      alignment: outbound
          ? AlignmentDirectional.centerEnd
          : AlignmentDirectional.centerStart,
      child: Container(
        margin: EdgeInsets.only(bottom: spacing.sm),
        padding: EdgeInsets.symmetric(
          horizontal: spacing.md,
          vertical: spacing.sm,
        ),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.78,
        ),
        decoration: BoxDecoration(
          color: bubbleColor,
          borderRadius: BorderRadius.circular(PointyRadii.card),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              message.body,
              style: textTheme.bodyMedium?.copyWith(color: textColor),
            ),
            SizedBox(height: spacing.xs),
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: spacing.xs,
              children: [
                if (message.createdAt != null)
                  Text(
                    formatDateTime(message.createdAt!),
                    style: textTheme.labelSmall?.copyWith(
                      color: textColor.withValues(alpha: 0.75),
                    ),
                  ),
                if (outbound)
                  ConversationMessageStatus(
                    status: message.outboundStatus,
                    foreground: textColor,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The delivery state of one outbound SMS, said in words rather than left as a
/// bare glyph.
///
/// The bubble used to render a 14px icon with no label at all, and collapsed
/// every state it did not recognise onto one clock — so `cancelled` and
/// `expired`, which will never arrive, looked exactly like a message still on
/// its way. Each state now carries its Arabic name as a tooltip and a semantics
/// label; the states that need someone to act (a failure, a cancellation, an
/// expiry, or a customer who opted out) also spell themselves out, following
/// the catalog cards' exception-only status idiom.
class ConversationMessageStatus extends StatelessWidget {
  const ConversationMessageStatus({
    super.key,
    required this.status,
    required this.foreground,
  });

  /// The backend `outbound_status` string (apps.messaging `OutboundMessage.Status`).
  final String status;

  /// The bubble's text colour, so the label sits on it legibly.
  final Color foreground;

  /// States the reader has to do something about, and which therefore earn a
  /// visible label instead of an icon alone.
  static bool isException(String status) {
    return const {
      'failed',
      'cancelled',
      'blocked_consent',
      'expired',
    }.contains(status);
  }

  static IconData _icon(String status) {
    return switch (status) {
      'delivered' => Icons.done_all,
      'sent' => Icons.check,
      'sending' => Icons.outgoing_mail,
      'scheduled' => Icons.schedule_send_outlined,
      'failed' => Icons.error_outline,
      'blocked_consent' => Icons.block,
      'cancelled' => Icons.cancel_outlined,
      'expired' => Icons.timer_off_outlined,
      _ => Icons.schedule,
    };
  }

  static String _label(String status, AppLocalizations l10n) {
    return switch (status) {
      'delivered' => l10n.conversationMessageStatusDelivered,
      'sent' => l10n.conversationMessageStatusSent,
      'sending' => l10n.conversationMessageStatusSending,
      'scheduled' => l10n.conversationMessageStatusScheduled,
      'failed' => l10n.conversationMessageStatusFailed,
      'blocked_consent' => l10n.conversationMessageStatusBlocked,
      'cancelled' => l10n.conversationMessageStatusCancelled,
      'expired' => l10n.conversationMessageStatusExpired,
      _ => l10n.conversationMessageStatusQueued,
    };
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);
    final textTheme = Theme.of(context).textTheme;
    final label = _label(status, l10n);
    final spelled = isException(status);

    return Tooltip(
      message: label,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            _icon(status),
            size: 14,
            // Spelled-out states already carry the label as text beside the
            // icon; repeating it here would read it out twice.
            semanticLabel: spelled ? null : label,
            color: status == 'failed'
                ? colors.danger
                : foreground.withValues(alpha: 0.75),
          ),
          if (spelled) ...[
            SizedBox(width: spacing.xs),
            Text(
              label,
              style: textTheme.labelSmall?.copyWith(color: foreground),
            ),
          ],
        ],
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.isSending,
    required this.onSend,
  });

  final TextEditingController controller;
  final bool isSending;
  final Future<void> Function() onSend;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;

    return Material(
      color: colors.surface,
      elevation: 2,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.all(spacing.sm),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  controller: controller,
                  minLines: 1,
                  maxLines: 4,
                  textInputAction: TextInputAction.newline,
                  decoration: InputDecoration(
                    hintText: l10n.conversationReplyHint,
                    isDense: true,
                  ),
                ),
              ),
              SizedBox(width: spacing.sm),
              IconButton.filled(
                tooltip: l10n.conversationSendTooltip,
                onPressed: isSending ? null : onSend,
                icon: isSending
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.send_outlined),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ReadOnlyHint extends StatelessWidget {
  const _ReadOnlyHint({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    return Container(
      width: double.infinity,
      color: colors.surfaceSunken,
      padding: EdgeInsets.all(spacing.md),
      child: Text(
        label,
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: colors.mutedInk,
        ),
      ),
    );
  }
}
