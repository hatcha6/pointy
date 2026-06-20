// Models for the AI assistant: chat messages, conversations, attachments, usage
// limits, and the normalized streaming events the relay emits. The relay
// auto-selects the model from the prompt's difficulty, so clients never pick one.

import 'package:flutter/foundation.dart';

enum AiMessageRole { user, assistant }

enum AiAttachmentKind { image, file }

/// An image or file the user attaches to a prompt. Carried to the relay as a
/// base64 data URI; [previewBytes] is kept locally only to render a thumbnail.
class AiAttachment {
  AiAttachment({
    required this.kind,
    required this.dataUri,
    required this.name,
    required this.mime,
    this.previewBytes,
  });

  final AiAttachmentKind kind;
  final String dataUri;
  final String name;
  final String mime;
  final Uint8List? previewBytes;

  bool get isImage => kind == AiAttachmentKind.image;

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'data_uri': dataUri,
    'name': name,
    'mime': mime,
  };

  /// Rebuilds the lightweight chip representation from persisted history, where
  /// the server returns only metadata (kind/name/mime) — never the bytes.
  factory AiAttachment.fromMetadata(Map<String, Object?> json) {
    return AiAttachment(
      kind: (json['kind'] as String?) == 'image'
          ? AiAttachmentKind.image
          : AiAttachmentKind.file,
      dataUri: '',
      name: (json['name'] as String?) ?? '',
      mime: (json['mime'] as String?) ?? '',
    );
  }
}

/// One usage window (5-hour or weekly) for the rate-limit ring.
class AiUsageWindow {
  const AiUsageWindow({required this.used, required this.limit, this.resetAt});

  final int used;
  final int limit;
  final DateTime? resetAt;

  bool get unlimited => limit <= 0;
  int get remaining => unlimited ? 0 : (limit - used).clamp(0, limit);
  double get fraction =>
      unlimited ? 0 : (used / limit).clamp(0.0, 1.0).toDouble();

  factory AiUsageWindow.fromJson(Map<String, Object?> json) {
    return AiUsageWindow(
      used: (json['used'] as num?)?.toInt() ?? 0,
      limit: (json['limit'] as num?)?.toInt() ?? 0,
      resetAt: DateTime.tryParse((json['reset_at'] as String?) ?? ''),
    );
  }
}

class AiUsage {
  const AiUsage({required this.fiveHour, required this.weekly});

  final AiUsageWindow fiveHour;
  final AiUsageWindow weekly;

  bool get hasAnyLimit => !fiveHour.unlimited || !weekly.unlimited;

  /// The window closest to its limit — drives the ring.
  AiUsageWindow get mostConstrained {
    if (fiveHour.unlimited) return weekly;
    if (weekly.unlimited) return fiveHour;
    return fiveHour.fraction >= weekly.fraction ? fiveHour : weekly;
  }

  factory AiUsage.fromJson(Map<String, Object?> json) {
    Map<String, Object?> window(String key) {
      final value = json[key];
      return value is Map<String, Object?> ? value : const {};
    }

    return AiUsage(
      fiveHour: AiUsageWindow.fromJson(window('five_hour')),
      weekly: AiUsageWindow.fromJson(window('weekly')),
    );
  }
}

/// One tool the assistant ran while answering — shown as a transient status chip
/// ("🔎 يستعلم عن المبيعات…") and ticked once it completes.
class AiToolRun {
  AiToolRun({
    required this.name,
    this.resource,
    this.label,
    this.done = false,
    this.ok,
    this.mutates = false,
  });

  final String name;
  final String? resource;
  final String? label;
  bool done;
  bool? ok;
  // True for a create/edit action (vs a read query) — drives a distinct,
  // persistent "action" chip so the user can see what the assistant changed.
  final bool mutates;
}

/// A single chat turn. Extends [ChangeNotifier] so a streaming reply can notify
/// *only its own bubble* as deltas arrive — the screen listens to the individual
/// message, not the whole conversation, so one growing reply never rebuilds the
/// settled messages above it (which would re-parse all their markdown). Mutations
/// during streaming go through the [appendContent]/[appendReasoning]/tool-run
/// methods so the notification stays scoped to this message.
/// The kind of an interactive question the assistant asks via the ask_user tool.
/// [unknown] is the graceful fallback for a server-introduced type this client
/// doesn't know — it renders as free text so a newer backend never breaks an
/// older app.
enum AiQuestionType { singleSelect, multiSelect, freeText, confirm, number, unknown }

AiQuestionType _aiQuestionTypeFrom(String? raw) {
  switch (raw) {
    case 'single_select':
      return AiQuestionType.singleSelect;
    case 'multi_select':
      return AiQuestionType.multiSelect;
    case 'free_text':
      return AiQuestionType.freeText;
    case 'confirm':
      return AiQuestionType.confirm;
    case 'number':
      return AiQuestionType.number;
    default:
      return AiQuestionType.unknown;
  }
}

/// The wire name for a question type — sent back inside the answer so the model
/// can correlate it with what it asked.
String aiQuestionTypeWire(AiQuestionType type) {
  switch (type) {
    case AiQuestionType.singleSelect:
      return 'single_select';
    case AiQuestionType.multiSelect:
      return 'multi_select';
    case AiQuestionType.freeText:
    case AiQuestionType.unknown:
      return 'free_text';
    case AiQuestionType.confirm:
      return 'confirm';
    case AiQuestionType.number:
      return 'number';
  }
}

/// One selectable option in a single/multi-select question.
class AiQuestionOption {
  const AiQuestionOption({required this.value, required this.label});

  final String value;
  final String label;

  factory AiQuestionOption.fromJson(Map<String, Object?> json) {
    final value = (json['value'] as String?) ?? '';
    return AiQuestionOption(
      value: value,
      label: (json['label'] as String?)?.trim().isNotEmpty == true
          ? json['label'] as String
          : value,
    );
  }
}

/// A single question the assistant asks the user. The per-type knobs live in
/// [config] (an opaque map the backend never interprets) and are read through the
/// typed getters below, so adding a question type is a client-only change.
class AiQuestion {
  const AiQuestion({
    required this.id,
    required this.type,
    required this.prompt,
    this.help,
    this.isRequired = true,
    this.config = const {},
  });

  final String id;
  final AiQuestionType type;
  final String prompt;
  final String? help;
  final bool isRequired;
  final Map<String, Object?> config;

  List<AiQuestionOption> get options {
    final raw = config['options'];
    if (raw is List) {
      return raw
          .whereType<Map<String, Object?>>()
          .map(AiQuestionOption.fromJson)
          .toList(growable: false);
    }
    return const [];
  }

  bool get allowOther => config['allow_other'] == true;
  String? get otherLabel => config['other_label'] as String?;
  int? get minSelect => (config['min_select'] as num?)?.toInt();
  int? get maxSelect => (config['max_select'] as num?)?.toInt();
  String? get placeholder => config['placeholder'] as String?;
  bool get multiline => config['multiline'] == true;
  int? get maxLength => (config['max_length'] as num?)?.toInt();
  num? get min => config['min'] as num?;
  num? get max => config['max'] as num?;
  String? get unit => (config['unit'] as String?)?.trim();
  int get decimals => (config['decimals'] as num?)?.toInt() ?? 0;
  String? get confirmLabel => config['confirm_label'] as String?;
  String? get denyLabel => config['deny_label'] as String?;

  factory AiQuestion.fromJson(Map<String, Object?> json) {
    return AiQuestion(
      id: (json['id'] as String?) ?? '',
      type: _aiQuestionTypeFrom(json['type'] as String?),
      prompt: (json['prompt'] as String?) ?? '',
      help: (json['help'] as String?)?.trim().isNotEmpty == true
          ? json['help'] as String
          : null,
      isRequired: json['required'] != false,
      config: json['config'] is Map<String, Object?>
          ? json['config'] as Map<String, Object?>
          : const {},
    );
  }
}

/// A pending elicitation attached to an assistant turn: one ask_user tool call
/// (identified by [toolCallId] on server message [messageId]) carrying one or
/// more [questions] to answer. Answering resumes the paused agentic turn.
class AiPendingQuestion {
  const AiPendingQuestion({
    required this.toolCallId,
    required this.messageId,
    required this.questions,
  });

  final String toolCallId;
  final int? messageId;
  final List<AiQuestion> questions;

  static AiPendingQuestion? fromParts({
    required String? toolCallId,
    required int? messageId,
    required Object? questionsRaw,
  }) {
    if (toolCallId == null || toolCallId.isEmpty || questionsRaw is! List) {
      return null;
    }
    final questions = questionsRaw
        .whereType<Map<String, Object?>>()
        .map(AiQuestion.fromJson)
        .where((q) => q.prompt.isNotEmpty)
        .toList(growable: false);
    if (questions.isEmpty) {
      return null;
    }
    return AiPendingQuestion(
      toolCallId: toolCallId,
      messageId: messageId,
      questions: questions,
    );
  }
}

/// One answer the user gives to one [AiQuestion]. Exactly one of [value]/[values]
/// is set depending on the question type; [otherText]/[isOther] cover the "other"
/// free-entry option on select questions. Serialized straight to the resume call.
class AiAnswer {
  const AiAnswer({
    required this.questionId,
    required this.type,
    this.value,
    this.values,
    this.otherText,
    this.isOther = false,
  });

  final String questionId;
  final AiQuestionType type;
  final Object? value;
  final List<String>? values;
  final String? otherText;
  final bool isOther;

  Map<String, Object?> toJson() => {
    'question_id': questionId,
    'type': aiQuestionTypeWire(type),
    if (value != null) 'value': value,
    if (values != null) 'values': values,
    if (otherText != null && otherText!.isNotEmpty) 'other_text': otherText,
    'is_other': isOther,
  };
}

class AiMessage extends ChangeNotifier {
  AiMessage({
    required this.role,
    required this.content,
    this.id,
    this.isStreaming = false,
    this.model = '',
    this.reasoning = '',
    this.attachments = const [],
    this.pendingQuestion,
    List<AiToolRun>? toolRuns,
  }) : toolRuns = toolRuns ?? <AiToolRun>[];

  /// Mutable: assigned from the `done` event for a freshly-sent turn so the
  /// view model can later target it for edit/retry rewinds.
  int? id;
  final AiMessageRole role;

  /// Mutable so the view model can append streamed deltas in place.
  String content;

  /// The model's thinking, when it exposes it. Streams before [content] and is
  /// shown in a collapsed-by-default disclosure.
  String reasoning;
  bool isStreaming;
  final String model;

  /// Attachments shown as chips on the user's turn. Carries preview bytes for a
  /// freshly-sent image; from history it holds metadata only.
  final List<AiAttachment> attachments;

  /// Tools the assistant ran while producing this turn (transient status chips).
  final List<AiToolRun> toolRuns;

  /// An interactive question the assistant is asking on this turn (ask_user). The
  /// turn pauses until the user answers; answering resumes the agentic loop.
  AiPendingQuestion? pendingQuestion;

  /// The user's submitted answers, kept in-session so the card can show a
  /// read-only summary after submit (cleared question state isn't re-fetched).
  List<AiAnswer>? submittedAnswers;

  bool get isUser => role == AiMessageRole.user;

  /// Whether this turn still has an unanswered question awaiting input.
  bool get hasPendingQuestion =>
      pendingQuestion != null && submittedAnswers == null;

  /// Append a streamed answer fragment and notify this message's listeners only.
  void appendContent(String delta) {
    if (delta.isEmpty) {
      return;
    }
    content += delta;
    notifyListeners();
  }

  /// Append a streamed thinking fragment and notify this message's listeners.
  void appendReasoning(String delta) {
    if (delta.isEmpty) {
      return;
    }
    reasoning += delta;
    notifyListeners();
  }

  /// Record that a tool started running while producing this turn.
  void startToolRun(AiToolRun run) {
    toolRuns.add(run);
    notifyListeners();
  }

  /// Mark the most recent matching tool run finished (success/failure).
  void finishToolRun({required String name, String? resource, bool? ok}) {
    for (final run in toolRuns.reversed) {
      if (run.name == name && run.resource == resource && !run.done) {
        run.done = true;
        run.ok = ok;
        break;
      }
    }
    notifyListeners();
  }

  /// Flip off the streaming flag and notify (the typing indicator → final text).
  void markStreamingComplete() {
    if (!isStreaming) {
      return;
    }
    isStreaming = false;
    notifyListeners();
  }

  /// The assistant asked the user something — attach the question and stop
  /// streaming so the bubble shows the interactive card instead of a cursor.
  void attachQuestion(AiPendingQuestion question) {
    pendingQuestion = question;
    isStreaming = false;
    notifyListeners();
  }

  /// Record the user's answers locally so the card flips to a read-only summary.
  void resolveQuestion(List<AiAnswer> answers) {
    submittedAnswers = answers;
    notifyListeners();
  }

  factory AiMessage.fromJson(Map<String, Object?> json) {
    final rawAttachments = json['attachments'];
    final attachments = rawAttachments is List
        ? rawAttachments
              .whereType<Map<String, Object?>>()
              .map(AiAttachment.fromMetadata)
              .toList(growable: false)
        : const <AiAttachment>[];
    // A still-open ask_user turn rehydrates its interactive question from history,
    // so a question survives a reload/reconnect and can be answered afterwards.
    final pendingSpec = json['pending_question'];
    final pending = (json['status'] as String?) == 'awaiting_answer'
        ? AiPendingQuestion.fromParts(
            toolCallId: json['tool_call_id'] as String?,
            messageId: (json['id'] as num?)?.toInt(),
            questionsRaw: pendingSpec is Map<String, Object?>
                ? pendingSpec['questions']
                : null,
          )
        : null;
    // Rehydrate only the *mutating* tool runs from the persisted trace, as
    // completed action chips — so a reload still shows what the assistant
    // created/edited. Read queries stay transient (they're decoration, and the
    // durable record of an answer is its text).
    final rawEvents = json['tool_events'];
    final toolRuns = rawEvents is List
        ? rawEvents
              .whereType<Map<String, Object?>>()
              .where((e) => e['mutates'] == true)
              .map(
                (e) => AiToolRun(
                  name: (e['name'] as String?) ?? '',
                  resource: e['resource'] as String?,
                  label: e['label'] as String?,
                  done: true,
                  ok: e['ok'] as bool?,
                  mutates: true,
                ),
              )
              .toList()
        : <AiToolRun>[];
    return AiMessage(
      id: (json['id'] as num?)?.toInt(),
      role: (json['role'] as String?) == 'user'
          ? AiMessageRole.user
          : AiMessageRole.assistant,
      content: (json['content'] as String?) ?? '',
      reasoning: (json['reasoning'] as String?) ?? '',
      model: (json['model'] as String?) ?? '',
      attachments: attachments,
      pendingQuestion: pending,
      toolRuns: toolRuns,
    );
  }
}

class AiConversationSummary {
  const AiConversationSummary({
    required this.id,
    required this.title,
    this.messageCount = 0,
    this.updatedAt,
  });

  final int id;
  final String title;
  final int messageCount;
  final DateTime? updatedAt;

  factory AiConversationSummary.fromJson(Map<String, Object?> json) {
    return AiConversationSummary(
      id: (json['id'] as num?)?.toInt() ?? 0,
      title: (json['title'] as String?) ?? '',
      messageCount: (json['message_count'] as num?)?.toInt() ?? 0,
      updatedAt: DateTime.tryParse((json['updated_at'] as String?) ?? ''),
    );
  }
}

class AiConversation {
  const AiConversation({
    required this.id,
    required this.title,
    required this.messages,
  });

  final int id;
  final String title;
  final List<AiMessage> messages;

  factory AiConversation.fromJson(Map<String, Object?> json) {
    final rawMessages = json['messages'];
    final messages = rawMessages is List
        ? rawMessages
              .whereType<Map<String, Object?>>()
              // Only user + assistant turns are bubbles. tool rows (ask_user
              // answers) and system rows are internal context, not shown.
              .where((m) => m['role'] == 'user' || m['role'] == 'assistant')
              .map(AiMessage.fromJson)
              .toList(growable: false)
        : <AiMessage>[];
    return AiConversation(
      id: (json['id'] as num?)?.toInt() ?? 0,
      title: (json['title'] as String?) ?? '',
      messages: messages,
    );
  }
}

/// Normalized streaming events surfaced to the view model as the reply arrives.
sealed class AiChatEvent {
  const AiChatEvent();
}

class AiChatDelta extends AiChatEvent {
  const AiChatDelta(this.text);

  final String text;
}

/// A chunk of the model's thinking (streams before the answer).
class AiChatReasoning extends AiChatEvent {
  const AiChatReasoning(this.text);

  final String text;
}

/// A status update for a tool the assistant is running between turns. Surfaced
/// as a transient chip; `phase` is "start" or "done".
class AiChatToolActivity extends AiChatEvent {
  const AiChatToolActivity({
    required this.name,
    this.resource,
    this.label,
    required this.phase,
    this.ok,
    this.mutates = false,
  });

  final String name;
  final String? resource;
  final String? label;
  final String phase;
  final bool? ok;
  // The tool changed shop data (create/edit/sale), not just read it.
  final bool mutates;

  bool get isStart => phase == 'start';
}

/// The assistant paused to ask the user something. Carries the question spec and
/// the ids needed to resume the agentic turn once the user answers. Terminal for
/// this stream — no `done` follows; the answer is submitted via the resume call.
class AiChatAskUser extends AiChatEvent {
  const AiChatAskUser({
    required this.conversationId,
    required this.messageId,
    required this.toolCallId,
    required this.questions,
  });

  final int conversationId;
  final int? messageId;
  final String toolCallId;
  final List<AiQuestion> questions;
}

class AiChatDone extends AiChatEvent {
  const AiChatDone({
    required this.conversationId,
    this.messageId,
    this.userMessageId,
    this.model = '',
    this.usage,
  });

  final int conversationId;
  final int? messageId;

  /// Server id of the user turn just sent — lets the client rewind to it later.
  final int? userMessageId;
  final String model;
  final AiUsage? usage;
}

class AiChatError extends AiChatEvent {
  const AiChatError(this.detail, {this.statusCode});

  final String detail;

  /// HTTP status when the failure was a transport error (e.g. 403 = AI not
  /// enabled for this shop). Null for in-band model/stream errors.
  final int? statusCode;
}
