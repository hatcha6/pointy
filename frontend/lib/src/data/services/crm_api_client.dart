import '../models/campaign.dart';
import '../models/conversation.dart';
import 'api_session.dart';

/// REST access to the customer-conversation endpoints (apps.crm):
/// `GET /api/crm/conversations/`, `GET .../{id}/` (with messages), and the
/// `reply` / `mark_read` / `close` actions.
class CrmApiClient {
  const CrmApiClient(this._session);

  final PosApiSession _session;

  Future<List<Conversation>> fetchConversations({String? status}) async {
    final response = await _session.get(
      'crm/conversations/',
      query: {if (status != null && status.isNotEmpty) 'status': status},
    );
    _session.ensureSuccess(
      response,
      'Conversations request failed with status',
    );
    final decoded = _session.decodedBody(response);
    final items = decoded is Map<String, Object?>
        ? (decoded['results'] as List<Object?>? ?? const [])
        : (decoded as List<Object?>? ?? const []);
    return items
        .whereType<Map<String, Object?>>()
        .map(Conversation.fromJson)
        .toList();
  }

  Future<Conversation> fetchConversation(int id) async {
    final response = await _session.get('crm/conversations/$id/');
    _session.ensureSuccess(response, 'Conversation request failed with status');
    return Conversation.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<ConversationMessage> reply(int id, String body) async {
    final response = await _session.post(
      'crm/conversations/$id/reply/',
      body: {'body': body},
    );
    _session.ensureSuccess(response, 'Conversation reply failed with status');
    return ConversationMessage.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<Conversation> markRead(int id) async {
    final response = await _session.post('crm/conversations/$id/mark_read/');
    _session.ensureSuccess(response, 'Mark-read failed with status');
    return Conversation.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<Conversation> close(int id) async {
    final response = await _session.post('crm/conversations/$id/close/');
    _session.ensureSuccess(response, 'Close conversation failed with status');
    return Conversation.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  /// Open (or resume) a conversation with an existing customer, so staff can send
  /// the first message. The backend keys the thread on the customer's phone.
  Future<Conversation> startConversation(int customerId) async {
    final response = await _session.post(
      'crm/conversations/start/',
      body: {'customer': customerId},
    );
    _session.ensureSuccess(response, 'Start conversation failed with status');
    return Conversation.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<List<Campaign>> fetchCampaigns({String? status}) async {
    final response = await _session.get(
      'crm/campaigns/',
      query: {if (status != null && status.isNotEmpty) 'status': status},
    );
    _session.ensureSuccess(response, 'Campaigns request failed with status');
    final decoded = _session.decodedBody(response);
    final items = decoded is Map<String, Object?>
        ? (decoded['results'] as List<Object?>? ?? const [])
        : (decoded as List<Object?>? ?? const []);
    return items
        .whereType<Map<String, Object?>>()
        .map(Campaign.fromJson)
        .toList();
  }

  Future<Campaign> fetchCampaign(int id) async {
    final response = await _session.get('crm/campaigns/$id/');
    _session.ensureSuccess(response, 'Campaign request failed with status');
    return Campaign.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<Campaign> createCampaign(CampaignDraft draft) async {
    final response = await _session.post(
      'crm/campaigns/',
      body: draft.toJson(),
    );
    _session.ensureSuccess(response, 'Campaign create failed with status');
    return Campaign.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<Campaign> updateCampaign(int id, CampaignDraft draft) async {
    final response = await _session.patch(
      'crm/campaigns/$id/',
      body: draft.toJson(),
    );
    _session.ensureSuccess(response, 'Campaign update failed with status');
    return Campaign.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<void> deleteCampaign(int id) async {
    final response = await _session.delete('crm/campaigns/$id/');
    _session.ensureSuccess(response, 'Campaign delete failed with status');
  }

  Future<CampaignPreview> previewCampaign(int id) async {
    final response = await _session.post('crm/campaigns/$id/preview/');
    _session.ensureSuccess(response, 'Campaign preview failed with status');
    return CampaignPreview.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<Campaign> sendCampaign(int id) async {
    final response = await _session.post('crm/campaigns/$id/send/');
    _session.ensureSuccess(response, 'Campaign send failed with status');
    return Campaign.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<Campaign> cancelCampaign(int id) async {
    final response = await _session.post('crm/campaigns/$id/cancel/');
    _session.ensureSuccess(response, 'Campaign cancel failed with status');
    return Campaign.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }
}
