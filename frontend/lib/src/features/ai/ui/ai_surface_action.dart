import 'package:flutter/foundation.dart';

/// What a tap on a generated surface asked for.
///
/// The model encodes intent in the action name's prefix, so one vocabulary
/// covers "open this record", "ask me more" and "here are my inputs" without
/// the catalog needing three different button types.
enum AiSurfaceActionKind {
  /// `navigate:` — open a screen or record in the app. No model round trip.
  navigate,

  /// `ask:` — send a follow-up question to the assistant.
  ask,

  /// `submit:` — send the surface's collected inputs back to the assistant.
  submit,

  /// Anything else. Ignored rather than guessed at.
  unknown,
}

@immutable
class AiSurfaceAction {
  const AiSurfaceAction({
    required this.kind,
    required this.name,
    required this.surfaceId,
    this.context = const <String, Object?>{},
    this.data = const <String, Object?>{},
  });

  /// Parses an action name of the form `prefix:verb`.
  factory AiSurfaceAction.parse({
    required String name,
    required String surfaceId,
    Map<String, Object?> context = const <String, Object?>{},
    Map<String, Object?> data = const <String, Object?>{},
  }) {
    final kind = switch (name.split(':').first) {
      'navigate' => AiSurfaceActionKind.navigate,
      'ask' => AiSurfaceActionKind.ask,
      'submit' => AiSurfaceActionKind.submit,
      _ => AiSurfaceActionKind.unknown,
    };
    return AiSurfaceAction(
      kind: kind,
      name: name,
      surfaceId: surfaceId,
      context: context,
      data: data,
    );
  }

  final AiSurfaceActionKind kind;
  final String name;
  final String surfaceId;

  /// Values the model attached to the action, e.g. `link` or `prompt`.
  final Map<String, Object?> context;

  /// The surface's data model at the moment of the tap. Only populated for
  /// [AiSurfaceActionKind.submit], where the inputs are the whole point.
  final Map<String, Object?> data;

  /// The deep link for a navigate action, if the model supplied one.
  String? get link {
    final value = context['link'];
    return value is String && value.isNotEmpty ? value : null;
  }

  /// The follow-up question for an ask action.
  String? get prompt {
    final value = context['prompt'];
    return value is String && value.isNotEmpty ? value : null;
  }
}
