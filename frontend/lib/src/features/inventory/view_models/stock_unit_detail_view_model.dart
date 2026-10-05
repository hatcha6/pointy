import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/consignment.dart';
import '../../../data/models/stock_unit.dart';
import '../../../data/models/unit_attribute.dart';
import '../../../data/models/unit_photo.dart';
import '../../../data/repositories/tracked_stock_repository.dart';
import '../../../data/services/api_error_detail.dart';
import '../../../data/services/api_session.dart';
import '../../../shared/tracking/unit_details_sheet.dart';

/// One article's page: what it is, what it looks like, what has happened to
/// it, and the three things a person may change about it without moving it —
/// its facts, its photos and its own warranty date.
///
/// The unit is re-read after every write rather than patched locally: its
/// cover, its stamped warranty and its history are decided by the server, and
/// a page that guessed would occasionally guess wrong.
class StockUnitDetailViewModel extends ChangeNotifier {
  StockUnitDetailViewModel({
    required TrackedStockRepository repository,
    required StockUnit unit,
    this.onUnitChanged,
  }) : _repository = repository,
       _unit = unit;

  final TrackedStockRepository _repository;

  /// Tells the list behind this page that its row changed.
  final ValueChanged<StockUnit>? onUnitChanged;

  StockUnit _unit;
  List<StockAllocationEntry> _history = const [];
  List<StockUnitTimelineEntry> _timeline = const [];
  List<ConsignmentIncident> _incidents = const [];
  List<UnitPhoto> _photos = const [];
  List<UnitAttributeDefinition> _definitions = const [];
  bool _isLoading = true;
  bool _photosFailed = false;
  bool _definitionsLoaded = false;
  int _uploadTotal = 0;
  int _uploadDone = 0;
  double _uploadFraction = 0;
  bool _disposed = false;

  StockUnit get unit => _unit;
  List<StockAllocationEntry> get history => _history;
  List<StockUnitTimelineEntry> get timeline => _timeline;
  List<ConsignmentIncident> get incidents => _incidents;
  List<UnitPhoto> get photos => _photos;
  List<UnitAttributeDefinition> get definitions => _definitions;
  bool get isLoading => _isLoading;
  bool get photosFailed => _photosFailed;
  bool get definitionsLoaded => _definitionsLoaded;

  /// Photos being sent right now: how many, how many are done, and how far
  /// through the current one — drawn as one bar under the strip.
  bool get isUploading => _uploadTotal > 0;
  int get uploadTotal => _uploadTotal;
  int get uploadDone => _uploadDone;
  double get uploadProgress => _uploadTotal == 0
      ? 0
      : ((_uploadDone + _uploadFraction) / _uploadTotal).clamp(0, 1);

  /// The cover, from the photo list once it has loaded and from the unit's own
  /// payload until then, so the hero never waits for the strip.
  UnitPhoto? get cover {
    for (final photo in _photos) {
      if (photo.isCover) return photo;
    }
    return _photos.isEmpty ? _unit.coverPhoto : _photos.first;
  }

  Future<void> load() async {
    final unitFuture = _repository.loadUnit(_unit.id);
    final historyFuture = _repository.loadUnitHistory(_unit.id);
    final timelineFuture = _repository.loadUnitTimeline(_unit.id);
    final photosFuture = _repository.loadUnitPhotos(_unit.id);
    final incidentsFuture = _unit.isConsignment
        ? _repository.loadUnitIncidents(_unit.id)
        : Future.value(Ok(const <ConsignmentIncident>[]));

    if (await unitFuture case Ok<StockUnit>(:final value)) {
      _unit = value;
    }
    if (await historyFuture case Ok<List<StockAllocationEntry>>(:final value)) {
      _history = value;
    }
    // `allocations ∪ events` (§6.9). An older backend answers 404 and the page
    // still renders the movements, which is the half that matters most.
    if (await timelineFuture case Ok<List<StockUnitTimelineEntry>>(
      :final value,
    )) {
      _timeline = value;
    }
    switch (await photosFuture) {
      case Ok<List<UnitPhoto>>(:final value):
        _photos = value;
        _photosFailed = false;
      case Error<List<UnitPhoto>>():
        _photosFailed = true;
    }
    if (await incidentsFuture case Ok<List<ConsignmentIncident>>(
      :final value,
    )) {
      _incidents = value;
    }
    _isLoading = false;
    _notify();
    await _loadDefinitions();
  }

  Future<void> _loadDefinitions() async {
    final assetType = _unit.assetTypeId;
    if (assetType == null) {
      _definitions = const [];
      _definitionsLoaded = true;
      _notify();
      return;
    }
    final result = await _repository.loadAttributeDefinitions(assetType);
    if (result case Ok<List<UnitAttributeDefinition>>(:final value)) {
      _definitions = value;
      _definitionsLoaded = true;
    }
    _notify();
  }

  /// Make the definitions available before a form opens, for a page that was
  /// shown before they arrived. True when they are there.
  Future<bool> ensureDefinitions() async {
    if (!_definitionsLoaded) await _loadDefinitions();
    return _definitionsLoaded;
  }

  // -- writes --------------------------------------------------------------

  Future<UnitDetailsSaveOutcome> saveAttributes(
    Map<String, Object?> attributes,
  ) async {
    final result = await _repository.saveUnitAttributes(_unit.id, attributes);
    return _afterUnitWrite(result, field: 'attributes');
  }

  Future<UnitDetailsSaveOutcome> setWarrantyOverride(DateTime? date) async {
    final result = await _repository.setUnitWarrantyOverride(_unit.id, date);
    return _afterUnitWrite(result, field: 'warranty_override_expires_on');
  }

  Future<UnitDetailsSaveOutcome> _afterUnitWrite(
    Result<StockUnit> result, {
    required String field,
  }) async {
    switch (result) {
      case Ok<StockUnit>(:final value):
        _unit = value;
        onUnitChanged?.call(value);
        await _reloadTimeline();
        _notify();
        return const UnitDetailsSaveOutcome.saved();
      case Error<StockUnit>(:final exception):
        return refusalOf(exception, field: field);
    }
  }

  /// Send [uploads] one after another, each with its own progress, and keep
  /// whatever arrived when one fails. Returns the names that did not.
  Future<List<String>> uploadPhotos(List<UnitPhotoUpload> uploads) async {
    if (uploads.isEmpty) return const [];
    final failed = <String>[];
    _uploadTotal = uploads.length;
    _uploadDone = 0;
    _uploadFraction = 0;
    _notify();
    for (final upload in uploads) {
      final result = await _repository.uploadUnitPhoto(
        _unit.id,
        upload,
        onProgress: (sent, total) {
          _uploadFraction = total <= 0 ? 0 : sent / total;
          _notify();
        },
      );
      switch (result) {
        case Ok<UnitPhoto>(:final value):
          _photos = [
            if (value.isCover)
              for (final photo in _photos) photo.copyWith(isCover: false)
            else
              ..._photos,
            value,
          ]..sort(_coverFirst);
        case Error<UnitPhoto>():
          failed.add(upload.filename);
      }
      _uploadDone += 1;
      _uploadFraction = 0;
      _notify();
    }
    _uploadTotal = 0;
    await _reloadUnitAndTimeline();
    _notify();
    return failed;
  }

  Future<bool> makeCover(UnitPhoto photo) async {
    final result = await _repository.setUnitCoverPhoto(_unit.id, photo.id);
    if (result is! Ok<UnitPhoto>) return false;
    _photos = [
      for (final row in _photos) row.copyWith(isCover: row.id == photo.id),
    ]..sort(_coverFirst);
    await _reloadUnitAndTimeline();
    _notify();
    return true;
  }

  Future<bool> deletePhoto(UnitPhoto photo) async {
    final result = await _repository.deleteUnitPhoto(_unit.id, photo.id);
    if (result is! Ok<void>) return false;
    // The server promotes a new cover when the old one goes; ask it which.
    if (await _repository.loadUnitPhotos(_unit.id) case Ok<List<UnitPhoto>>(
      :final value,
    )) {
      _photos = value;
    } else {
      _photos = [
        for (final row in _photos)
          if (row.id != photo.id) row,
      ];
    }
    await _reloadUnitAndTimeline();
    _notify();
    return true;
  }

  /// The page's own copy after a write made somewhere else on it — the
  /// reprice dialog, the write-off, an incident.
  void replaceUnit(StockUnit unit) {
    _unit = unit;
    onUnitChanged?.call(unit);
    _notify();
    unawaited(_reloadTimeline().then((_) => _notify()));
  }

  Future<void> _reloadUnitAndTimeline() async {
    if (await _repository.loadUnit(_unit.id) case Ok<StockUnit>(:final value)) {
      _unit = value;
      onUnitChanged?.call(value);
    }
    await _reloadTimeline();
  }

  Future<void> _reloadTimeline() async {
    if (await _repository.loadUnitTimeline(_unit.id)
        case Ok<List<StockUnitTimelineEntry>>(:final value)) {
      _timeline = value;
    }
  }

  static int _coverFirst(UnitPhoto a, UnitPhoto b) {
    if (a.isCover != b.isCover) return a.isCover ? -1 : 1;
    final aAt = a.createdAt, bAt = b.createdAt;
    if (aAt == null || bAt == null) return b.id.compareTo(a.id);
    return bAt.compareTo(aAt);
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

/// A refusal as the form shows it: the server's per-key messages under
/// [field] (the attributes map, or the warranty date), and its sentence when
/// it named nothing.
UnitDetailsSaveOutcome refusalOf(Object exception, {required String field}) {
  final body = exception is PosApiException ? exception.decodedBody : null;
  final errors = <String, String>{};
  if (body is Map<String, Object?>) {
    final named = body[field];
    if (named is Map<String, Object?>) {
      for (final entry in named.entries) {
        final text = _firstMessage(entry.value);
        if (text.isNotEmpty) errors[entry.key] = text;
      }
    } else if (named != null) {
      final text = _firstMessage(named);
      if (text.isNotEmpty) errors[field] = text;
    }
  }
  if (errors.isNotEmpty) {
    return UnitDetailsSaveOutcome.refused(fieldErrors: errors);
  }
  return UnitDetailsSaveOutcome.refused(message: apiErrorDetail(exception));
}

String _firstMessage(Object? value) {
  if (value is String) return value.trim();
  if (value is List && value.isNotEmpty) return _firstMessage(value.first);
  return '';
}
