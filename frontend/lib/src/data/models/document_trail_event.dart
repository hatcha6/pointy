/// One thing that happened to a document.
///
/// The shop's own record, not telemetry: every retraction, correction and
/// issue, with the words the person typed as their reason. The server sends
/// codes and raw values; the wording is the app's, because the app is the part
/// that speaks Arabic.
enum DocumentTrailAction {
  created,
  submitted,
  edited,
  corrected,
  cancelled,
  amended,
  superseded,
  unknown,
}

DocumentTrailAction documentTrailActionFromJson(Object? value) {
  return switch (value?.toString()) {
    'created' => DocumentTrailAction.created,
    'submitted' => DocumentTrailAction.submitted,
    'edited' => DocumentTrailAction.edited,
    'corrected' => DocumentTrailAction.corrected,
    'cancelled' => DocumentTrailAction.cancelled,
    'amended' => DocumentTrailAction.amended,
    'superseded' => DocumentTrailAction.superseded,
    _ => DocumentTrailAction.unknown,
  };
}

/// One field a correction moved, and where it moved it from and to.
class DocumentFieldChange {
  const DocumentFieldChange({
    required this.field,
    required this.from,
    required this.to,
  });

  final String field;
  final String from;
  final String to;
}

class DocumentTrailEvent {
  const DocumentTrailEvent({
    required this.id,
    required this.documentType,
    required this.objectId,
    required this.documentNumber,
    required this.action,
    required this.reason,
    required this.changes,
    this.actorUsername,
    this.createdAt,
  });

  final int id;
  final String documentType;
  final int objectId;
  final String documentNumber;
  final DocumentTrailAction action;

  /// Why, in the words of whoever did it. Often empty — a reason is asked for,
  /// never demanded, because a demanded reason is a field people fill with a
  /// full stop.
  final String reason;
  final List<DocumentFieldChange> changes;
  final String? actorUsername;
  final DateTime? createdAt;

  factory DocumentTrailEvent.fromJson(Map<String, Object?> json) {
    return DocumentTrailEvent(
      id: (json['id'] as num?)?.toInt() ?? 0,
      documentType: json['document_type']?.toString() ?? '',
      objectId: (json['object_id'] as num?)?.toInt() ?? 0,
      documentNumber: json['document_number']?.toString() ?? '',
      action: documentTrailActionFromJson(json['action']),
      reason: json['reason']?.toString() ?? '',
      changes: _changesFromDetails(json['details']),
      actorUsername: json['actor_username']?.toString(),
      createdAt: DateTime.tryParse(json['created_at']?.toString() ?? '')
          ?.toLocal(),
    );
  }
}

List<DocumentFieldChange> _changesFromDetails(Object? details) {
  if (details is! Map) {
    return const [];
  }
  final changes = details['changes'];
  if (changes is! Map) {
    return const [];
  }
  final rows = <DocumentFieldChange>[];
  for (final entry in changes.entries) {
    final value = entry.value;
    if (value is! Map) {
      continue;
    }
    rows.add(
      DocumentFieldChange(
        field: entry.key.toString(),
        from: value['from']?.toString() ?? '',
        to: value['to']?.toString() ?? '',
      ),
    );
  }
  rows.sort((a, b) => a.field.compareTo(b.field));
  return rows;
}

List<DocumentTrailEvent> documentTrailEventsFromResponse(Object? body) {
  final rows = switch (body) {
    Map<String, Object?>() => body['results'],
    List<Object?>() => body,
    _ => const <Object?>[],
  };
  if (rows is! List) {
    return const [];
  }
  return [
    for (final row in rows)
      if (row is Map<String, Object?>) DocumentTrailEvent.fromJson(row),
  ];
}
