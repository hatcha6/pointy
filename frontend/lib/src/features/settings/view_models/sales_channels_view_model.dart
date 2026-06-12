import 'package:flutter/foundation.dart';

import '../../../core/analytics_audit.dart';
import '../../../core/analytics_engine.dart';
import '../../../core/result.dart';
import '../../../data/models/sales_channel.dart';
import '../../../data/repositories/sales_channel_repository.dart';

class SalesChannelsViewModel extends ChangeNotifier {
  SalesChannelsViewModel(this._repository, {AnalyticsEngine? analyticsEngine})
    : _analyticsEngine = analyticsEngine;

  final SalesChannelRepository _repository;
  final AnalyticsEngine? _analyticsEngine;

  List<SalesChannel> _channels = const [];
  bool _isLoading = false;
  bool _isMutating = false;
  bool _hasLoadError = false;
  bool _hasMutationError = false;

  List<SalesChannel> get channels => _channels;
  bool get isLoading => _isLoading;
  bool get isMutating => _isMutating;
  bool get hasLoadError => _hasLoadError;
  bool get hasMutationError => _hasMutationError;

  Future<void> loadChannels() async {
    _isLoading = true;
    _hasLoadError = false;
    notifyListeners();

    final result = await _repository.loadChannels();
    switch (result) {
      case Ok<List<SalesChannel>>():
        _channels = result.value;
      case Error<List<SalesChannel>>():
        _hasLoadError = true;
    }

    _isLoading = false;
    notifyListeners();
  }

  Future<SalesChannelKeyGrant?> createChannel(SalesChannelDraft draft) async {
    return _mutate(() async {
      final result = await _repository.createChannel(draft);
      switch (result) {
        case Ok<SalesChannelKeyGrant>():
          _trackChannelEvent(
            'settings.sales_channel.created',
            result.value.channel,
          );
          return result.value;
        case Error<SalesChannelKeyGrant>():
          _hasMutationError = true;
          return null;
      }
    });
  }

  Future<bool> setChannelActive(
    SalesChannel channel, {
    required bool isActive,
  }) async {
    final updated = await _mutate(() async {
      final result = await _repository.setChannelActive(
        channel.id,
        isActive: isActive,
      );
      switch (result) {
        case Ok<SalesChannel>():
          _trackChannelEvent(
            isActive
                ? 'settings.sales_channel.authorized'
                : 'settings.sales_channel.deauthorized',
            result.value,
          );
          return result.value;
        case Error<SalesChannel>():
          _hasMutationError = true;
          return null;
      }
    });
    return updated != null;
  }

  Future<bool> deleteChannel(SalesChannel channel) async {
    final deleted = await _mutate(() async {
      final result = await _repository.deleteChannel(channel.id);
      switch (result) {
        case Ok<void>():
          _trackChannelEvent('settings.sales_channel.deleted', channel);
          return true;
        case Error<void>():
          _hasMutationError = true;
          return false;
      }
    });
    return deleted;
  }

  Future<SalesChannelKeyGrant?> rotateChannelKey(SalesChannel channel) async {
    return _mutate(() async {
      final result = await _repository.rotateChannelKey(channel.id);
      switch (result) {
        case Ok<SalesChannelKeyGrant>():
          _trackChannelEvent(
            'settings.sales_channel.key_rotated',
            result.value.channel,
          );
          return result.value;
        case Error<SalesChannelKeyGrant>():
          _hasMutationError = true;
          return null;
      }
    });
  }

  Future<T> _mutate<T>(Future<T> Function() operation) async {
    _isMutating = true;
    _hasMutationError = false;
    notifyListeners();

    final outcome = await operation();
    _isMutating = false;
    notifyListeners();
    await loadChannels();
    return outcome;
  }

  void _trackChannelEvent(String name, SalesChannel channel) {
    trackAuditEvent(
      _analyticsEngine,
      name: name,
      entityType: 'sales_channel',
      entityId: channel.id,
      attributes: {
        'channel_type': channel.type.toJson(),
        'is_system': channel.isSystem,
        'source': 'shop_settings',
      },
    );
  }
}
