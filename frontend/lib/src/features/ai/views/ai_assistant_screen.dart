import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/ai_chat.dart';
import '../../../shared/app_navigation_drawer.dart';
import '../../../shared/async_selection/async_multi_select_picker.dart';
import '../../../shared/navigation/ai_deep_link.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../view_models/ai_chat_view_model.dart';

const double _maxContentWidth = 860;
const double _bubbleRadius = 18;
const double _bubbleTail = 6;

/// Loads a page of products for the ask_user product_picker question — the same
/// shape the shared async picker expects, with each option keyed by the product's
/// default VARIANT id (what a purchase-order line references) and labelled by
/// product name. Injected from the app shell (where the catalog repository lives)
/// so the AI feature stays decoupled from the catalog data layer.
typedef AiProductSearch =
    Future<AsyncSelectionPage<int>> Function(String search, int page);

/// Opens a deep link the AI emitted (a screen or an entity detail). Injected
/// from the app shell, which owns navigation + the repositories. Returns false
/// if the target can't be opened (unknown / no permission / load failed).
typedef AiLinkHandler =
    Future<bool> Function(BuildContext context, AiDeepLink link);

/// The AI assistant: a streaming chat with the relay-hosted model. The relay
/// auto-selects the model from the prompt's difficulty, so the user just types.
/// Arabic-first and RTL; only reachable when the shop's AI entitlement is active.
class AiAssistantScreen extends StatefulWidget {
  const AiAssistantScreen({
    super.key,
    required this.viewModel,
    required this.navigation,
    this.productSearch,
    this.onOpenAiLink,
  });

  final AiChatViewModel viewModel;
  final AppNavigation navigation;

  /// Loads products for a product_picker question. Null when the host didn't wire
  /// a catalog source — the picker degrades to "create new product" only.
  final AiProductSearch? productSearch;

  /// Opens an in-app deep link the AI emitted in its reply. Null when the host
  /// didn't wire navigation — links then render as plain (inert) text.
  final AiLinkHandler? onOpenAiLink;

  @override
  State<AiAssistantScreen> createState() => _AiAssistantScreenState();
}

class _AiAssistantScreenState extends State<AiAssistantScreen> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _inputFocus = FocusNode();
  final ScrollController _scrollController = ScrollController();

  /// The streaming reply we follow for auto-scroll. We listen to this single
  /// message (not the view model) so a token only triggers a coalesced scroll —
  /// never a rebuild of the screen.
  AiMessage? _followedMessage;

  /// Coalesces scroll-follows to one per frame; without it, 25 tokens/sec would
  /// kick off 25 overlapping scroll animations that fight each other (jank).
  bool _autoScrollQueued = false;

  /// Tracks structural changes (turns added / conversation opened) vs. mere
  /// token growth, so we only force a scroll-to-bottom on the former.
  int _lastMessageCount = 0;

  @override
  void initState() {
    super.initState();
    widget.viewModel.addListener(_handleModelChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(widget.viewModel.loadHistory());
        unawaited(widget.viewModel.loadUsage());
      }
    });
  }

  @override
  void dispose() {
    _followedMessage?.removeListener(_handleStreamTick);
    widget.viewModel.removeListener(_handleModelChanged);
    _controller.dispose();
    _inputFocus.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _handleModelChanged() {
    if (widget.viewModel.imageLimitReached) {
      widget.viewModel.acknowledgeImageLimit();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _showImageLimitNotice();
        }
      });
    }
    _syncScrollFollow();
    // Only the view model's *structural* changes (a turn added, a conversation
    // opened) reach this listener now — streamed tokens notify their own bubble.
    // So an ease-to-bottom here is cheap and runs at most a couple times a turn.
    final count = widget.viewModel.messages.length;
    if (count != _lastMessageCount) {
      _lastMessageCount = count;
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    }
  }

  /// Attach/detach the scroll-follow listener as the streaming message changes.
  void _syncScrollFollow() {
    final streaming = widget.viewModel.streamingMessage;
    if (identical(streaming, _followedMessage)) {
      return;
    }
    _followedMessage?.removeListener(_handleStreamTick);
    _followedMessage = streaming;
    _followedMessage?.addListener(_handleStreamTick);
  }

  void _handleStreamTick() => _queueAutoScroll();

  /// Pin to the bottom as the reply grows — but only if the user is already near
  /// it (don't yank them up while they read earlier replies), and at most once
  /// per frame. Uses [ScrollController.jumpTo] so growth never spawns competing
  /// animations.
  void _queueAutoScroll() {
    if (_autoScrollQueued || !_isNearBottom()) {
      return;
    }
    _autoScrollQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _autoScrollQueued = false;
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
    });
  }

  bool _isNearBottom() {
    if (!_scrollController.hasClients) {
      return true;
    }
    final position = _scrollController.position;
    return position.maxScrollExtent - position.pixels < 280;
  }

  void _showImageLimitNotice() {
    final l10n = AppLocalizations.of(context)!;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(l10n.aiAssistantImageLimit(widget.viewModel.maxImages))),
      );
  }

  void _scrollToBottom() {
    if (!_scrollController.hasClients) {
      return;
    }
    _scrollController.animateTo(
      _scrollController.position.maxScrollExtent,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  void _send() {
    if (widget.viewModel.isStreaming || widget.viewModel.hasPendingQuestion) {
      return;
    }
    final text = _controller.text;
    if (text.trim().isEmpty && !widget.viewModel.hasPendingAttachments) {
      return;
    }
    _controller.clear();
    unawaited(widget.viewModel.sendMessage(text));
  }

  void _submitAnswer(List<AiAnswer> answers) {
    unawaited(widget.viewModel.submitAnswer(answers));
  }

  void _skipQuestion() {
    unawaited(widget.viewModel.skipQuestion());
  }

  /// A tapped link inside an assistant reply. In-app `pointy://` links route via
  /// the injected handler; anything else (a plain web URL) is left alone rather
  /// than opening a browser.
  void _handleAssistantLink(String url) {
    final handler = widget.onOpenAiLink;
    if (handler == null) {
      return;
    }
    final link = AiDeepLink.tryParse(url);
    if (link == null) {
      return;
    }
    unawaited(_openAssistantLink(handler, link));
  }

  Future<void> _openAssistantLink(AiLinkHandler handler, AiDeepLink link) async {
    final opened = await handler(context, link);
    if (!opened && mounted) {
      final l10n = AppLocalizations.of(context)!;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.aiAssistantLinkUnavailable)),
      );
    }
  }

  Future<void> _openAttachSheet() async {
    final viewModel = widget.viewModel;
    final choice = await showModalBottomSheet<_AttachChoice>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) =>
          _AttachSheet(canAddImage: viewModel.canAddImage),
    );
    if (choice == null || !mounted) {
      return;
    }
    switch (choice) {
      case _AttachChoice.gallery:
        await viewModel.addImage(fromCamera: false);
      case _AttachChoice.camera:
        await viewModel.addImage(fromCamera: true);
      case _AttachChoice.file:
        await viewModel.addFiles();
    }
  }

  Future<void> _openUsageSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => _UsageSheet(usage: widget.viewModel.usage),
    );
  }

  void _retry(AiMessage message) {
    unawaited(widget.viewModel.retry(message));
  }

  Future<void> _edit(AiMessage message) async {
    final text = await widget.viewModel.rewindForEdit(message);
    if (text == null || !mounted) {
      return;
    }
    _controller
      ..text = text
      ..selection = TextSelection.collapsed(offset: text.length);
    _inputFocus.requestFocus();
  }

  Future<void> _copy(AiMessage message) async {
    await Clipboard.setData(ClipboardData(text: message.content));
    if (!mounted) {
      return;
    }
    final l10n = AppLocalizations.of(context)!;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(l10n.aiAssistantCopied)));
  }

  void _sendSuggestion(String text) {
    if (widget.viewModel.isStreaming || widget.viewModel.hasPendingQuestion) {
      return;
    }
    unawaited(widget.viewModel.sendMessage(text));
  }

  Future<void> _openHistory() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => _HistorySheet(
        viewModel: widget.viewModel,
        onSelect: (id) {
          Navigator.of(sheetContext).pop();
          unawaited(widget.viewModel.openConversation(id));
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.viewModel,
      builder: (context, _) {
        final l10n = AppLocalizations.of(context)!;
        final colors = context.pointyColors;
        final viewModel = widget.viewModel;

        return PointyScaffold(
          drawer: AppNavigationDrawer(
            selectedDestination: AppNavigationDestination.aiAssistant,
            navigation: widget.navigation,
          ),
          appBar: AppBar(
            leading: const PointyNavigationMenuButton(),
            titleSpacing: 0,
            title: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const _AssistantMark(size: 28, iconSize: 15),
                const SizedBox(width: 8),
                Text(l10n.aiAssistantTitle),
              ],
            ),
            actions: [
              IconButton(
                tooltip: l10n.aiAssistantHistoryTitle,
                onPressed: viewModel.isStreaming ? null : _openHistory,
                icon: const Icon(Icons.history),
              ),
              IconButton(
                tooltip: l10n.aiAssistantNewChat,
                onPressed: viewModel.isStreaming || !viewModel.hasMessages
                    ? null
                    : viewModel.startNewConversation,
                icon: const Icon(Icons.add_comment_outlined),
              ),
            ],
          ),
          body: Container(
            color: colors.page,
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: _maxContentWidth),
              child: Column(
                children: [
                  Expanded(
                    child: viewModel.hasMessages
                        ? _MessageList(
                            controller: _scrollController,
                            messages: viewModel.messages,
                            isStreaming: viewModel.isStreaming,
                            onRetry: _retry,
                            onEdit: _edit,
                            onCopy: _copy,
                            onAnswer: _submitAnswer,
                            onSkip: _skipQuestion,
                            productSearch: widget.productSearch,
                            onLinkTap: _handleAssistantLink,
                          )
                        : _EmptyState(onSuggestion: _sendSuggestion),
                  ),
                  if (viewModel.errorKind != null)
                    Padding(
                      padding: EdgeInsets.fromLTRB(
                        AdaptiveSpacing.of(context).lg,
                        0,
                        AdaptiveSpacing.of(context).lg,
                        AdaptiveSpacing.of(context).xs,
                      ),
                      child: PointyInlineMessage.error(
                        message: _errorText(l10n, viewModel.errorKind!),
                        compact: true,
                      ),
                    ),
                  _Composer(
                    controller: _controller,
                    focusNode: _inputFocus,
                    viewModel: viewModel,
                    onSend: _send,
                    onAttach: _openAttachSheet,
                    onUsage: _openUsageSheet,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  String _errorText(AppLocalizations l10n, AiChatErrorKind kind) {
    return switch (kind) {
      AiChatErrorKind.notEntitled => l10n.aiAssistantErrorNotEntitled,
      AiChatErrorKind.network => l10n.aiAssistantErrorNetwork,
      AiChatErrorKind.rateLimited => l10n.aiAssistantErrorRateLimited,
      AiChatErrorKind.tooManyImages => l10n.aiAssistantErrorTooManyImages,
      AiChatErrorKind.server ||
      AiChatErrorKind.aiError => l10n.aiAssistantErrorGeneric,
    };
  }
}

class _MessageList extends StatelessWidget {
  const _MessageList({
    required this.controller,
    required this.messages,
    required this.isStreaming,
    required this.onRetry,
    required this.onEdit,
    required this.onCopy,
    required this.onAnswer,
    required this.onSkip,
    required this.productSearch,
    required this.onLinkTap,
  });

  final ScrollController controller;
  final List<AiMessage> messages;
  final bool isStreaming;
  final ValueChanged<AiMessage> onRetry;
  final ValueChanged<AiMessage> onEdit;
  final ValueChanged<AiMessage> onCopy;
  final ValueChanged<List<AiAnswer>> onAnswer;
  final VoidCallback onSkip;
  final AiProductSearch? productSearch;
  final ValueChanged<String> onLinkTap;

  @override
  Widget build(BuildContext context) {
    final spacing = AdaptiveSpacing.of(context);
    return ListView.separated(
      controller: controller,
      padding: EdgeInsets.symmetric(
        horizontal: spacing.lg,
        vertical: spacing.lg,
      ),
      itemCount: messages.length,
      separatorBuilder: (_, _) => SizedBox(height: spacing.lg),
      itemBuilder: (context, index) {
        final message = messages[index];
        final Widget child;
        if (message.isUser) {
          // Edit/retry rewind the conversation server-side, so only offer them
          // once the turn is persisted (has an id) and nothing is streaming.
          child = _UserMessage(
            message: message,
            showActions: !isStreaming && message.id != null,
            onRetry: () => onRetry(message),
            onEdit: () => onEdit(message),
          );
        } else {
          child = _AssistantMessage(
            message: message,
            showCopy: !isStreaming && message.content.isNotEmpty,
            onCopy: () => onCopy(message),
            onAnswer: onAnswer,
            onSkip: onSkip,
            productSearch: productSearch,
            onLinkTap: onLinkTap,
          );
        }
        // A stable per-message key preserves each bubble's element (and so its
        // memoized markdown) across structural rebuilds and rewinds; the repaint
        // boundary keeps a streaming bubble's repaints off its neighbours.
        return RepaintBoundary(
          key: ValueKey<AiMessage>(message),
          child: child,
        );
      },
    );
  }
}

/// The user's turn — a compact primary bubble aligned to the trailing edge,
/// with edit (rewind) + retry actions revealed underneath once it's persisted.
class _UserMessage extends StatelessWidget {
  const _UserMessage({
    required this.message,
    required this.showActions,
    required this.onRetry,
    required this.onEdit,
  });

  final AiMessage message;
  final bool showActions;
  final VoidCallback onRetry;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);
    final l10n = AppLocalizations.of(context)!;
    final maxWidth =
        math.min(MediaQuery.sizeOf(context).width, _maxContentWidth) * 0.82;
    final base = Theme.of(context).textTheme.bodyMedium ?? const TextStyle();
    final hasText = message.content.isNotEmpty;

    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (message.attachments.isNotEmpty) ...[
              _SentAttachments(attachments: message.attachments),
              if (hasText) SizedBox(height: spacing.xs),
            ],
            if (hasText)
              Container(
                padding: EdgeInsets.symmetric(
                  horizontal: spacing.md,
                  vertical: spacing.sm + 2,
                ),
                decoration: BoxDecoration(
                  color: colors.primary,
                  borderRadius: const BorderRadiusDirectional.only(
                    topStart: Radius.circular(_bubbleRadius),
                    topEnd: Radius.circular(_bubbleRadius),
                    bottomStart: Radius.circular(_bubbleTail),
                    bottomEnd: Radius.circular(_bubbleRadius),
                  ),
                ),
                child: SelectableText(
                  message.content,
                  style: base.copyWith(color: Colors.white, height: 1.45),
                ),
              ),
            if (showActions)
              _MessageActions(
                actions: [
                  _MessageAction(
                    icon: Icons.edit_outlined,
                    tooltip: l10n.aiAssistantActionEdit,
                    onTap: onEdit,
                  ),
                  _MessageAction(
                    icon: Icons.refresh_rounded,
                    tooltip: l10n.aiAssistantActionRetry,
                    onTap: onRetry,
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

/// The assistant's turn — rendered directly on the background (no card, no
/// avatar), with the model's thinking in a collapsed-by-default disclosure.
class _AssistantMessage extends StatelessWidget {
  const _AssistantMessage({
    required this.message,
    required this.showCopy,
    required this.onCopy,
    required this.onAnswer,
    required this.onSkip,
    required this.productSearch,
    required this.onLinkTap,
  });

  final AiMessage message;
  final bool showCopy;
  final VoidCallback onCopy;
  final ValueChanged<List<AiAnswer>> onAnswer;
  final VoidCallback onSkip;
  final AiProductSearch? productSearch;
  final ValueChanged<String> onLinkTap;

  @override
  Widget build(BuildContext context) {
    final spacing = AdaptiveSpacing.of(context);
    final l10n = AppLocalizations.of(context)!;

    // Listen to the message itself: streamed deltas notify only this listenable,
    // so the rebuild is scoped to this one bubble — never the list or its peers.
    // Coalesced to one rebuild per frame so a burst of tokens re-parses the
    // markdown at most at the refresh rate, not once per token.
    return _CoalescedBuilder(
      listenable: message,
      builder: (context) {
        final showTyping = message.isStreaming && message.content.isEmpty;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (message.toolRuns.isNotEmpty) ...[
              _ToolRunChips(runs: message.toolRuns),
              SizedBox(height: spacing.sm),
            ],
            if (message.reasoning.isNotEmpty) ...[
              _ThinkingDisclosure(reasoning: message.reasoning),
              SizedBox(height: spacing.sm),
            ],
            if (showTyping)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 4),
                child: _TypingIndicator(),
              )
            else if (message.content.isNotEmpty)
              _AssistantText(message: message, onLinkTap: onLinkTap),
            if (message.pendingQuestion != null) ...[
              if (message.content.isNotEmpty) SizedBox(height: spacing.sm),
              _QuestionCard(
                message: message,
                onSubmit: onAnswer,
                onSkip: onSkip,
                productSearch: productSearch,
              ),
            ],
            if (showCopy)
              _MessageActions(
                actions: [
                  _MessageAction(
                    icon: Icons.copy_rounded,
                    tooltip: l10n.aiAssistantActionCopy,
                    onTap: onCopy,
                  ),
                ],
              ),
          ],
        );
      },
    );
  }
}

/// Like [ListenableBuilder], but collapses a burst of notifications into a single
/// rebuild per frame. A streamed reply can notify on every token; if several land
/// within one frame, an eager rebuild would re-parse the bubble's markdown
/// multiple times for nothing. Deferring to a frame callback caps the work to the
/// display's refresh rate while still rendering the final text (the trailing
/// notification always schedules one last build).
class _CoalescedBuilder extends StatefulWidget {
  const _CoalescedBuilder({required this.listenable, required this.builder});

  final Listenable listenable;
  final WidgetBuilder builder;

  @override
  State<_CoalescedBuilder> createState() => _CoalescedBuilderState();
}

class _CoalescedBuilderState extends State<_CoalescedBuilder> {
  bool _frameScheduled = false;

  @override
  void initState() {
    super.initState();
    widget.listenable.addListener(_handleChange);
  }

  @override
  void didUpdateWidget(_CoalescedBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.listenable != widget.listenable) {
      oldWidget.listenable.removeListener(_handleChange);
      widget.listenable.addListener(_handleChange);
    }
  }

  @override
  void dispose() {
    widget.listenable.removeListener(_handleChange);
    super.dispose();
  }

  void _handleChange() {
    if (_frameScheduled) {
      return;
    }
    _frameScheduled = true;
    SchedulerBinding.instance.scheduleFrameCallback((_) {
      _frameScheduled = false;
      if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);
}

/// Renders the assistant's reply as formatted markdown (headings, lists, tables,
/// code, bold/italic, links) via gpt_markdown — which tolerates the partial,
/// mid-stream markdown a live reply produces, so it renders progressively as
/// tokens arrive. Wrapped in a SelectionArea so the rendered text stays
/// selectable. RTL/LTR follows the ambient direction.
class _AssistantText extends StatefulWidget {
  const _AssistantText({required this.message, required this.onLinkTap});

  final AiMessage message;
  final ValueChanged<String> onLinkTap;

  @override
  State<_AssistantText> createState() => _AssistantTextState();
}

class _AssistantTextState extends State<_AssistantText> {
  Widget? _cached;
  String? _content;
  TextStyle? _style;
  TextDirection? _direction;

  // A stable method reference (not a fresh closure), so it's NOT a memoization
  // input — the cached GptMarkdown keeps it across rebuilds, and it reads the
  // current widget's callback at tap time (links stay live even when memoized).
  void _handleLinkTap(String url, String title) => widget.onLinkTap(url);

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final base = Theme.of(context).textTheme.bodyMedium ?? const TextStyle();
    final style = base.copyWith(color: colors.ink, height: 1.55);
    final direction = Directionality.of(context);
    final content = widget.message.content;

    // GptMarkdown re-parses its entire input on every build. Memoize the rendered
    // tree by its inputs and hand back the *same* widget instance when nothing
    // changed — the framework then short-circuits the rebuild, so a structural
    // rebuild (or a sibling streaming) never re-parses a settled reply. Only
    // genuinely new text (this turn while it streams) pays the parse cost.
    if (_cached == null ||
        content != _content ||
        style != _style ||
        direction != _direction) {
      _content = content;
      _style = style;
      _direction = direction;
      _cached = GptMarkdown(
        content,
        style: style,
        textDirection: direction,
        onLinkTap: _handleLinkTap,
      );
    }
    return SelectionArea(child: _cached!);
  }
}

/// Sentinel value for the user-entered "other" option on select questions.
const String _kQuestionOther = '__ask_user_other__';

/// The interactive card for an assistant's ask_user question(s): one control per
/// question type (single/multi-select with an "other" entry, free text, number,
/// yes/no), validated, with Submit + Skip. On submit it builds the structured
/// answers and resumes the agentic turn; after submitting it flips to a compact
/// read-only summary. RTL throughout (AlignmentDirectional / pointyColors).
class _QuestionCard extends StatefulWidget {
  const _QuestionCard({
    required this.message,
    required this.onSubmit,
    required this.onSkip,
    required this.productSearch,
  });

  final AiMessage message;
  final ValueChanged<List<AiAnswer>> onSubmit;
  final VoidCallback onSkip;
  final AiProductSearch? productSearch;

  @override
  State<_QuestionCard> createState() => _QuestionCardState();
}

/// A product_picker choice in progress: an existing product (its default variant
/// id + name) or the "create a new product" path.
class _ProductChoice {
  const _ProductChoice.existing(this.variantId, this.name) : createNew = false;
  const _ProductChoice.createNew() : variantId = null, name = null, createNew = true;

  final int? variantId;
  final String? name;
  final bool createNew;
}

class _QuestionCardState extends State<_QuestionCard> {
  final Map<String, String?> _single = {}; // option value or _kQuestionOther
  final Map<String, Set<String>> _multi = {};
  final Map<String, bool?> _confirm = {};
  final Map<String, TextEditingController> _text = {};
  final Map<String, _ProductChoice> _product = {};
  final Map<String, String?> _errors = {};
  bool _submitting = false;

  List<AiQuestion> get _questions =>
      widget.message.pendingQuestion?.questions ?? const [];

  // Every editable field (free text, number, and the "other" entry) is backed by
  // a persisted controller so the visible text is the single source of truth —
  // it survives the field being unmounted (e.g. deselecting then reselecting the
  // "other" chip), so the submitted value always matches what the user sees.
  TextEditingController _controllerFor(String id) =>
      _text.putIfAbsent(id, TextEditingController.new);

  String _otherKey(String id) => '$id::other';

  @override
  void dispose() {
    for (final controller in _text.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _submit() {
    if (_submitting) {
      return;
    }
    final l10n = AppLocalizations.of(context)!;
    final answers = <AiAnswer>[];
    final errors = <String, String?>{};
    for (final question in _questions) {
      final resolved = _resolve(question, l10n);
      if (resolved.error != null) {
        errors[question.id] = resolved.error;
      } else if (resolved.answer != null) {
        answers.add(resolved.answer!);
      }
    }
    if (errors.isNotEmpty) {
      setState(() {
        _errors
          ..clear()
          ..addAll(errors);
      });
      return;
    }
    setState(() => _submitting = true);
    widget.onSubmit(answers);
  }

  ({AiAnswer? answer, String? error}) _resolve(
    AiQuestion question,
    AppLocalizations l10n,
  ) {
    String? required() => question.isRequired ? l10n.aiAssistantAskUserRequired : null;
    switch (question.type) {
      case AiQuestionType.singleSelect:
        final selected = _single[question.id];
        if (selected == null) {
          return (answer: null, error: required());
        }
        if (selected == _kQuestionOther) {
          final text = _controllerFor(_otherKey(question.id)).text.trim();
          if (text.isEmpty) {
            return (answer: null, error: l10n.aiAssistantAskUserRequired);
          }
          return (
            answer: AiAnswer(
              questionId: question.id,
              type: question.type,
              value: text,
              isOther: true,
            ),
            error: null,
          );
        }
        return (
          answer: AiAnswer(
            questionId: question.id,
            type: question.type,
            value: selected,
          ),
          error: null,
        );
      case AiQuestionType.multiSelect:
        final set = _multi[question.id] ?? const <String>{};
        final hasOther = set.contains(_kQuestionOther);
        final otherText = _controllerFor(_otherKey(question.id)).text.trim();
        if (hasOther && otherText.isEmpty) {
          return (answer: null, error: l10n.aiAssistantAskUserRequired);
        }
        final values = set.where((v) => v != _kQuestionOther).toList();
        final count = values.length + (hasOther ? 1 : 0);
        final minSelect = question.minSelect ?? (question.isRequired ? 1 : 0);
        if (count < minSelect) {
          final error = question.maxSelect != null
              ? l10n.aiAssistantAskUserSelectRange(minSelect, question.maxSelect!)
              : l10n.aiAssistantAskUserSelectAtLeast(minSelect);
          return (answer: null, error: count == 0 ? required() ?? error : error);
        }
        if (question.maxSelect != null && count > question.maxSelect!) {
          return (
            answer: null,
            error: l10n.aiAssistantAskUserSelectRange(minSelect, question.maxSelect!),
          );
        }
        return (
          answer: AiAnswer(
            questionId: question.id,
            type: question.type,
            values: values,
            otherText: hasOther ? otherText : null,
            isOther: hasOther,
          ),
          error: null,
        );
      case AiQuestionType.confirm:
        final value = _confirm[question.id];
        if (value == null) {
          return (answer: null, error: required());
        }
        return (
          answer: AiAnswer(questionId: question.id, type: question.type, value: value),
          error: null,
        );
      case AiQuestionType.number:
        final raw = _controllerFor(question.id).text.trim();
        if (raw.isEmpty) {
          return (answer: null, error: required());
        }
        final parsed = num.tryParse(raw);
        if (parsed == null) {
          return (answer: null, error: l10n.aiAssistantAskUserNumberInvalid);
        }
        if (question.min != null && parsed < question.min!) {
          return (
            answer: null,
            error: l10n.aiAssistantAskUserNumberMin('${question.min}'),
          );
        }
        if (question.max != null && parsed > question.max!) {
          return (
            answer: null,
            error: l10n.aiAssistantAskUserNumberMax('${question.max}'),
          );
        }
        // Honour an integer question (decimals: 0) — reject a fractional value.
        if (question.decimals == 0 && parsed != parsed.truncate()) {
          return (answer: null, error: l10n.aiAssistantAskUserNumberInvalid);
        }
        return (
          answer: AiAnswer(questionId: question.id, type: question.type, value: parsed),
          error: null,
        );
      case AiQuestionType.productPicker:
        final choice = _product[question.id];
        if (choice == null) {
          return (answer: null, error: required());
        }
        if (choice.createNew) {
          // "Create a new product" — the AI reads is_other and creates it.
          return (
            answer: AiAnswer(questionId: question.id, type: question.type, isOther: true),
            error: null,
          );
        }
        // Defensive: a picked product must carry its variant id (the PO line key).
        if (choice.variantId == null) {
          return (answer: null, error: required());
        }
        return (
          answer: AiAnswer(
            questionId: question.id,
            type: question.type,
            value: choice.variantId,
            otherText: choice.name,
          ),
          error: null,
        );
      case AiQuestionType.freeText:
      case AiQuestionType.unknown:
        final text = _controllerFor(question.id).text.trim();
        if (text.isEmpty) {
          return (answer: null, error: required());
        }
        return (
          answer: AiAnswer(questionId: question.id, type: question.type, value: text),
          error: null,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);
    final answered = widget.message.submittedAnswers != null;

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 2),
      padding: EdgeInsets.all(spacing.md),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(PointyRadii.card),
        border: Border.all(color: colors.line),
      ),
      child: answered
          ? _AnswerSummary(message: widget.message)
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < _questions.length; i++) ...[
                  if (i > 0) Divider(height: spacing.lg * 1.4, color: colors.line),
                  _buildQuestion(_questions[i]),
                ],
                SizedBox(height: spacing.md),
                _buildActions(),
              ],
            ),
    );
  }

  Widget _buildQuestion(AiQuestion question) {
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);
    final textTheme = Theme.of(context).textTheme;
    final error = _errors[question.id];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          question.prompt,
          style: textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
        ),
        if (question.help != null) ...[
          SizedBox(height: spacing.xs),
          Text(
            question.help!,
            style: textTheme.bodySmall?.copyWith(color: colors.mutedInk),
          ),
        ],
        SizedBox(height: spacing.sm),
        _buildControl(question),
        if (error != null) ...[
          SizedBox(height: spacing.xs),
          Text(
            error,
            style: textTheme.bodySmall?.copyWith(color: colors.danger),
          ),
        ],
      ],
    );
  }

  Widget _buildControl(AiQuestion question) {
    switch (question.type) {
      case AiQuestionType.singleSelect:
        return _buildSingleSelect(question);
      case AiQuestionType.multiSelect:
        return _buildMultiSelect(question);
      case AiQuestionType.confirm:
        return _buildConfirm(question);
      case AiQuestionType.number:
        return _buildNumber(question);
      case AiQuestionType.productPicker:
        return _buildProductPicker(question);
      case AiQuestionType.freeText:
      case AiQuestionType.unknown:
        return _buildText(question);
    }
  }

  Widget _buildSingleSelect(AiQuestion question) {
    final spacing = AdaptiveSpacing.of(context);
    final l10n = AppLocalizations.of(context)!;
    final selected = _single[question.id];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: spacing.xs,
          runSpacing: spacing.xs,
          children: [
            for (final option in question.options)
              ChoiceChip(
                label: Text(option.label),
                selected: selected == option.value,
                onSelected: (_) => setState(() {
                  _single[question.id] = option.value;
                  _errors.remove(question.id);
                }),
              ),
            if (question.allowOther)
              ChoiceChip(
                label: Text(question.otherLabel ?? l10n.aiAssistantAskUserOther),
                selected: selected == _kQuestionOther,
                onSelected: (_) => setState(() {
                  _single[question.id] = _kQuestionOther;
                  _errors.remove(question.id);
                }),
              ),
          ],
        ),
        if (selected == _kQuestionOther) ...[
          SizedBox(height: spacing.sm),
          _buildOtherField(question),
        ],
      ],
    );
  }

  Widget _buildMultiSelect(AiQuestion question) {
    final spacing = AdaptiveSpacing.of(context);
    final l10n = AppLocalizations.of(context)!;
    final set = _multi.putIfAbsent(question.id, () => <String>{});
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: spacing.xs,
          runSpacing: spacing.xs,
          children: [
            for (final option in question.options)
              FilterChip(
                label: Text(option.label),
                selected: set.contains(option.value),
                onSelected: (on) => setState(() {
                  on ? set.add(option.value) : set.remove(option.value);
                  _errors.remove(question.id);
                }),
              ),
            if (question.allowOther)
              FilterChip(
                label: Text(question.otherLabel ?? l10n.aiAssistantAskUserOther),
                selected: set.contains(_kQuestionOther),
                onSelected: (on) => setState(() {
                  on ? set.add(_kQuestionOther) : set.remove(_kQuestionOther);
                  _errors.remove(question.id);
                }),
              ),
          ],
        ),
        if (set.contains(_kQuestionOther)) ...[
          SizedBox(height: spacing.sm),
          _buildOtherField(question),
        ],
      ],
    );
  }

  Widget _buildOtherField(AiQuestion question) {
    final l10n = AppLocalizations.of(context)!;
    return TextField(
      controller: _controllerFor(_otherKey(question.id)),
      decoration: InputDecoration(hintText: l10n.aiAssistantAskUserOtherHint),
      textInputAction: TextInputAction.done,
      onChanged: (_) {
        if (_errors[question.id] != null) {
          setState(() => _errors.remove(question.id));
        }
      },
    );
  }

  Widget _buildText(AiQuestion question) {
    final l10n = AppLocalizations.of(context)!;
    return TextField(
      controller: _controllerFor(question.id),
      minLines: question.multiline ? 3 : 1,
      maxLines: question.multiline ? 6 : 1,
      maxLength: question.maxLength,
      textInputAction:
          question.multiline ? TextInputAction.newline : TextInputAction.done,
      decoration: InputDecoration(
        hintText: question.placeholder ?? l10n.aiAssistantAskUserTextHint,
      ),
      onChanged: (_) {
        if (_errors[question.id] != null) {
          setState(() => _errors.remove(question.id));
        }
      },
    );
  }

  Widget _buildNumber(AiQuestion question) {
    return TextField(
      controller: _controllerFor(question.id),
      keyboardType: TextInputType.numberWithOptions(
        decimal: question.decimals > 0,
        signed: (question.min ?? 0) < 0,
      ),
      inputFormatters: [
        // No decimal point for an integer question (decimals: 0).
        FilteringTextInputFormatter.allow(
          RegExp(question.decimals > 0 ? r'[0-9.\-]' : r'[0-9\-]'),
        ),
      ],
      decoration: InputDecoration(
        hintText: question.placeholder,
        suffixText: question.unit,
      ),
      onChanged: (_) {
        if (_errors[question.id] != null) {
          setState(() => _errors.remove(question.id));
        }
      },
    );
  }

  Widget _buildConfirm(AiQuestion question) {
    final spacing = AdaptiveSpacing.of(context);
    final l10n = AppLocalizations.of(context)!;
    final value = _confirm[question.id];
    return Wrap(
      spacing: spacing.xs,
      children: [
        ChoiceChip(
          label: Text(question.confirmLabel ?? l10n.aiAssistantAskUserConfirmYes),
          selected: value == true,
          onSelected: (_) => setState(() {
            _confirm[question.id] = true;
            _errors.remove(question.id);
          }),
        ),
        ChoiceChip(
          label: Text(question.denyLabel ?? l10n.aiAssistantAskUserConfirmNo),
          selected: value == false,
          onSelected: (_) => setState(() {
            _confirm[question.id] = false;
            _errors.remove(question.id);
          }),
        ),
      ],
    );
  }

  Widget _buildProductPicker(AiQuestion question) {
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final l10n = AppLocalizations.of(context)!;
    final choice = _product[question.id];
    final canSearch = widget.productSearch != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (choice != null) ...[
          Container(
            padding: EdgeInsets.symmetric(horizontal: spacing.sm, vertical: spacing.xs),
            decoration: BoxDecoration(
              color: colors.primaryContainer,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: colors.primary),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  choice.createNew ? Icons.add_circle_outline : Icons.check_circle,
                  size: 16,
                  color: colors.success,
                ),
                SizedBox(width: spacing.xs),
                Flexible(
                  child: Text(
                    choice.createNew
                        ? l10n.aiAssistantProductPickerCreateNewChosen
                        : (choice.name ?? ''),
                    style: textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(height: spacing.sm),
        ],
        Wrap(
          spacing: spacing.xs,
          runSpacing: spacing.xs,
          children: [
            if (canSearch)
              OutlinedButton.icon(
                key: ValueKey('ai_product_pick_${question.id}'),
                onPressed: () => _openProductPicker(question),
                icon: const Icon(Icons.search, size: 18),
                label: Text(l10n.aiAssistantProductPickerChoose),
              ),
            // Always offer "create new" when search isn't available, so there's
            // never a dead card with no way to answer.
            if (question.allowCreateNew || !canSearch)
              OutlinedButton.icon(
                key: ValueKey('ai_product_create_${question.id}'),
                onPressed: () => setState(() {
                  _product[question.id] = const _ProductChoice.createNew();
                  _errors.remove(question.id);
                }),
                icon: const Icon(Icons.add, size: 18),
                label: Text(l10n.aiAssistantProductPickerCreateNew),
              ),
          ],
        ),
      ],
    );
  }

  Future<void> _openProductPicker(AiQuestion question) async {
    final search = widget.productSearch;
    if (search == null) {
      return;
    }
    final l10n = AppLocalizations.of(context)!;
    final picked = await showAsyncMultiSelectPicker<int>(
      context: context,
      singleSelection: true,
      initialSearch: question.productName ?? '',
      selected: const [],
      searchFieldKey: const ValueKey('ai_product_picker_search'),
      applyButtonKey: const ValueKey('ai_product_picker_apply'),
      strings: AsyncSelectionPickerStrings<int>(
        title: l10n.aiAssistantProductPickerTitle,
        searchHint: l10n.aiAssistantProductPickerSearchHint,
        emptyText: l10n.aiAssistantProductPickerEmpty,
        clearText: l10n.clearButton,
        clearSearchTooltip: l10n.clearSearchTooltip,
        loadErrorText: l10n.aiAssistantProductPickerLoadError,
        confirmText: l10n.confirmButton,
        fallbackLabelForId: (id) => '#$id',
      ),
      loadPage: search,
    );
    if (!mounted || picked == null || picked.isEmpty) {
      return;
    }
    final option = picked.first;
    setState(() {
      _product[question.id] = _ProductChoice.existing(
        option.id,
        option.displayLabel((id) => '#$id'),
      );
      _errors.remove(question.id);
    });
  }

  Widget _buildActions() {
    final spacing = AdaptiveSpacing.of(context);
    final l10n = AppLocalizations.of(context)!;
    return Row(
      children: [
        FilledButton(
          onPressed: _submitting ? null : _submit,
          child: Text(l10n.aiAssistantAskUserSubmit),
        ),
        SizedBox(width: spacing.xs),
        TextButton(
          onPressed: _submitting ? null : widget.onSkip,
          child: Text(l10n.aiAssistantAskUserSkip),
        ),
      ],
    );
  }
}

/// The read-only recap shown on a question card after the user answers.
class _AnswerSummary extends StatelessWidget {
  const _AnswerSummary({required this.message});

  final AiMessage message;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);
    final l10n = AppLocalizations.of(context)!;
    final textTheme = Theme.of(context).textTheme;
    final questions = message.pendingQuestion?.questions ?? const [];
    final answers = {
      for (final a in message.submittedAnswers ?? const <AiAnswer>[]) a.questionId: a,
    };
    final skipped = (message.submittedAnswers ?? const []).isEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.check_circle_outline, size: 16, color: colors.success),
            SizedBox(width: spacing.xs),
            Text(
              skipped
                  ? l10n.aiAssistantAskUserSkipped
                  : l10n.aiAssistantAskUserAnswered,
              style: textTheme.bodySmall?.copyWith(
                color: colors.mutedInk,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        if (!skipped)
          for (final question in questions)
            if (answers[question.id] != null) ...[
              SizedBox(height: spacing.sm),
              Text(
                question.prompt,
                style: textTheme.bodySmall?.copyWith(color: colors.mutedInk),
              ),
              SizedBox(height: 2),
              Text(
                _displayAnswer(question, answers[question.id]!, l10n),
                style: textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
            ],
      ],
    );
  }

  String _displayAnswer(AiQuestion question, AiAnswer answer, AppLocalizations l10n) {
    String labelFor(String value) {
      for (final option in question.options) {
        if (option.value == value) {
          return option.label;
        }
      }
      return value;
    }

    switch (question.type) {
      case AiQuestionType.singleSelect:
        return answer.isOther ? '${answer.value}' : labelFor('${answer.value}');
      case AiQuestionType.multiSelect:
        final parts = [
          for (final v in answer.values ?? const []) labelFor(v),
          if (answer.isOther && answer.otherText != null) answer.otherText!,
        ];
        return parts.join('، ');
      case AiQuestionType.confirm:
        return answer.value == true
            ? l10n.aiAssistantAskUserConfirmYes
            : l10n.aiAssistantAskUserConfirmNo;
      case AiQuestionType.number:
        final unit = question.unit;
        return unit != null ? '${answer.value} $unit' : '${answer.value}';
      case AiQuestionType.productPicker:
        return answer.isOther
            ? l10n.aiAssistantProductPickerCreateNewChosen
            : (answer.otherText ?? '${answer.value ?? ''}');
      case AiQuestionType.freeText:
      case AiQuestionType.unknown:
        return '${answer.value ?? ''}';
    }
  }
}

/// A faint row of small icon actions shown under a message (edit/retry/copy).
/// Aligned by the parent: trailing under user turns, leading under assistant.
class _MessageActions extends StatelessWidget {
  const _MessageActions({required this.actions});

  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(mainAxisSize: MainAxisSize.min, children: actions),
    );
  }
}

class _MessageAction extends StatelessWidget {
  const _MessageAction({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    return IconButton(
      icon: Icon(icon),
      iconSize: 18,
      tooltip: tooltip,
      onPressed: onTap,
      color: colors.mutedInk,
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.all(7),
      constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
    );
  }
}

/// Transient chips for the tools the assistant runs while answering — a spinner
/// while active, a check (or error) once done.
class _ToolRunChips extends StatelessWidget {
  const _ToolRunChips({required this.runs});

  final List<AiToolRun> runs;

  @override
  Widget build(BuildContext context) {
    final spacing = AdaptiveSpacing.of(context);
    return Wrap(
      spacing: spacing.xs,
      runSpacing: spacing.xs,
      children: [for (final run in runs) _ToolRunChip(run: run)],
    );
  }
}

class _ToolRunChip extends StatelessWidget {
  const _ToolRunChip({required this.run});

  final AiToolRun run;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);
    final l10n = AppLocalizations.of(context)!;
    final label = (run.label != null && run.label!.isNotEmpty)
        ? run.label!
        : (run.resource ?? l10n.aiAssistantToolWorking);
    final failed = run.done && run.ok == false;
    final mutating = run.mutates;

    // A create/edit "action" chip is accented and kept as a durable record of
    // what the assistant changed; a read "query" chip stays muted. The action
    // label is already self-describing ("إنشاء: المصروفات"), so it's shown as-is
    // rather than wrapped in the "querying…" phrasing.
    final text = mutating ? label : l10n.aiAssistantToolQuerying(label);

    return Container(
      padding: EdgeInsets.symmetric(horizontal: spacing.sm, vertical: spacing.xs),
      decoration: BoxDecoration(
        color: mutating ? colors.primaryContainer : colors.surfaceSunken,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: mutating ? colors.primary : colors.line),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!run.done)
            SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(colors.primary),
              ),
            )
          else
            Icon(
              failed
                  ? Icons.error_outline
                  : (mutating ? Icons.check_circle : Icons.check_circle_outline),
              size: 14,
              color: failed ? colors.danger : colors.success,
            ),
          SizedBox(width: spacing.xs),
          Text(
            text,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: mutating ? colors.ink : colors.mutedInk,
              fontWeight: mutating ? FontWeight.w600 : null,
            ),
          ),
        ],
      ),
    );
  }
}

/// Collapsible reasoning. Collapsed by default; tap to reveal the thinking.
class _ThinkingDisclosure extends StatefulWidget {
  const _ThinkingDisclosure({required this.reasoning});

  final String reasoning;

  @override
  State<_ThinkingDisclosure> createState() => _ThinkingDisclosureState();
}

class _ThinkingDisclosureState extends State<_ThinkingDisclosure> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);
    final l10n = AppLocalizations.of(context)!;

    return Container(
      decoration: BoxDecoration(
        color: colors.surfaceSunken,
        borderRadius: BorderRadius.circular(PointyRadii.input),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(PointyRadii.input),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: spacing.md,
                vertical: spacing.sm,
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.psychology_outlined,
                    size: 17,
                    color: colors.mutedInk,
                  ),
                  SizedBox(width: spacing.sm),
                  Text(
                    l10n.aiAssistantThinkingLabel,
                    style: TextStyle(
                      color: colors.mutedInk,
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                  ),
                  const Spacer(),
                  AnimatedRotation(
                    turns: _expanded ? 0.5 : 0,
                    duration: const Duration(milliseconds: 150),
                    child: Icon(
                      Icons.expand_more,
                      size: 18,
                      color: colors.mutedInk,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_expanded)
            Padding(
              padding: EdgeInsets.fromLTRB(
                spacing.md,
                0,
                spacing.md,
                spacing.sm,
              ),
              child: SelectableText(
                widget.reasoning,
                style: TextStyle(
                  color: colors.mutedInk,
                  height: 1.5,
                  fontSize: 13,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _AssistantMark extends StatelessWidget {
  const _AssistantMark({this.size = 32, this.iconSize = 17});

  final double size;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [colors.primary, colors.primaryStrong],
        ),
      ),
      child: Icon(Icons.auto_awesome, size: iconSize, color: Colors.white),
    );
  }
}

class _TypingIndicator extends StatefulWidget {
  const _TypingIndicator();

  @override
  State<_TypingIndicator> createState() => _TypingIndicatorState();
}

class _TypingIndicatorState extends State<_TypingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final l10n = AppLocalizations.of(context)!;
    return Semantics(
      label: l10n.aiAssistantThinking,
      child: SizedBox(
        height: 16,
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            return Row(
              mainAxisSize: MainAxisSize.min,
              children: List.generate(3, (i) {
                final t = (_controller.value + i * 0.18) % 1.0;
                final wave = 1 - (2 * t - 1).abs();
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2.5),
                  child: Opacity(
                    opacity: 0.4 + 0.6 * wave,
                    child: Transform.translate(
                      offset: Offset(0, -3 * wave),
                      child: Container(
                        width: 7,
                        height: 7,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: colors.mutedInk,
                        ),
                      ),
                    ),
                  ),
                );
              }),
            );
          },
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onSuggestion});

  final ValueChanged<String> onSuggestion;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);
    final l10n = AppLocalizations.of(context)!;
    final textTheme = Theme.of(context).textTheme;
    final suggestions = [
      l10n.aiAssistantSuggestion1,
      l10n.aiAssistantSuggestion2,
      l10n.aiAssistantSuggestion3,
    ];

    return Center(
      child: SingleChildScrollView(
        padding: spacing.pagePadding,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 78,
              height: 78,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [colors.primary, colors.primaryStrong],
                ),
                boxShadow: PointyShadows.raised,
              ),
              child: const Icon(
                Icons.auto_awesome,
                size: 36,
                color: Colors.white,
              ),
            ),
            SizedBox(height: spacing.lg),
            Text(
              l10n.aiAssistantEmptyTitle,
              textAlign: TextAlign.center,
              style: textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            SizedBox(height: spacing.xs),
            Text(
              l10n.aiAssistantEmptySubtitle,
              textAlign: TextAlign.center,
              style: textTheme.bodyMedium?.copyWith(color: colors.mutedInk),
            ),
            SizedBox(height: spacing.xl),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Column(
                children: [
                  for (final suggestion in suggestions) ...[
                    _SuggestionChip(
                      label: suggestion,
                      onTap: () => onSuggestion(suggestion),
                    ),
                    SizedBox(height: spacing.sm),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SuggestionChip extends StatelessWidget {
  const _SuggestionChip({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);
    return Material(
      color: colors.surface,
      borderRadius: BorderRadius.circular(PointyRadii.input),
      child: InkWell(
        borderRadius: BorderRadius.circular(PointyRadii.input),
        onTap: onTap,
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(PointyRadii.input),
            border: Border.all(color: colors.line),
          ),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: spacing.md,
              vertical: spacing.sm + 2,
            ),
            child: Row(
              children: [
                Icon(
                  Icons.auto_awesome_outlined,
                  size: 17,
                  color: colors.primaryStrong,
                ),
                SizedBox(width: spacing.sm),
                Expanded(
                  child: Text(
                    label,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
                Icon(Icons.arrow_outward, size: 15, color: colors.mutedInk),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The composer: a single rounded field with a "+" attach button (prefix), an
/// optional thumbnail strip for pending attachments, and — as suffixes inside
/// the field — a circular usage ring and the send button (Codex/Claude style).
class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.focusNode,
    required this.viewModel,
    required this.onSend,
    required this.onAttach,
    required this.onUsage,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final AiChatViewModel viewModel;
  final VoidCallback onSend;
  final VoidCallback onAttach;
  final VoidCallback onUsage;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);
    final l10n = AppLocalizations.of(context)!;
    final usage = viewModel.usage;
    final showRing = usage != null && usage.hasAnyLimit;
    // While the assistant is waiting on an answer, the composer is locked so the
    // user resolves the question (or skips it) rather than typing past it.
    final locked = viewModel.isStreaming || viewModel.hasPendingQuestion;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        spacing.lg,
        spacing.xs,
        spacing.lg,
        spacing.md,
      ),
      child: SafeArea(
        top: false,
        child: Container(
          decoration: BoxDecoration(
            color: colors.surfaceSunken,
            borderRadius: BorderRadius.circular(26),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (viewModel.hasPendingAttachments)
                _PendingAttachmentStrip(viewModel: viewModel),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  _AttachButton(
                    tooltip: l10n.aiAssistantAttachTooltip,
                    onTap: locked ? null : onAttach,
                  ),
                  Expanded(
                    child: TextField(
                      controller: controller,
                      focusNode: focusNode,
                      enabled: !locked,
                      minLines: 1,
                      maxLines: 6,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => onSend(),
                      decoration: InputDecoration(
                        hintText: viewModel.hasPendingQuestion
                            ? l10n.aiAssistantAskUserPendingComposer
                            : l10n.aiAssistantInputHint,
                        border: InputBorder.none,
                        isCollapsed: true,
                        contentPadding: const EdgeInsets.symmetric(
                          vertical: 13,
                        ),
                      ),
                    ),
                  ),
                  if (showRing)
                    Padding(
                      padding: const EdgeInsetsDirectional.only(bottom: 3),
                      child: _UsageRing(usage: usage, onTap: onUsage),
                    ),
                  const SizedBox(width: 2),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 3),
                    child: _SendButton(
                      controller: controller,
                      viewModel: viewModel,
                      onSend: onSend,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AttachButton extends StatelessWidget {
  const _AttachButton({required this.tooltip, required this.onTap});

  final String tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 1),
      child: IconButton(
        tooltip: tooltip,
        onPressed: onTap,
        visualDensity: VisualDensity.compact,
        icon: const Icon(Icons.add_rounded, size: 24),
        color: colors.mutedInk,
      ),
    );
  }
}

/// A small ring showing how much of the tightest usage window is consumed; taps
/// open the usage sheet. Turns amber as it fills and red once exhausted.
class _UsageRing extends StatelessWidget {
  const _UsageRing({required this.usage, required this.onTap});

  final AiUsage usage;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final l10n = AppLocalizations.of(context)!;
    final window = usage.mostConstrained;
    final exhausted = !window.unlimited && window.remaining <= 0;
    final color = exhausted
        ? colors.danger
        : (window.fraction >= 0.8 ? colors.warning : colors.primary);

    return Tooltip(
      message: l10n.aiAssistantUsageRemaining(window.remaining),
      child: InkResponse(
        onTap: onTap,
        radius: 22,
        child: SizedBox(
          width: 38,
          height: 38,
          child: Center(
            child: SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(
                value: window.unlimited
                    ? 0
                    : window.fraction.clamp(0.04, 1.0).toDouble(),
                strokeWidth: 3,
                backgroundColor: colors.line,
                valueColor: AlwaysStoppedAnimation<Color>(color),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SendButton extends StatelessWidget {
  const _SendButton({
    required this.controller,
    required this.viewModel,
    required this.onSend,
  });

  final TextEditingController controller;
  final AiChatViewModel viewModel;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final l10n = AppLocalizations.of(context)!;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        if (viewModel.isStreaming) {
          return const SizedBox(
            width: 38,
            height: 38,
            child: Padding(
              padding: EdgeInsets.all(10),
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          );
        }
        final canSend =
            !viewModel.hasPendingQuestion &&
            (controller.text.trim().isNotEmpty ||
                viewModel.hasPendingAttachments);
        return Tooltip(
          message: l10n.aiAssistantSendTooltip,
          child: Material(
            color: canSend ? colors.primary : colors.line,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: canSend ? onSend : null,
              child: SizedBox(
                width: 38,
                height: 38,
                child: Icon(
                  Icons.arrow_upward_rounded,
                  size: 20,
                  color: canSend ? Colors.white : colors.mutedInk,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Pending attachments shown as a horizontal strip inside the composer, each
/// with a remove badge.
class _PendingAttachmentStrip extends StatelessWidget {
  const _PendingAttachmentStrip({required this.viewModel});

  final AiChatViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final spacing = AdaptiveSpacing.of(context);
    final attachments = viewModel.pendingAttachments;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        spacing.sm,
        spacing.xs,
        spacing.sm,
        spacing.xs,
      ),
      child: SizedBox(
        height: 66,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: attachments.length,
          separatorBuilder: (_, _) => SizedBox(width: spacing.xs),
          itemBuilder: (context, index) {
            final attachment = attachments[index];
            return _PendingAttachmentTile(
              attachment: attachment,
              onRemove: () => viewModel.removeAttachment(attachment),
            );
          },
        ),
      ),
    );
  }
}

class _PendingAttachmentTile extends StatelessWidget {
  const _PendingAttachmentTile({
    required this.attachment,
    required this.onRemove,
  });

  final AiAttachment attachment;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final l10n = AppLocalizations.of(context)!;
    final isImage = attachment.isImage && attachment.previewBytes != null;

    return Stack(
      children: [
        Container(
          width: isImage ? 66 : 152,
          height: 66,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: colors.line),
            image: isImage
                ? DecorationImage(
                    image: MemoryImage(attachment.previewBytes!),
                    fit: BoxFit.cover,
                  )
                : null,
          ),
          child: isImage
              ? null
              : Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Row(
                    children: [
                      Icon(
                        Icons.description_outlined,
                        size: 20,
                        color: colors.primaryStrong,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          attachment.name.isEmpty
                              ? l10n.aiAssistantAttachFile
                              : attachment.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                ),
        ),
        PositionedDirectional(
          top: 3,
          end: 3,
          child: Tooltip(
            message: l10n.aiAssistantRemoveAttachment,
            child: Material(
              color: Colors.black.withValues(alpha: 0.55),
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: onRemove,
                child: const SizedBox(
                  width: 20,
                  height: 20,
                  child: Icon(Icons.close, size: 13, color: Colors.white),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Attachments on a sent user turn: images as rounded thumbnails, everything
/// else as a labeled chip. From history (no bytes) images fall back to a chip.
class _SentAttachments extends StatelessWidget {
  const _SentAttachments({required this.attachments});

  final List<AiAttachment> attachments;

  @override
  Widget build(BuildContext context) {
    final spacing = AdaptiveSpacing.of(context);
    return Wrap(
      alignment: WrapAlignment.start,
      spacing: spacing.xs,
      runSpacing: spacing.xs,
      children: [
        for (final attachment in attachments)
          if (attachment.isImage && attachment.previewBytes != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: Image.memory(
                attachment.previewBytes!,
                width: 140,
                height: 140,
                fit: BoxFit.cover,
              ),
            )
          else
            _FileChip(attachment: attachment),
      ],
    );
  }
}

class _FileChip extends StatelessWidget {
  const _FileChip({required this.attachment});

  final AiAttachment attachment;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);
    final l10n = AppLocalizations.of(context)!;
    final label = attachment.name.isNotEmpty
        ? attachment.name
        : (attachment.isImage
              ? l10n.aiAssistantAttachmentImage
              : l10n.aiAssistantAttachFile);

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: spacing.sm,
        vertical: spacing.xs + 2,
      ),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.line),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            attachment.isImage
                ? Icons.image_outlined
                : Icons.description_outlined,
            size: 16,
            color: colors.primaryStrong,
          ),
          SizedBox(width: spacing.xs),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 170),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

enum _AttachChoice { gallery, camera, file }

class _AttachSheet extends StatelessWidget {
  const _AttachSheet({required this.canAddImage});

  final bool canAddImage;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: Text(l10n.aiAssistantAttachImage),
            enabled: canAddImage,
            onTap: () => Navigator.of(context).pop(_AttachChoice.gallery),
          ),
          ListTile(
            leading: const Icon(Icons.photo_camera_outlined),
            title: Text(l10n.aiAssistantAttachCamera),
            enabled: canAddImage,
            onTap: () => Navigator.of(context).pop(_AttachChoice.camera),
          ),
          ListTile(
            leading: const Icon(Icons.attach_file),
            title: Text(l10n.aiAssistantAttachFile),
            onTap: () => Navigator.of(context).pop(_AttachChoice.file),
          ),
          SizedBox(height: spacing.sm),
        ],
      ),
    );
  }
}

/// Bottom sheet detailing both usage windows with progress bars and, when a
/// window is exhausted, when it resets.
class _UsageSheet extends StatelessWidget {
  const _UsageSheet({required this.usage});

  final AiUsage? usage;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final snapshot = usage;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          spacing.lg,
          0,
          spacing.lg,
          spacing.lg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.aiAssistantUsageTitle,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            SizedBox(height: spacing.md),
            if (snapshot != null) ...[
              _UsageWindowRow(
                label: l10n.aiAssistantUsageFiveHour,
                window: snapshot.fiveHour,
              ),
              SizedBox(height: spacing.md),
              _UsageWindowRow(
                label: l10n.aiAssistantUsageWeekly,
                window: snapshot.weekly,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _UsageWindowRow extends StatelessWidget {
  const _UsageWindowRow({required this.label, required this.window});

  final String label;
  final AiUsageWindow window;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);
    final l10n = AppLocalizations.of(context)!;
    final textTheme = Theme.of(context).textTheme;
    final unlimited = window.unlimited;
    final exhausted = !unlimited && window.remaining <= 0;
    final color = exhausted
        ? colors.danger
        : (window.fraction >= 0.8 ? colors.warning : colors.primary);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Text(
              unlimited
                  ? l10n.aiAssistantUsageUnlimited
                  : l10n.aiAssistantUsageUsedOfLimit(window.used, window.limit),
              style: textTheme.bodySmall?.copyWith(color: colors.mutedInk),
            ),
          ],
        ),
        SizedBox(height: spacing.xs),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: unlimited ? 0 : window.fraction.clamp(0.0, 1.0).toDouble(),
            minHeight: 7,
            backgroundColor: colors.line,
            valueColor: AlwaysStoppedAnimation<Color>(color),
          ),
        ),
        if (exhausted && window.resetAt != null) ...[
          SizedBox(height: spacing.xs),
          Text(
            l10n.aiAssistantUsageResets(formatDateTime(window.resetAt!)),
            style: textTheme.bodySmall?.copyWith(color: colors.mutedInk),
          ),
        ],
      ],
    );
  }
}

class _HistorySheet extends StatelessWidget {
  const _HistorySheet({required this.viewModel, required this.onSelect});

  final AiChatViewModel viewModel;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;

    return SafeArea(
      child: ListenableBuilder(
        listenable: viewModel,
        builder: (context, _) {
          final conversations = viewModel.conversations;
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
                child: Text(
                  l10n.aiAssistantHistoryTitle,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              if (viewModel.isLoadingHistory)
                Padding(
                  padding: spacing.pagePadding,
                  child: const Center(child: CircularProgressIndicator()),
                )
              else if (conversations.isEmpty)
                Padding(
                  padding: spacing.pagePadding,
                  child: Text(
                    l10n.aiAssistantHistoryEmpty,
                    style: TextStyle(color: colors.mutedInk),
                  ),
                )
              else
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    padding: EdgeInsets.only(bottom: spacing.md),
                    itemCount: conversations.length,
                    itemBuilder: (context, index) {
                      final conversation = conversations[index];
                      return ListTile(
                        leading: const Icon(Icons.chat_bubble_outline),
                        title: Text(
                          conversation.title.isEmpty
                              ? l10n.aiAssistantNewChat
                              : conversation.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: IconButton(
                          tooltip: l10n.aiAssistantDeleteConversation,
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () => unawaited(
                            viewModel.deleteConversation(conversation.id),
                          ),
                        ),
                        onTap: () => onSelect(conversation.id),
                      );
                    },
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
