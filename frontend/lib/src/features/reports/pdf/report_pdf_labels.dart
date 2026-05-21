import 'report_pdf_models.dart';

class ReportPdfLabels {
  const ReportPdfLabels({
    required this.generatedAt,
    required this.generatedBy,
    required this.reference,
    required this.period,
    required this.fromDate,
    required this.toDate,
    required this.summary,
    required this.auditTrail,
    required this.auditTime,
    required this.auditAction,
    required this.auditActor,
    required this.auditNote,
    required this.page,
    required this.ofPages,
    required this.emptyValue,
    required this.typeLabels,
  });

  const ReportPdfLabels.arabic()
    : generatedAt = 'تاريخ الإنشاء',
      generatedBy = 'أنشئ بواسطة',
      reference = 'المرجع',
      period = 'الفترة',
      fromDate = 'من',
      toDate = 'إلى',
      summary = 'الملخص',
      auditTrail = 'سجل التدقيق',
      auditTime = 'الوقت',
      auditAction = 'الإجراء',
      auditActor = 'المستخدم',
      auditNote = 'ملاحظة',
      page = 'صفحة',
      ofPages = 'من',
      emptyValue = '-',
      typeLabels = const {
        BusinessReportType.salesSummary: 'ملخص المبيعات',
        BusinessReportType.paymentSummary: 'ملخص المدفوعات',
        BusinessReportType.registerSessionArchive: 'أرشيف جلسات الصندوق',
        BusinessReportType.inventorySnapshot: 'لقطة المخزون',
        BusinessReportType.stockMovementArchive: 'أرشيف حركة المخزون',
        BusinessReportType.purchasingSummary: 'ملخص المشتريات',
        BusinessReportType.customerStatement: 'كشف عميل',
        BusinessReportType.supplierStatement: 'كشف مورد',
        BusinessReportType.discountAudit: 'تدقيق الخصومات',
        BusinessReportType.auditTrail: 'سجل تدقيق',
      };

  final String generatedAt;
  final String generatedBy;
  final String reference;
  final String period;
  final String fromDate;
  final String toDate;
  final String summary;
  final String auditTrail;
  final String auditTime;
  final String auditAction;
  final String auditActor;
  final String auditNote;
  final String page;
  final String ofPages;
  final String emptyValue;
  final Map<BusinessReportType, String> typeLabels;

  String typeLabel(BusinessReportType type) => typeLabels[type] ?? type.name;
}
