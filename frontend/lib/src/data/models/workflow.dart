import 'operations_job.dart';

class WorkflowStage {
  const WorkflowStage({
    required this.id,
    required this.code,
    required this.name,
    required this.displayOrder,
    required this.isInitial,
    required this.isTerminal,
    required this.requiresCustomerApproval,
    required this.consumesMaterials,
    required this.producesOutput,
  });

  final int id;
  final String code;
  final String name;
  final int displayOrder;
  final bool isInitial;
  final bool isTerminal;
  final bool requiresCustomerApproval;
  final bool consumesMaterials;
  final bool producesOutput;

  factory WorkflowStage.fromJson(Map<String, Object?> json) {
    return WorkflowStage(
      id: json['id'] as int,
      code: json['code']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      displayOrder: _intFromJson(json['display_order']),
      isInitial: json['is_initial'] == true,
      isTerminal: json['is_terminal'] == true,
      requiresCustomerApproval: json['requires_customer_approval'] == true,
      consumesMaterials: json['consumes_materials'] == true,
      producesOutput: json['produces_output'] == true,
    );
  }
}

class WorkflowTemplate {
  const WorkflowTemplate({
    required this.id,
    required this.name,
    required this.jobType,
    required this.isActive,
    required this.isSystem,
    required this.jobCount,
    required this.stages,
    this.createdAt,
    this.updatedAt,
  });

  final int id;
  final String name;
  final OperationsJobType jobType;
  final bool isActive;
  final bool isSystem;
  final int jobCount;
  final List<WorkflowStage> stages;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  factory WorkflowTemplate.fromJson(Map<String, Object?> json) {
    final stagesJson = (json['stages'] as List<Object?>?) ?? const [];
    return WorkflowTemplate(
      id: json['id'] as int,
      name: json['name']?.toString() ?? '',
      jobType: OperationsJobType.fromJson(json['job_type']),
      isActive: json['is_active'] == true,
      isSystem: json['is_system'] == true,
      jobCount: _intFromJson(json['job_count']),
      stages: stagesJson
          .whereType<Map<String, Object?>>()
          .map(WorkflowStage.fromJson)
          .toList(growable: false),
      createdAt: _dateTimeFromJson(json['created_at']),
      updatedAt: _dateTimeFromJson(json['updated_at']),
    );
  }
}

class WorkflowTemplatePage {
  const WorkflowTemplatePage({required this.templates, required this.hasMore});

  final List<WorkflowTemplate> templates;
  final bool hasMore;

  factory WorkflowTemplatePage.fromJson(Map<String, Object?> json) {
    final results = (json['results'] as List<Object?>)
        .cast<Map<String, Object?>>()
        .map(WorkflowTemplate.fromJson)
        .toList(growable: false);

    return WorkflowTemplatePage(
      templates: results,
      hasMore: json['next'] != null,
    );
  }
}

class WorkflowStageDraft {
  const WorkflowStageDraft({
    required this.code,
    required this.name,
    required this.displayOrder,
    this.id,
    this.isInitial = false,
    this.isTerminal = false,
    this.requiresCustomerApproval = false,
    this.consumesMaterials = false,
    this.producesOutput = false,
  });

  final int? id;
  final String code;
  final String name;
  final int displayOrder;
  final bool isInitial;
  final bool isTerminal;
  final bool requiresCustomerApproval;
  final bool consumesMaterials;
  final bool producesOutput;

  Map<String, Object?> toJson() {
    return {
      if (id != null) 'id': id,
      'code': code,
      'name': name,
      'display_order': displayOrder,
      'is_initial': isInitial,
      'is_terminal': isTerminal,
      'requires_customer_approval': requiresCustomerApproval,
      'consumes_materials': consumesMaterials,
      'produces_output': producesOutput,
    };
  }
}

class WorkflowTemplateDraft {
  const WorkflowTemplateDraft({
    required this.name,
    required this.jobType,
    required this.stages,
    this.id,
    this.isActive = true,
  });

  final int? id;
  final String name;
  final OperationsJobType jobType;
  final bool isActive;
  final List<WorkflowStageDraft> stages;

  Map<String, Object?> toJson() {
    return {
      'name': name,
      'job_type': jobType.toJson(),
      'is_active': isActive,
      'stages': stages.map((stage) => stage.toJson()).toList(growable: false),
    };
  }
}

int _intFromJson(Object? value) {
  if (value is int) {
    return value;
  }
  return int.tryParse((value ?? 0).toString()) ?? 0;
}

DateTime? _dateTimeFromJson(Object? value) {
  if (value == null) {
    return null;
  }
  return DateTime.tryParse(value.toString());
}
