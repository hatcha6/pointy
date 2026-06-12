import '../models/sales_channel.dart';
import 'api_session.dart';

class SalesChannelApiClient {
  const SalesChannelApiClient(this._session);

  final PosApiSession _session;

  Future<SalesChannelPage> fetchSalesChannels({int page = 1}) async {
    final response = await _session.get(
      'sales-channels/',
      query: {'page': '$page'},
    );
    _session.ensureSuccess(
      response,
      'Sales channels request failed with status',
    );
    return SalesChannelPage.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<SalesChannelKeyGrant> createSalesChannel(
    SalesChannelDraft draft,
  ) async {
    final response = await _session.post(
      'sales-channels/',
      body: draft.toJson(),
    );
    _session.ensureSuccess(
      response,
      'Sales channel create failed with status',
    );
    return SalesChannelKeyGrant.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<SalesChannel> updateSalesChannel(
    int channelId,
    Map<String, Object?> changes,
  ) async {
    final response = await _session.patch(
      'sales-channels/$channelId/',
      body: changes,
    );
    _session.ensureSuccess(
      response,
      'Sales channel update failed with status',
    );
    return SalesChannel.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<void> deleteSalesChannel(int channelId) async {
    final response = await _session.delete('sales-channels/$channelId/');
    _session.ensureSuccess(
      response,
      'Sales channel delete failed with status',
    );
  }

  Future<SalesChannelKeyGrant> rotateSalesChannelKey(int channelId) async {
    final response = await _session.post(
      'sales-channels/$channelId/rotate-key/',
    );
    _session.ensureSuccess(
      response,
      'Sales channel key rotation failed with status',
    );
    return SalesChannelKeyGrant.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }
}
