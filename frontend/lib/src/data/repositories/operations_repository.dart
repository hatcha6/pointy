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
    String? idempotencyKey,
  }) async {
    return Result.guard(
      () => _service.transitionJob(
        jobId,
        toStage: toStage,
        note: note,
        idempotencyKey: idempotencyKey,
      ),
    );
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
    int page = 1,
  }) async {
    return Result.guard(
      () => _service.fetchCustomerAssets(
        customer: customer,
        search: search,
        page: page,
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
