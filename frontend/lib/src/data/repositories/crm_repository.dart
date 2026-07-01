import '../../core/result.dart';
import '../models/campaign.dart';
import '../models/conversation.dart';
import '../services/pos_api_service.dart';

/// Access to customer SMS conversations and their reply/read actions. Every call
/// is wrapped in [Result]. Powers the Conversations inbox screen.
class CrmRepository {
  const CrmRepository(this._service);

  final PosApiService _service;

  Future<Result<List<Conversation>>> loadConversations({String? status}) {
    return Result.guard(() => _service.fetchConversations(status: status));
  }

  Future<Result<Conversation>> loadConversation(int id) {
    return Result.guard(() => _service.fetchConversation(id));
  }

  Future<Result<ConversationMessage>> reply(int id, String body) {
    return Result.guard(() => _service.replyToConversation(id, body));
  }

  Future<Result<Conversation>> markRead(int id) {
    return Result.guard(() => _service.markConversationRead(id));
  }

  Future<Result<Conversation>> startConversation(int customerId) {
    return Result.guard(() => _service.startConversation(customerId));
  }

  Future<Result<List<Campaign>>> loadCampaigns({String? status}) {
    return Result.guard(() => _service.fetchCampaigns(status: status));
  }

  Future<Result<Campaign>> loadCampaign(int id) {
    return Result.guard(() => _service.fetchCampaign(id));
  }

  Future<Result<Campaign>> createCampaign(CampaignDraft draft) {
    return Result.guard(() => _service.createCampaign(draft));
  }

  Future<Result<Campaign>> updateCampaign(int id, CampaignDraft draft) {
    return Result.guard(() => _service.updateCampaign(id, draft));
  }

  Future<Result<void>> deleteCampaign(int id) {
    return Result.guard(() => _service.deleteCampaign(id));
  }

  Future<Result<CampaignPreview>> previewCampaign(int id) {
    return Result.guard(() => _service.previewCampaign(id));
  }

  Future<Result<Campaign>> sendCampaign(int id) {
    return Result.guard(() => _service.sendCampaign(id));
  }

  Future<Result<Campaign>> cancelCampaign(int id) {
    return Result.guard(() => _service.cancelCampaign(id));
  }
}
