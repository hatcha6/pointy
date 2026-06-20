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
  });

  final String name;
  final String? resource;
  final String? label;
  bool done;
  bool? ok;
}

/// A single chat turn. Extends [ChangeNotifier] so a streaming reply can notify
/// *only its own bubble* as deltas arrive — the screen listens to the individual
/// message, not the whole conversation, so one growing reply never rebuilds the
/// settled messages above it (which would re-parse all their markdown). Mutations
/// during streaming go through the [appendContent]/[appendReasoning]/tool-run
/// methods so the notification stays scoped to this message.
class AiMessage extends ChangeNotifier {
  AiMessage({
    required this.role,
    required this.content,
    this.id,
    this.isStreaming = false,
    this.model = '',
    this.reasoning = '',
    this.attachments = const [],
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

  bool get isUser => role == AiMessageRole.user;

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

  factory AiMessage.fromJson(Map<String, Object?> json) {
    final rawAttachments = json['attachments'];
    final attachments = rawAttachments is List
        ? rawAttachments
              .whereType<Map<String, Object?>>()
              .map(AiAttachment.fromMetadata)
              .toList(growable: false)
        : const <AiAttachment>[];
    return AiMessage(
      id: (json['id'] as num?)?.toInt(),
      role: (json['role'] as String?) == 'user'
          ? AiMessageRole.user
          : AiMessageRole.assistant,
      content: (json['content'] as String?) ?? '',
      reasoning: (json['reasoning'] as String?) ?? '',
      model: (json['model'] as String?) ?? '',
      attachments: attachments,
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
  });

  final String name;
  final String? resource;
  final String? label;
  final String phase;
  final bool? ok;

  bool get isStart => phase == 'start';
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
