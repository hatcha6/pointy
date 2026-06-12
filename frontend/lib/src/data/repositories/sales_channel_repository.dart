import '../../core/result.dart';
import '../models/sales_channel.dart';
import '../services/pos_api_service.dart';

class SalesChannelRepository {
  SalesChannelRepository(this._service);

  final PosApiService _service;

  Future<Result<List<SalesChannel>>> loadChannels() async {
    return Result.guard(() async {
      final channels = <SalesChannel>[];
      var page = 1;
      var hasMore = true;
      while (hasMore) {
        final result = await _service.fetchSalesChannels(page: page);
        channels.addAll(result.channels);
        hasMore = result.hasMore;
        page += 1;
      }
      return channels;
    });
  }

  Future<Result<SalesChannelKeyGrant>> createChannel(
    SalesChannelDraft draft,
  ) async {
    return Result.guard(() => _service.createSalesChannel(draft));
  }

  Future<Result<SalesChannel>> setChannelActive(
    int channelId, {
    required bool isActive,
  }) async {
    return Result.guard(
      () => _service.updateSalesChannel(channelId, {'is_active': isActive}),
    );
  }

  Future<Result<void>> deleteChannel(int channelId) async {
    return Result.guard(() => _service.deleteSalesChannel(channelId));
  }

  Future<Result<SalesChannelKeyGrant>> rotateChannelKey(int channelId) async {
    return Result.guard(() => _service.rotateSalesChannelKey(channelId));
  }
}
