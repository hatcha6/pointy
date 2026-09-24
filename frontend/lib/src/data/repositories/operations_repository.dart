import '../../core/result.dart';
import '../models/bill_of_materials.dart';
import '../models/customer_asset.dart';
import '../models/operations_job.dart';
import '../models/workflow.dart';
import '../services/pos_api_service.dart';

class OperationsRepository {
  OperationsRepository(this._service);

  final PosApiService _service;

  Future<Result<OperationsJobPage>> loadJobs({
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
    return Result.guard(
      () => _service.fetchJobs(
        status: status,
        jobType: jobType,
        currentStage: currentStage,
        assignedTo: assignedTo,
        customer: customer,
        asset: asset,
        workflowTemplate: workflowTemplate,
        search: search,
        page: page,
      ),
    );
  }

  Future<Result<List<OperationsJob>>> loadAllJobs({
    OperationsJobStatus? status,
    OperationsJobType? jobType,
    int? currentStage,
    int? assignedTo,
    int? customer,
    int? asset,
    int? workflowTemplate,
    String search = '',
  }) async {
    return Result.guard(() async {
      final jobs = <OperationsJob>[];
      var page = 1;
      var hasMore = true;
      while (hasMore) {
        final result = await _service.fetchJobs(
          status: status,
          jobType: jobType,
          currentStage: currentStage,
          assignedTo: assignedTo,
          customer: customer,
          asset: asset,
          workflowTemplate: workflowTemplate,
          search: search,
          page: page,
        );
        jobs.addAll(result.jobs);
        hasMore = result.hasMore;
        page += 1;
      }
      return jobs;
    });
  }

  /// Declined jobs whose item is still on the shelf, waiting for the customer
  /// to collect it unrepaired. Kept apart from [loadAllJobs] on purpose: the
  /// board lists open work, and these are finished jobs it still has to show.
  Future<Result<List<OperationsJob>>> loadJobsAwaitingHandBack({
    String search = '',
  }) async {
    return Result.guard(() async {
      final jobs = <OperationsJob>[];
      var page = 1;
      var hasMore = true;
      while (hasMore) {
        final result = await _service.fetchJobs(
          awaitingHandBack: true,
          search: search,
          page: page,
        );
        jobs.addAll(result.jobs);
        hasMore = result.hasMore;
        page += 1;
      }
      return jobs;
    });
  }

  Future<Result<OperationsJob>> loadJob(int jobId) async {
    return Result.guard(() => _service.fetchJob(jobId));
  }

  Future<Result<OperationsJob>> createJob(
    OperationsJobDraft draft, {
    String? idempotencyKey,
  }) async {
    return Result.guard(
      () => _service.createJob(draft, idempotencyKey: idempotencyKey),
    );
  }

  Future<Result<OperationsJob>> updateJob(
    int jobId,
    Map<String, Object?> changes,
  ) async {
    return Result.guard(() => _service.updateJob(jobId, changes));
  }

  Future<Result<OperationsJob>> assignJob(int jobId, int? employeeId) async {
    return Result.guard(() => _service.assignJob(jobId, employeeId));
  }

  Future<Result<OperationsJob>> transitionJob(
    int jobId, {
    required int toStage,
    String note = '',
    String handedOverTo = '',
    bool forceRelease = false,
    String? idempotencyKey,
  }) async {
    return Result.guard(
      () => _service.transitionJob(
        jobId,
        toStage: toStage,
        note: note,
        handedOverTo: handedOverTo,
        forceRelease: forceRelease,
        idempotencyKey: idempotencyKey,
      ),
    );
  }

  Future<Result<OperationsJob>> addJobService(
    int jobId,
    JobServiceDraft draft, {
    String? idempotencyKey,
  }) async {
    return Result.guard(
      () =>
          _service.addJobService(jobId, draft, idempotencyKey: idempotencyKey),
    );
  }

  Future<Result<OperationsJob>> removeJobService(
    int jobId,
    int serviceId,
  ) async {
    return Result.guard(() => _service.removeJobService(jobId, serviceId));
  }

  Future<Result<OperationsJob>> holdJob(
    int jobId, {
    required String reason,
  }) async {
    return Result.guard(() => _service.holdJob(jobId, reason: reason));
  }

  Future<Result<OperationsJob>> resumeJob(int jobId) async {
    return Result.guard(() => _service.resumeJob(jobId));
  }

  Future<Result<OperationsJob>> addJobMaterial(
    int jobId, {
    required int variant,
    required double quantity,
    required bool consumeNow,
    String? idempotencyKey,
  }) async {
    return Result.guard(
      () => _service.addJobMaterial(
        jobId,
        variant: variant,
        quantity: quantity,
        consumeNow: consumeNow,
        idempotencyKey: idempotencyKey,
      ),
    );
  }

  Future<Result<OperationsJob>> reverseJobMaterial(
    int jobId,
    int materialId,
  ) async {
    return Result.guard(() => _service.reverseJobMaterial(jobId, materialId));
  }

  Future<Result<OperationsJob>> cancelJob(
    int jobId, {
    String reason = '',
  }) async {
    return Result.guard(() => _service.cancelJob(jobId, reason: reason));
  }

  Future<Result<OperationsJob>> declineJob(
    int jobId,
    JobDeclineDraft draft, {
    String? idempotencyKey,
  }) async {
    return Result.guard(
      () => _service.declineJob(jobId, draft, idempotencyKey: idempotencyKey),
    );
  }

  Future<Result<OperationsJob>> handBackJob(
    int jobId, {
    String handedOverTo = '',
    String note = '',
    bool forceRelease = false,
    String? idempotencyKey,
  }) async {
    return Result.guard(
      () => _service.handBackJob(
        jobId,
        handedOverTo: handedOverTo,
        note: note,
        forceRelease: forceRelease,
        idempotencyKey: idempotencyKey,
      ),
    );
  }

  Future<Result<OperationsJob>> reopenJob(int jobId, {String note = ''}) async {
    return Result.guard(() => _service.reopenJob(jobId, note: note));
  }

  Future<Result<OperationsJob>> invoiceJob(
    int jobId,
    JobInvoiceDraft draft, {
    String? idempotencyKey,
  }) async {
    return Result.guard(
      () => _service.invoiceJob(jobId, draft, idempotencyKey: idempotencyKey),
    );
  }

  Future<Result<CustomerAssetPage>> loadCustomerAssets({
    int? customer,
    String search = '',
    bool? inShop,
    String? assetType,
    String ordering = '',
    int page = 1,
  }) async {
    return Result.guard(
      () => _service.fetchCustomerAssets(
        customer: customer,
        search: search,
        inShop: inShop,
        assetType: assetType,
        ordering: ordering,
        page: page,
      ),
    );
  }

  Future<Result<List<CustomerAssetType>>> loadAssetTypes({
    bool? isActive,
  }) async {
    return Result.guard(() async {
      final types = <CustomerAssetType>[];
      var page = 1;
      var hasMore = true;
      while (hasMore) {
        final result = await _service.fetchAssetTypes(
          isActive: isActive,
          page: page,
        );
        types.addAll(result.types);
        hasMore = result.hasMore;
        page += 1;
      }
      return types;
    });
  }

  Future<Result<CustomerAssetType>> saveAssetType(
    CustomerAssetType type,
  ) async {
    return Result.guard(() => _service.saveAssetType(type));
  }

  Future<Result<void>> deleteAssetType(int typeId) async {
    return Result.guard(() => _service.deleteAssetType(typeId));
  }

  Future<Result<CustomerAssetDetail>> loadCustomerAsset(int assetId) async {
    return Result.guard(() => _service.fetchCustomerAsset(assetId));
  }

  Future<Result<CustomerAsset>> transferCustomerAsset(
    int assetId, {
    required int customer,
    String note = '',
  }) async {
    return Result.guard(
      () => _service.transferCustomerAsset(
        assetId,
        customer: customer,
        note: note,
      ),
    );
  }

  Future<Result<CustomerAsset>> createCustomerAsset(
    CustomerAssetDraft draft,
  ) async {
    return Result.guard(() => _service.createCustomerAsset(draft));
  }

  Future<Result<CustomerAsset>> updateCustomerAsset(
    int assetId,
    CustomerAssetDraft draft,
  ) async {
    return Result.guard(() => _service.updateCustomerAsset(assetId, draft));
  }

  Future<Result<List<WorkflowTemplate>>> loadAllWorkflowTemplates({
    OperationsJobType? jobType,
    bool? isActive,
  }) async {
    return Result.guard(() async {
      final templates = <WorkflowTemplate>[];
      var page = 1;
      var hasMore = true;
      while (hasMore) {
        final result = await _service.fetchWorkflowTemplates(
          jobType: jobType,
          isActive: isActive,
          page: page,
        );
        templates.addAll(result.templates);
        hasMore = result.hasMore;
        page += 1;
      }
      return templates;
    });
  }

  Future<Result<WorkflowTemplate>> saveWorkflowTemplate(
    WorkflowTemplateDraft draft,
  ) async {
    return Result.guard(() => _service.saveWorkflowTemplate(draft));
  }

  Future<Result<void>> deleteWorkflowTemplate(int templateId) async {
    return Result.guard(() => _service.deleteWorkflowTemplate(templateId));
  }

  Future<Result<List<BillOfMaterials>>> loadAllBoms({bool? isActive}) async {
    return Result.guard(() async {
      final boms = <BillOfMaterials>[];
      var page = 1;
      var hasMore = true;
      while (hasMore) {
        final result = await _service.fetchBoms(isActive: isActive, page: page);
        boms.addAll(result.boms);
        hasMore = result.hasMore;
        page += 1;
      }
      return boms;
    });
  }

  Future<Result<BillOfMaterials>> saveBom(BillOfMaterialsDraft draft) async {
    return Result.guard(() => _service.saveBom(draft));
  }

  Future<Result<void>> deleteBom(int bomId) async {
    return Result.guard(() => _service.deleteBom(bomId));
  }
}
