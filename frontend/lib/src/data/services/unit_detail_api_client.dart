import '../models/stock_unit.dart';
import '../models/unit_attribute.dart';
import '../models/unit_photo.dart';
import 'api_session.dart';

/// What a person records about one article without moving it: its facts, its
/// photos and its own warranty date. Every write here is on the unit's §6.9
/// history server-side.
class UnitDetailApiClient {
  const UnitDetailApiClient(this._session);

  final PosApiSession _session;

  /// The fields a kind of article records, in the order a form shows them.
  Future<List<UnitAttributeDefinition>> fetchAttributeDefinitions(
    int assetTypeId,
  ) async {
    final response = await _session.get(
      'unit-attribute-definitions/',
      query: {'asset_type': '$assetTypeId', 'page_size': '200'},
    );
    _session.ensureSuccess(
      response,
      'Unit attribute definitions failed with status',
    );
    final decoded = _session.decodedBody(response);
    final rows = decoded is Map<String, Object?> ? decoded['results'] : decoded;
    if (rows is! List<Object?>) {
      return const [];
    }
    return rows
        .whereType<Map<String, Object?>>()
        .map(UnitAttributeDefinition.fromJson)
        .toList(growable: false);
  }

  /// Replace the article's facts. A refusal names its fields — see
  /// `unitAttributeFieldErrors`.
  Future<StockUnit> saveAttributes(
    int unitId,
    Map<String, Object?> attributes,
  ) async {
    final response = await _session.post(
      'stock-units/$unitId/attributes/',
      body: {'attributes': attributes},
    );
    _session.throwApiException(response, 'Unit attributes failed with status');
    return StockUnit.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  /// Give the article its own warranty end date; null returns it to the
  /// product's days from the sale.
  Future<StockUnit> setWarrantyOverride(int unitId, DateTime? expiresOn) async {
    final response = await _session.post(
      'stock-units/$unitId/warranty/',
      body: {
        'warranty_override_expires_on': expiresOn == null
            ? null
            : _isoDate(expiresOn),
      },
    );
    _session.throwApiException(response, 'Unit warranty failed with status');
    return StockUnit.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<List<UnitPhoto>> fetchPhotos(int unitId) async {
    final response = await _session.get('stock-units/$unitId/photos/');
    _session.ensureSuccess(response, 'Unit photos failed with status');
    final decoded = _session.decodedBody(response);
    if (decoded is! List<Object?>) {
      return const [];
    }
    return decoded
        .whereType<Map<String, Object?>>()
        .map(UnitPhoto.fromJson)
        .toList(growable: false);
  }

  Future<UnitPhoto> uploadPhoto(
    int unitId,
    UnitPhotoUpload upload, {
    bool isCover = false,
    void Function(int sent, int total)? onProgress,
  }) async {
    final response = await _session.postMultipart(
      'stock-units/$unitId/photos/',
      fields: {if (isCover) 'is_cover': 'true'},
      files: [
        ApiMultipartFile(
          fieldName: 'file',
          filename: upload.filename,
          bytes: upload.bytes,
          contentType: upload.contentType,
        ),
      ],
      // A phone photo over a relayed connection is not a one-second request.
      timeout: const Duration(minutes: 2),
      onProgress: onProgress,
    );
    _session.throwApiException(
      response,
      'Unit photo upload failed with status',
    );
    return UnitPhoto.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<void> deletePhoto(int unitId, int photoId) async {
    final response = await _session.delete(
      'stock-units/$unitId/photos/$photoId/',
    );
    _session.throwApiException(
      response,
      'Unit photo delete failed with status',
    );
  }

  Future<UnitPhoto> setCoverPhoto(int unitId, int photoId) async {
    final response = await _session.post(
      'stock-units/$unitId/photos/$photoId/cover/',
      body: const <String, Object?>{},
    );
    _session.throwApiException(response, 'Unit cover failed with status');
    return UnitPhoto.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }
}

String _isoDate(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-'
    '${value.month.toString().padLeft(2, '0')}-'
    '${value.day.toString().padLeft(2, '0')}';
