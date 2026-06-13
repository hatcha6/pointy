import '../models/bill_of_materials.dart';
import '../models/customer_asset.dart';
import '../models/operations_job.dart';
import '../models/workflow.dart';
import 'api_session.dart';

class OperationsApiClient {
  const OperationsApiClient(this._session);

  final PosApiSession _session;

  Future<OperationsJobPage> fetchJobs({
    OperationsJobStatus? status,
    OperationsJobType? jobType,
    int? currentStage,
    int? assignedTo,
    int? customer,
    int? asset,
    int? workflowTemplate,
    String search = '',
    int page = 1,
  }) async {
    final normalizedSearch = search.trim();
    final response = await _session.get(
      'jobs/',
      query: {
        if (status != null) 'status': status.toJson(),
        if (jobType != null) 'job_type': jobType.toJson(),
        if (currentStage != null) 'current_stage': '$currentStage',
        if (assignedTo != null) 'assigned_to': '$assignedTo',
        if (customer != null) 'customer': '$customer',
        if (asset != null) 'asset': '$asset',
        if (workflowTemplate != null) 'workflow_template': '$workflowTemplate',
        if (normalizedSearch.isNotEmpty) 'search': normalizedSearch,
        'page': '$page',
      },
    );
    _session.ensureSuccess(response, 'Job list request failed with status');
    return OperationsJobPage.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<OperationsJob> fetchJob(int jobId) async {
    final response = await _session.get('jobs/$jobId/');
    _session.ensureSuccess(response, 'Job detail request failed with status');
    return OperationsJob.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<OperationsJob> createJob(
    OperationsJobDraft draft, {
    String? idempotencyKey,
  }) async {
    final response = await _session.post(
      'jobs/',
      body: draft.toJson(),
      idempotencyKey: idempotencyKey,
    );
    _session.ensureSuccess(response, 'Job create failed with status');
    return OperationsJob.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<OperationsJob> updateJob(
    int jobId,
    Map<String, Object?> changes,
  ) async {
    final response = await _session.patch('jobs/$jobId/', body: changes);
    _session.ensureSuccess(response, 'Job update failed with status');
    return OperationsJob.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<OperationsJob> transitionJob(
    int jobId, {
    required int toStage,
    String note = '',
    String? idempotencyKey,
  }) async {
    final normalizedNote = note.trim();
    final response = await _session.post(
      'jobs/$jobId/transition/',
      body: {
        'to_stage': toStage,
        if (normalizedNote.isNotEmpty) 'note': normalizedNote,
      },
      idempotencyKey: idempotencyKey,
    );
    _session.ensureSuccess(response, 'Job transition failed with status');
    return OperationsJob.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<OperationsJob> addJobMaterial(
    int jobId, {
    required int variant,
    required double quantity,
    required bool consumeNow,
    String? idempotencyKey,
  }) async {
    final response = await _session.post(
      'jobs/$jobId/materials/',
      body: {'variant': variant, 'quantity': quantity, 'consume_now': consumeNow},
      idempotencyKey: idempotencyKey,
    );
    _session.ensureSuccess(response, 'Job material add failed with status');
    return OperationsJob.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<OperationsJob> reverseJobMaterial(int jobId, int materialId) async {
    final response = await _session.post(
      'jobs/$jobId/materials/$materialId/reverse/',
    );
    _session.ensureSuccess(response, 'Job material reverse failed with status');
    return OperationsJob.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<OperationsJob> cancelJob(int jobId, {String reason = ''}) async {
    final normalizedReason = reason.trim();
    final response = await _session.post(
      'jobs/$jobId/cancel/',
      body: {if (normalizedReason.isNotEmpty) 'reason': normalizedReason},
    );
    _session.ensureSuccess(response, 'Job cancel failed with status');
    return OperationsJob.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<OperationsJob> reopenJob(int jobId, {String note = ''}) async {
    final normalizedNote = note.trim();
    final response = await _session.post(
      'jobs/$jobId/reopen/',
      body: {if (normalizedNote.isNotEmpty) 'note': normalizedNote},
    );
    _session.ensureSuccess(response, 'Job reopen failed with status');
    return OperationsJob.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<OperationsJob> invoiceJob(
    int jobId,
    JobInvoiceDraft draft, {
    String? idempotencyKey,
  }) async {
    final response = await _session.post(
      'jobs/$jobId/invoice/',
      body: draft.toJson(),
      idempotencyKey: idempotencyKey,
    );
    _session.ensureSuccess(response, 'Job invoice failed with status');
    return OperationsJob.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<CustomerAssetPage> fetchCustomerAssets({
    int? customer,
    String search = '',
    int page = 1,
  }) async {
    final normalizedSearch = search.trim();
    final response = await _session.get(
      'assets/',
      query: {
        if (customer != null) 'customer': '$customer',
        if (normalizedSearch.isNotEmpty) 'search': normalizedSearch,
        'page': '$page',
      },
    );
    _session.ensureSuccess(
      response,
      'Customer asset list request failed with status',
    );
    return CustomerAssetPage.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<CustomerAsset> createCustomerAsset(CustomerAssetDraft draft) async {
    final response = await _session.post('assets/', body: draft.toJson());
    _session.ensureSuccess(response, 'Customer asset create failed with status');
    return CustomerAsset.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<CustomerAsset> updateCustomerAsset(
    int assetId,
    CustomerAssetDraft draft,
  ) async {
    final response = await _session.patch(
      'assets/$assetId/',
      body: draft.toJson(),
    );
    _session.ensureSuccess(response, 'Customer asset update failed with status');
    return CustomerAsset.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<WorkflowTemplatePage> fetchWorkflowTemplates({
    OperationsJobType? jobType,
    bool? isActive,
    int page = 1,
  }) async {
    final response = await _session.get(
      'workflow-templates/',
      query: {
        if (jobType != null) 'job_type': jobType.toJson(),
        if (isActive != null) 'is_active': '$isActive',
        'page': '$page',
      },
    );
    _session.ensureSuccess(
      response,
      'Workflow template list request failed with status',
    );
    return WorkflowTemplatePage.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<WorkflowTemplate> saveWorkflowTemplate(
    WorkflowTemplateDraft draft,
  ) async {
    final templateId = draft.id;
    final response = templateId == null
        ? await _session.post('workflow-templates/', body: draft.toJson())
        : await _session.put(
            'workflow-templates/$templateId/',
            body: draft.toJson(),
          );
    _session.ensureSuccess(
      response,
      'Workflow template save failed with status',
    );
    return WorkflowTemplate.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<void> deleteWorkflowTemplate(int templateId) async {
    final response = await _session.delete('workflow-templates/$templateId/');
    _session.ensureSuccess(
      response,
      'Workflow template delete failed with status',
    );
  }

  Future<BillOfMaterialsPage> fetchBoms({bool? isActive, int page = 1}) async {
    final response = await _session.get(
      'boms/',
      query: {
        if (isActive != null) 'is_active': '$isActive',
        'page': '$page',
      },
    );
    _session.ensureSuccess(response, 'BOM list request failed with status');
    return BillOfMaterialsPage.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<BillOfMaterials> saveBom(BillOfMaterialsDraft draft) async {
    final bomId = draft.id;
    final response = bomId == null
        ? await _session.post('boms/', body: draft.toJson())
        : await _session.put('boms/$bomId/', body: draft.toJson());
    _session.ensureSuccess(response, 'BOM save failed with status');
    return BillOfMaterials.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<void> deleteBom(int bomId) async {
    final response = await _session.delete('boms/$bomId/');
    _session.ensureSuccess(response, 'BOM delete failed with status');
  }
}
