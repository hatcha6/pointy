import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/unit_attribute.dart';
import '../../../data/models/unit_checklist_kind.dart';
import '../../../data/repositories/tracked_stock_repository.dart';
import '../../../data/services/api_session.dart';

/// How a save of one checklist field went.
///
/// A refusal names the editor's fields where the server did (`label`,
/// `data_type`, `choices`, `suffix`), so the message sits under the control
/// it is about; anything else is one sentence — the server's Arabic one when
/// it wrote one, or [error] for the screen to word.
class UnitChecklistSaveOutcome {
  const UnitChecklistSaveOutcome.saved(UnitAttributeDefinition this.definition)
    : fieldErrors = const {},
      message = '',
      error = null;

  const UnitChecklistSaveOutcome.refused({
    this.fieldErrors = const {},
    this.message = '',
    this.error,
  }) : definition = null;

  final UnitAttributeDefinition? definition;
  final Map<String, String> fieldErrors;
  final String message;
  final Object? error;

  bool get isSaved => definition != null;
}

/// The fields of the form a refusal can point at.
const unitChecklistFormFields = {'label', 'data_type', 'choices', 'suffix'};

/// [error] as the editor shows it: per field where the server named one of
/// [unitChecklistFormFields], else its first Arabic sentence.
UnitChecklistSaveOutcome unitChecklistRefusalOf(Object error) {
  final body = error is PosApiException ? error.decodedBody : null;
  final fieldErrors = <String, String>{};
  var message = '';
  if (body is Map<String, Object?>) {
    for (final entry in body.entries) {
      final text = _firstMessage(entry.value);
      if (text.isEmpty) continue;
      if (unitChecklistFormFields.contains(entry.key)) {
        fieldErrors[entry.key] = text;
      } else if (message.isEmpty && _arabicLetter.hasMatch(text)) {
        // Never English on an Arabic screen: the screen words it instead.
        message = text;
      }
    }
  }
  return UnitChecklistSaveOutcome.refused(
    fieldErrors: fieldErrors,
    message: message,
    error: error,
  );
}

final _arabicLetter = RegExp('[\u0600-\u06FF]');

String _firstMessage(Object? value) {
  if (value is String) return value.trim();
  if (value is List && value.isNotEmpty) return _firstMessage(value.first);
  return '';
}

/// One kind's checklist: its fields in order, and the four things an owner
/// does to them — add, edit, delete, move.
///
/// [hasChanges] tells the kinds list to re-count when the owner comes back.
class UnitChecklistViewModel extends ChangeNotifier {
  UnitChecklistViewModel({required this.repository, required this.kind});

  final TrackedStockRepository repository;
  final UnitChecklistKind kind;

  List<UnitAttributeDefinition> _fields = const [];
  bool _isLoading = false;
  bool _hasLoaded = false;
  bool _isReordering = false;
  bool _hasChanges = false;
  Object? _loadError;
  Object? _actionError;
  bool _disposed = false;

  List<UnitAttributeDefinition> get fields => _fields;
  bool get isLoading => _isLoading;
  bool get hasLoaded => _hasLoaded;
  bool get isReordering => _isReordering;
  bool get hasChanges => _hasChanges;
  Object? get loadError => _loadError;

  /// The last delete or move that failed, for a snackbar.
  Object? get actionError => _actionError;

  Future<void> load() async {
    _isLoading = true;
    _loadError = null;
    _notify();
    final result = await repository.loadAttributeDefinitions(kind.assetTypeId);
    switch (result) {
      case Ok<List<UnitAttributeDefinition>>(:final value):
        _fields = value;
        _hasLoaded = true;
      case Error<List<UnitAttributeDefinition>>(:final exception):
        _loadError = exception;
    }
    _isLoading = false;
    _notify();
  }

  /// Adds [draft] (id 0) or saves the edit; the list follows on success.
  Future<UnitChecklistSaveOutcome> save(UnitAttributeDefinition draft) async {
    final result = await repository.saveAttributeDefinition(draft);
    switch (result) {
      case Ok<UnitAttributeDefinition>(:final value):
        final isNew = _fields.every((field) => field.id != value.id);
        _fields = [
          for (final field in _fields) field.id == value.id ? value : field,
          if (isNew) value,
        ];
        _hasChanges = true;
        _notify();
        return UnitChecklistSaveOutcome.saved(value);
      case Error<UnitAttributeDefinition>(:final exception):
        return unitChecklistRefusalOf(exception);
    }
  }

  Future<bool> delete(UnitAttributeDefinition field) async {
    _actionError = null;
    final result = await repository.deleteAttributeDefinition(field.id);
    switch (result) {
      case Ok<void>():
        _fields = [
          for (final other in _fields)
            if (other.id != field.id) other,
        ];
        _hasChanges = true;
        _notify();
        return true;
      case Error<void>(:final exception):
        _actionError = exception;
        _notify();
        return false;
    }
  }

  /// Moves the field at [from] to [to] — the final slot, net of the removal,
  /// as `ReorderableListView.onReorderItem` reports it. Shown at once and
  /// undone if the server refuses.
  Future<bool> move(int from, int to) async {
    if (_isReordering ||
        from == to ||
        from < 0 ||
        to < 0 ||
        from >= _fields.length ||
        to >= _fields.length) {
      return false;
    }
    final before = _fields;
    final moved = [..._fields];
    moved.insert(to, moved.removeAt(from));
    _fields = moved;
    _isReordering = true;
    _actionError = null;
    _notify();
    final result = await repository.reorderAttributeDefinitions(
      kind.assetTypeId,
      [for (final field in moved) field.id],
    );
    _isReordering = false;
    switch (result) {
      case Ok<List<UnitAttributeDefinition>>(:final value):
        if (value.isNotEmpty) _fields = value;
        _hasChanges = true;
        _notify();
        return true;
      case Error<List<UnitAttributeDefinition>>(:final exception):
        _fields = before;
        _actionError = exception;
        _notify();
        return false;
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
