import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/campaign.dart';
import '../../../data/repositories/crm_repository.dart';

/// Drives the campaigns list. Mints a [CampaignEditorViewModel] per campaign the
/// user opens (or a new draft).
class CampaignsViewModel extends ChangeNotifier {
  CampaignsViewModel(this._repository);

  final CrmRepository _repository;

  List<Campaign> _campaigns = const [];
  bool _isLoading = false;
  bool _hasLoadError = false;

  List<Campaign> get campaigns => _campaigns;
  bool get isLoading => _isLoading;
  bool get hasLoadError => _hasLoadError;
  bool get isEmpty => _campaigns.isEmpty;

  Future<void> load() async {
    _isLoading = true;
    _hasLoadError = false;
    notifyListeners();

    final result = await _repository.loadCampaigns();
    switch (result) {
      case Ok<List<Campaign>>(value: final items):
        _campaigns = items;
      case Error<List<Campaign>>():
        _hasLoadError = true;
    }

    _isLoading = false;
    notifyListeners();
  }

  CampaignEditorViewModel editorFor(Campaign? campaign) {
    return CampaignEditorViewModel(_repository, campaign);
  }
}

/// Drives a single campaign: edit the draft, preview the audience, approve+send.
class CampaignEditorViewModel extends ChangeNotifier {
  CampaignEditorViewModel(this._repository, Campaign? campaign)
    : _campaign = campaign {
    if (campaign != null) {
      name = campaign.name;
      bodyTemplate = campaign.bodyTemplate;
      rfmSegments = campaign.rfmSegments.toSet();
    }
  }

  final CrmRepository _repository;
  Campaign? _campaign;
  bool _isSaving = false;
  bool _isPreviewing = false;
  bool _isSending = false;
  CampaignPreview? _preview;

  String name = '';
  String bodyTemplate = '';
  Set<String> rfmSegments = <String>{};

  Campaign? get campaign => _campaign;
  bool get isNew => _campaign == null;
  bool get isDraft => _campaign?.isDraft ?? true;
  bool get isSaving => _isSaving;
  bool get isPreviewing => _isPreviewing;
  bool get isSending => _isSending;
  bool get isBusy => _isSaving || _isPreviewing || _isSending;
  CampaignPreview? get preview => _preview;

  bool get canSave =>
      name.trim().isNotEmpty && bodyTemplate.trim().isNotEmpty && !isBusy;

  /// Sending requires a saved draft (the preview + send hit the persisted row).
  bool get canSend => _campaign != null && isDraft && !isBusy;

  void setName(String value) {
    name = value;
    notifyListeners();
  }

  void setBodyTemplate(String value) {
    bodyTemplate = value;
    notifyListeners();
  }

  void toggleSegment(String slug) {
    if (!rfmSegments.remove(slug)) {
      rfmSegments.add(slug);
    }
    notifyListeners();
  }

  Future<bool> save() async {
    if (!canSave) return false;
    _isSaving = true;
    _preview = null;
    notifyListeners();

    final draft = CampaignDraft(
      name: name.trim(),
      bodyTemplate: bodyTemplate.trim(),
      rfmSegments: rfmSegments.toList(),
    );
    final Result<Campaign> result = _campaign == null
        ? await _repository.createCampaign(draft)
        : await _repository.updateCampaign(_campaign!.id, draft);

    var ok = false;
    switch (result) {
      case Ok<Campaign>(value: final saved):
        _campaign = saved;
        ok = true;
      case Error<Campaign>():
        ok = false;
    }

    _isSaving = false;
    notifyListeners();
    return ok;
  }

  Future<void> loadPreview() async {
    final campaign = _campaign;
    if (campaign == null) return;
    _isPreviewing = true;
    notifyListeners();

    final result = await _repository.previewCampaign(campaign.id);
    switch (result) {
      case Ok<CampaignPreview>(value: final value):
        _preview = value;
      case Error<CampaignPreview>():
        _preview = null;
    }

    _isPreviewing = false;
    notifyListeners();
  }

  Future<bool> send() async {
    final campaign = _campaign;
    if (campaign == null) return false;
    _isSending = true;
    notifyListeners();

    final result = await _repository.sendCampaign(campaign.id);
    var ok = false;
    switch (result) {
      case Ok<Campaign>(value: final sent):
        _campaign = sent;
        ok = true;
      case Error<Campaign>():
        ok = false;
    }

    _isSending = false;
    notifyListeners();
    return ok;
  }
}
