import '../../shared/formatters.dart';
import '../models/register_session_summary.dart';

/// The printed words of the Z-Report's provider-services section.
///
/// A class rather than ARB strings for the same reason as `RepairTicketLabels`:
/// both Z-Report formats are laid out with no `BuildContext` to localise from.
/// Shared by the thermal drawer copy and the A4 PDF so the two name a bucket
/// the same way.
///
/// Tashkeel is kept to one mark per letter at most: the PDF shaper drops a mark
/// stacked on another (see the receipt tagline), and a thermal code page has
/// no room for them either.
class ZReportIntegrationLabels {
  const ZReportIntegrationLabels.arabic()
    : title = 'خدمات الشحن',
      provider = 'المزوّد',
      transactionCount = 'العمليات',
      sold = 'دفعه الزبائن',
      cost = 'حصة المزوّد',
      margin = 'ربح المتجر',
      total = 'إجمالي خدمات الشحن',
      allProviders = 'الإجمالي',
      delivered = 'نُفّذ',
      awaiting = 'لم يُنفّذ بعد',
      unknown = 'بحاجة إلى مراجعة',
      refunded = 'مُرتجع',
      refundedAfterDelivery = 'مُرتجع بعد التنفيذ',
      floatLost = 'خرج من رصيد الوكالة دون مقابل',
      receipt = 'الفاتورة',
      service = 'الخدمة',
      subscriber = 'البطاقة / الخط',
      price = 'السعر',
      transactionCost = 'التكلفة',
      amount = 'المبلغ',
      status = 'الحالة',
      unknownProvider = 'خدمة غير معروفة';

  final String title;
  final String provider;
  final String transactionCount;
  final String sold;
  final String cost;
  final String margin;
  final String total;
  final String allProviders;
  final String delivered;
  final String awaiting;
  final String unknown;
  final String refunded;
  final String refundedAfterDelivery;

  /// Float money spent on sales the shop then refunded.
  final String floatLost;
  final String receipt;
  final String service;
  final String subscriber;
  final String price;
  final String transactionCost;
  final String amount;
  final String status;
  final String unknownProvider;

  /// The provider's own brand, as the shop knows it.
  String providerName(String key) {
    return switch (key) {
      'hdbox' => 'HD Box',
      'lnet' => 'LNET',
      'qareeb' => 'قريب',
      _ => unknownProvider,
    };
  }

  String bucket(SessionIntegrationBucket bucket) {
    return switch (bucket) {
      SessionIntegrationBucket.delivered => delivered,
      SessionIntegrationBucket.awaiting => awaiting,
      SessionIntegrationBucket.unknown => unknown,
      SessionIntegrationBucket.refunded => refunded,
    };
  }

  /// One transaction's state, singling out a refund the provider had already
  /// performed — the float paid for it either way.
  String transactionStatus(SessionIntegrationTransaction transaction) {
    return transaction.isRefundedAfterDelivery
        ? refundedAfterDelivery
        : bucket(transaction.bucket);
  }

  /// "HD Box — لم يُنفّذ بعد (2)": one provider's problem line.
  String providerLine(String provider, String what, int count) =>
      '${providerName(provider)} — $what ($count)';
}

/// The thermal drawer copy's provider-services section, ready for the
/// `z_report` encoder: what each provider's customers paid, then one line per
/// way that money went astray.
///
/// Cost and margin are deliberately left to the manager's screen and the A4
/// copy. This slip is printed at the counter, often by the cashier, and what
/// the shop pays a provider is the owner's number, not the counter's.
Map<String, Object?> zReportIntegrationThermalSection(
  SessionIntegrations integrations,
) {
  const labels = ZReportIntegrationLabels.arabic();
  return {
    'title': labels.title,
    'rows': [
      for (final figures in integrations.providers) ...[
        {
          'label':
              '${labels.providerName(figures.provider)} '
              '(${figures.transactionCount})',
          'value': formatMoney(figures.sold),
        },
        for (final bucket in const [
          SessionIntegrationBucket.unknown,
          SessionIntegrationBucket.awaiting,
          SessionIntegrationBucket.refunded,
        ])
          if (figures.bucket(bucket).count > 0)
            {
              'label': labels.providerLine(
                figures.provider,
                labels.bucket(bucket),
                figures.bucket(bucket).count,
              ),
              'value': formatMoney(figures.bucket(bucket).amount),
            },
        // A heading-only line: the float's loss is a cost, and cost stays off
        // this slip — but that it happened is exactly what the drawer copy is
        // for.
        if (figures.refundedAfterDelivery.count > 0)
          {
            'label': labels.providerLine(
              figures.provider,
              labels.refundedAfterDelivery,
              figures.refundedAfterDelivery.count,
            ),
            'value': '',
            'emphasize': true,
          },
      ],
    ],
    'total': {
      'label': labels.total,
      'value': formatMoney(integrations.totals.sold),
    },
  };
}
