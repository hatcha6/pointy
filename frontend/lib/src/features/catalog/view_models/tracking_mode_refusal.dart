import '../../../data/models/tracking_mode.dart';
import '../../../data/services/api_session.dart';

/// The machine half of the one tracking refusal a confirmation can answer.
const trackingIdentifyLaterCode =
    'tracking_mode_change_requires_identification';

/// The server asking whether stock already on the shelf may be identified
/// later, when tracking is turned on over it.
///
/// Not a failure: the save is waiting for the user. Serial stock would become
/// placeholders the till refuses until each is scanned, lot stock one lot with
/// no number — so the question is the user's to answer, never the client's.
class TrackingIdentificationRequest {
  const TrackingIdentificationRequest({
    required this.onHand,
    required this.requestedMode,
  });

  /// How much is on the shelf, as the server counted it — "30", "2.5".
  final String onHand;

  /// The mode the save was turning on.
  final TrackingMode requestedMode;
}

/// The server's question, when [error] is the identify-later refusal.
TrackingIdentificationRequest? trackingIdentificationFrom(Object error) {
  final body = _refusalBody(error);
  if (body == null || _firstLeaf(body['code']) != trackingIdentifyLaterCode) {
    return null;
  }
  return TrackingIdentificationRequest(
    onHand: _firstLeaf(body['on_hand']) ?? '',
    requestedMode: TrackingMode.fromWire(_firstLeaf(body['requested_mode'])),
  );
}

/// The server's sentence refusing a tracking-mode change, when [error] is one.
///
/// The guard answers on the field itself — `{"tracking_mode": ["…"]}` — so the
/// form can put the reason beside the choice that caused it rather than under
/// the whole sheet.
String? trackingModeErrorFrom(Object error) {
  final body = _refusalBody(error);
  if (body == null) {
    return null;
  }
  final trimmed = _firstLeaf(body['tracking_mode'])?.trim() ?? '';
  return trimmed.isEmpty ? null : trimmed;
}

Map<Object?, Object?>? _refusalBody(Object error) {
  if (error is! PosApiException || error.statusCode != 400) {
    return null;
  }
  final body = error.decodedBody;
  return body is Map ? body : null;
}

/// DRF wraps every leaf of a serializer-level error in a list, the code
/// included; a hand-written view may not. Either reads the same here.
String? _firstLeaf(Object? value) => switch (value) {
  final String text => text,
  final List<Object?> items when items.isNotEmpty => items.first?.toString(),
  _ => null,
};
