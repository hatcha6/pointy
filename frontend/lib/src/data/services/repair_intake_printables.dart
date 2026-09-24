import '../models/barcode_label.dart';
import '../models/customer_asset.dart';
import '../models/operations_job.dart';
import '../models/repair_ticket.dart';
import '../models/shop_settings.dart';

/// The printed words of the repair intake receipt and the device sticker.
///
/// A class rather than ARB strings for the same reason as
/// `OrderDocumentLabels`: the receipt renders in a background isolate, where
/// there is no `BuildContext` to localise from. Arabic, like every document
/// this shop prints.
///
/// Tashkeel is kept to one mark per letter at most: the PDF shaper drops a
/// mark stacked on another (see the receipt tagline), and a thermal code page
/// has no room for them either.
class RepairTicketLabels {
  const RepairTicketLabels.arabic()
    : title = 'إيصال استلام جهاز',
      jobNumber = 'رقم المهمة',
      scanHint = 'أحضر هذا الإيصال عند استلام جهازك',
      receivedAt = 'تاريخ الاستلام',
      dueAt = 'موعد التسليم المتوقع',
      customer = 'الزبون',
      phone = 'الهاتف',
      device = 'الجهاز',
      color = 'اللون',
      imei = 'IMEI',
      serial = 'الرقم التسلسلي',
      plate = 'اللوحة',
      vin = 'رقم الشاصي',
      problem = 'وصف العطل',
      quotedPrice = 'السعر التقديري',
      diagnosisFee = 'رسوم الفحص عند رفض التصليح',
      warranty = 'الضمان',
      terms = 'الشروط',
      receivedBy = 'استلمه',
      customerSignature = 'توقيع الزبون',
      shopPhone = 'هاتف المحل',
      walkInCustomer = 'زبون',
      unnamedDevice = 'جهاز',
      defaultTerms = const [
        'يسلم الجهاز لحامل هذا الإيصال، فاحتفظ به.',
        'المحل غير مسؤول عن البيانات، يرجى أخذ نسخة احتياطية قبل الصيانة.',
        'الفحص مجاني عند إجراء التصليح، وتستحق رسوم الفحص إذا رفض الزبون '
            'التصليح.',
        'المحل غير مسؤول عن الأجهزة التي لا تستلم خلال 60 يومًا من إبلاغ '
            'الزبون بجاهزيتها.',
        'قد تتعطل الأجهزة المعرضة للسوائل أو المفتوحة سابقًا أثناء الصيانة، '
            'ولا يتحمل المحل ذلك.',
        'يشمل الضمان القطعة المستبدلة فقط، ولا يشمل الكسر أو السوائل.',
      ];

  final String title;
  final String jobNumber;
  final String scanHint;
  final String receivedAt;
  final String dueAt;
  final String customer;
  final String phone;
  final String device;
  final String color;
  final String imei;
  final String serial;
  final String plate;
  final String vin;
  final String problem;
  final String quotedPrice;
  final String diagnosisFee;
  final String warranty;
  final String terms;
  final String receivedBy;
  final String customerSignature;
  final String shopPhone;
  final String walkInCustomer;
  final String unnamedDevice;

  /// Printed when the shop has not written its own conditions.
  final List<String> defaultTerms;

  /// "30 يومًا" — Arabic counts days four ways, and a receipt that gets the
  /// grammar wrong reads as careless on the one document the customer keeps.
  String warrantyDays(int days) {
    if (days == 1) {
      return 'يوم واحد';
    }
    if (days == 2) {
      return 'يومان';
    }
    if (days >= 3 && days <= 10) {
      return '$days أيام';
    }
    return '$days يومًا';
  }
}

/// The intake receipt for [job], as the customer takes it home.
RepairTicket buildRepairTicket(
  OperationsJob job, {
  ShopSettings? settings,
  RepairTicketLabels labels = const RepairTicketLabels.arabic(),
}) {
  final shopName = settings?.shopName.trim() ?? '';
  final fee = settings?.repairDiagnosisFee;
  return RepairTicket(
    shopName: shopName.isEmpty ? 'نقطة البيع' : shopName,
    shopHeaderLines: _lines(settings?.receiptHeader ?? ''),
    shopPhone: settings?.shopPhone.trim() ?? '',
    jobNumber: job.jobNumber,
    scanCode: repairScanCode(job.jobNumber),
    receivedAt: job.createdAt,
    dueAt: job.dueAt,
    customerName: job.customerName.trim().isEmpty
        ? labels.walkInCustomer
        : job.customerName.trim(),
    customerPhone: job.customerPhone.trim(),
    devices: [
      for (final link in job.assets)
        if (link.assetDetails != null) _device(link.assetDetails!, labels),
    ],
    problem: job.symptoms.trim(),
    quotedPrice: job.quotedPrice,
    diagnosisFee: fee != null && fee > 0 ? fee : null,
    warrantyDays: job.warrantyDays,
    // The shop's own list when it has one — even an empty one, which is a shop
    // that prints no conditions; the defaults only when it never wrote any.
    terms: settings?.repairTicketTerms ?? labels.defaultTerms,
    receivedBy: job.createdByName.trim(),
    footerNote: _nonEmpty(settings?.receiptFooter),
  );
}

/// The sticker that goes on the customer's item: the same card a product label
/// prints, carrying whose it is, the job's barcode, and what is wrong with it.
///
/// The full job number rides in the SKU slot, which the raw label languages
/// print under the bars; the PDF card prints the scan code there instead.
BarcodeLabelPrintLine repairLabelPrintLine(
  OperationsJob job, {
  RepairTicketLabels labels = const RepairTicketLabels.arabic(),
}) {
  final customer = job.customerName.trim().isNotEmpty
      ? job.customerName.trim()
      : job.customerPhone.trim().isNotEmpty
      ? job.customerPhone.trim()
      : labels.walkInCustomer;
  return BarcodeLabelPrintLine(
    label: BarcodeLabelDraft(
      displayName: customer,
      productName: customer,
      sku: job.jobNumber,
      barcode: repairScanCode(job.jobNumber),
      unitPrice: 0,
    ),
    copies: 1,
    includePrice: false,
    caption: _stickerCaption(job, labels),
  );
}

/// What the bench needs to read off the sticker: the fault, briefly. A phone
/// in a tray does not need its own model name printed on it, so that is only
/// the fallback for a job taken in with no description.
String _stickerCaption(OperationsJob job, RepairTicketLabels labels) {
  final problem = job.symptoms.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (problem.isNotEmpty) {
    return _clip(problem, 22);
  }
  for (final link in job.assets) {
    final asset = link.assetDetails;
    if (asset != null && asset.displayName.trim().isNotEmpty) {
      return _clip(asset.displayName.trim(), 22);
    }
  }
  return '';
}

RepairTicketDevice _device(CustomerAsset asset, RepairTicketLabels labels) {
  final name = asset.displayName.trim().isNotEmpty
      ? asset.displayName.trim()
      : labels.unnamedDevice;
  final custom = asset.customIdentifier.trim();
  return RepairTicketDevice(
    name: name,
    identifiers: [
      if (asset.plateNumber.trim().isNotEmpty)
        '${labels.plate} ${asset.plateNumber.trim()}',
      if (asset.vin.trim().isNotEmpty) '${labels.vin} ${asset.vin.trim()}',
      if (asset.imei.trim().isNotEmpty) '${labels.imei} ${asset.imei.trim()}',
      if (asset.serialNumber.trim().isNotEmpty)
        '${labels.serial} ${asset.serialNumber.trim()}',
      if (custom.isNotEmpty)
        asset.customIdentifierLabel.trim().isEmpty
            ? custom
            : '${asset.customIdentifierLabel.trim()} $custom',
    ],
    color: asset.color.trim(),
  );
}

/// Cuts [value] at a word boundary so it fits [max] characters, marking the
/// cut. A sticker row scales its text down to fit, so a long line would not be
/// clipped — it would be printed too small to read, which is worse.
String _clip(String value, int max) {
  if (value.length <= max) {
    return value;
  }
  final cut = value.substring(0, max);
  final lastSpace = cut.lastIndexOf(' ');
  final head = lastSpace > max ~/ 2 ? cut.substring(0, lastSpace) : cut;
  return '${head.trimRight()}…';
}

List<String> _lines(String value) {
  return [
    for (final line in value.split(RegExp(r'\r?\n')))
      if (line.trim().isNotEmpty) line.trim(),
  ];
}

String? _nonEmpty(String? value) {
  final trimmed = value?.trim() ?? '';
  return trimmed.isEmpty ? null : trimmed;
}
