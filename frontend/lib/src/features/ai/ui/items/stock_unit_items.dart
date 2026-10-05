import 'package:flutter/material.dart';
import 'package:genui/genui.dart';
import 'package:json_schema_builder/json_schema_builder.dart';

import '../../../../../l10n/generated/app_localizations.dart';
import '../../../../data/models/stock_unit.dart';
import '../../../../shared/components/components.dart';
import '../../../../shared/design/design.dart';
import '../ai_ui_support.dart';

/// Unit statuses the card understands — `StockUnit.Status` on the backend.
const List<String> _unitStatuses = <String>[
  StockUnitStatus.expected,
  StockUnitStatus.inStock,
  StockUnitStatus.reserved,
  StockUnitStatus.inTransit,
  StockUnitStatus.sold,
  StockUnitStatus.returned,
  StockUnitStatus.damaged,
  StockUnitStatus.writtenOff,
  StockUnitStatus.cancelled,
];

/// After this long on a shelf a used handset is the ageing question (§8.4),
/// so the card says so in the warning tone rather than leaving it to be read.
const int _agedAfterDays = 90;

final aiStockUnitCard = CatalogItem(
  name: 'StockUnitCard',
  dataSchema: S.object(
    description:
        'One identified article — a handset by IMEI, a serial, a pack in a '
        'lot. Use after lookup_stock_unit, copying its "card" as these '
        'properties. For several units use variant "compact" inside a Column '
        '(up to five); for more, a Table. Tapping it opens the unit.',
    properties: {
      'unitId': S.integer(description: 'The stock unit id, from the tool.'),
      'code': S.string(description: 'The identifier: IMEI, serial number.'),
      'product': S.string(description: 'Product and variant name.'),
      'status': S.string(
        description: 'Where the article is in its life.',
        enumValues: _unitStatuses,
      ),
      'price': S.number(description: 'Its own asking price, in shop money.'),
      'daysOnShelf': S.integer(description: 'Days since it went on sale.'),
      'warehouse': S.string(description: 'Where it is now.'),
      'lot': S.string(description: 'The lot it belongs to, if any.'),
      'expiryDate': S.string(description: 'The lot expiry, YYYY-MM-DD.'),
      'availability': S.string(
        description:
            'Whether its lot may be sold: "recalled" for a quarantined lot, '
            '"expired" for a lot past its date. Omit when it may.',
        enumValues: ['ok', 'recalled', 'expired'],
      ),
      'consignment': S.boolean(
        description: 'True when the article belongs to a consignor.',
      ),
      'attributes': S.list(
        description: 'The facts the shop records, e.g. battery or grade.',
        items: S.object(
          properties: {'label': S.string(), 'value': S.string()},
          required: ['label', 'value'],
        ),
      ),
      'variant': S.string(
        description: '"full" for one article, "compact" for a row in a list.',
        enumValues: ['full', 'compact'],
      ),
    },
    required: ['unitId', 'code', 'product'],
  ),
  exampleData: [
    () => '''
      [{"id": "root", "component": "StockUnitCard", "unitId": 41,
        "code": "358240051111110", "product": "آيفون 13 · 128GB أزرق",
        "status": "in_stock", "price": 1450, "daysOnShelf": 23,
        "warehouse": "المحل الرئيسي",
        "attributes": [{"label": "البطارية", "value": "86%"},
                       {"label": "الحالة", "value": "A"}]}]
    ''',
  ],
  widgetBuilder: (itemContext) {
    final data = itemContext.data as Map<String, Object?>;
    final unit = AiStockUnitCardData.fromMap(data);
    void open() => aiDispatchAction(itemContext, {
      'event': {
        'name': 'navigate:stock-unit',
        'context': {'link': 'pointy://stock-unit/${unit.unitId}'},
      },
    });
    return data['variant'] == 'compact'
        ? _CompactUnitRow(unit: unit, onTap: open)
        : _FullUnitCard(unit: unit, onTap: open);
  },
);

/// The card's data, read once from the model's properties. Public so the
/// widget tests and the preview board build the same thing the chat does.
class AiStockUnitCardData {
  const AiStockUnitCardData({
    required this.unitId,
    required this.code,
    required this.product,
    this.status = '',
    this.price,
    this.daysOnShelf,
    this.warehouse = '',
    this.lot = '',
    this.expiryDate = '',
    this.availability = 'ok',
    this.consignment = false,
    this.attributes = const [],
  });

  final int unitId;
  final String code;
  final String product;
  final String status;
  final Object? price;
  final int? daysOnShelf;
  final String warehouse;
  final String lot;
  final String expiryDate;
  final String availability;
  final bool consignment;
  final List<(String, String)> attributes;

  bool get isStopped => availability == 'recalled' || availability == 'expired';
  bool get isAged => (daysOnShelf ?? 0) >= _agedAfterDays;

  factory AiStockUnitCardData.fromMap(Map<String, Object?> data) {
    int? asInt(Object? value) =>
        value is num ? value.toInt() : int.tryParse('${value ?? ''}');
    return AiStockUnitCardData(
      unitId: asInt(data['unitId']) ?? 0,
      code: aiString(data, 'code'),
      product: aiString(data, 'product'),
      status: aiString(data, 'status'),
      price: data['price'],
      daysOnShelf: asInt(data['daysOnShelf']),
      warehouse: aiString(data, 'warehouse'),
      lot: aiString(data, 'lot'),
      expiryDate: aiString(data, 'expiryDate'),
      availability: aiString(data, 'availability', fallback: 'ok'),
      consignment: data['consignment'] == true,
      attributes: [
        for (final entry in (data['attributes'] as List? ?? const <Object?>[]))
          if (entry is Map && '${entry['value'] ?? ''}'.isNotEmpty)
            ('${entry['label'] ?? ''}', '${entry['value']}'),
      ],
    );
  }
}

String _statusLabel(AppLocalizations l10n, String status) => switch (status) {
  StockUnitStatus.inStock => l10n.stockUnitStatusInStock,
  StockUnitStatus.reserved => l10n.stockUnitStatusReserved,
  StockUnitStatus.sold => l10n.stockUnitStatusSold,
  StockUnitStatus.damaged => l10n.stockUnitStatusDamaged,
  StockUnitStatus.writtenOff => l10n.stockUnitStatusWrittenOff,
  StockUnitStatus.inTransit => l10n.aiUiStockUnitStatusInTransit,
  StockUnitStatus.returned => l10n.aiUiStockUnitStatusReturned,
  StockUnitStatus.expected => l10n.aiUiStockUnitStatusExpected,
  StockUnitStatus.cancelled => l10n.aiUiStockUnitStatusCancelled,
  _ => status,
};

AiTone _statusTone(String status) => switch (status) {
  StockUnitStatus.inStock => AiTone.success,
  StockUnitStatus.reserved || StockUnitStatus.inTransit => AiTone.info,
  StockUnitStatus.expected => AiTone.warning,
  StockUnitStatus.damaged || StockUnitStatus.writtenOff => AiTone.danger,
  _ => AiTone.neutral,
};

/// LTR isolate for identifiers inside Arabic runs, so «3582…» and «AB-12»
/// keep their order.
String _ltr(String value) => '\u2066$value\u2069';

List<Widget> _pills(BuildContext context, AiStockUnitCardData unit) {
  final l10n = AppLocalizations.of(context)!;
  final colors = context.pointyColors;
  final days = unit.daysOnShelf;
  return [
    if (unit.status.isNotEmpty)
      PointyStatusPill(
        label: _statusLabel(l10n, unit.status),
        color: aiToneColor(context, _statusTone(unit.status)),
      ),
    if (days != null && unit.status == StockUnitStatus.inStock)
      PointyStatusPill(
        label: l10n.aiUiStockUnitDaysOnShelf(days),
        icon: Icons.schedule_rounded,
        color: unit.isAged ? colors.warning : colors.mutedInk,
      ),
    if (unit.consignment)
      PointyStatusPill(
        label: l10n.aiUiStockUnitConsignment,
        icon: Icons.handshake_outlined,
        color: colors.primaryStrong,
      ),
    if (unit.isStopped)
      PointyStatusPill(
        label: unit.availability == 'expired'
            ? l10n.posBatchPickerExpired
            : l10n.stockBatchQuarantinedBadge,
        icon: Icons.block_outlined,
        color: colors.danger,
      ),
  ];
}

class _UnitGlyph extends StatelessWidget {
  const _UnitGlyph({required this.stopped});

  final bool stopped;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final accent = stopped ? colors.danger : colors.primaryStrong;
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: Color.alphaBlend(accent.withValues(alpha: 0.12), colors.surface),
        shape: BoxShape.circle,
      ),
      child: Icon(Icons.qr_code_2_rounded, size: 22, color: accent),
    );
  }
}

/// One article, answered in full: what it is, where, for how much, and how
/// long it has waited — and, when its lot is stopped, that first.
class _FullUnitCard extends StatelessWidget {
  const _FullUnitCard({required this.unit, required this.onTap});

  final AiStockUnitCardData unit;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final theme = Theme.of(context).textTheme;
    final radius = BorderRadius.circular(PointyRadii.card);
    final details = <PointySummaryRow>[
      if (unit.warehouse.isNotEmpty)
        PointySummaryRow(
          label: l10n.aiUiStockUnitWarehouse,
          value: unit.warehouse,
        ),
      if (unit.lot.isNotEmpty)
        PointySummaryRow(label: l10n.aiUiStockUnitLot, value: _ltr(unit.lot)),
      if (unit.expiryDate.isNotEmpty)
        PointySummaryRow(
          label: l10n.aiUiStockUnitExpiry,
          value: aiFormatValue(unit.expiryDate, 'date'),
          valueColor: unit.availability == 'expired' ? colors.danger : null,
        ),
      for (final (label, value) in unit.attributes)
        PointySummaryRow(label: label, value: value),
    ];

    return Material(
      color: colors.surface,
      borderRadius: radius,
      child: InkWell(
        onTap: onTap,
        borderRadius: radius,
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: radius,
            border: Border.all(
              color: unit.isStopped
                  ? colors.danger.withValues(alpha: 0.4)
                  : colors.line,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _UnitGlyph(stopped: unit.isStopped),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          unit.product,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: aiTextStyle(context, 'title', 'strong'),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _ltr(unit.code),
                          style: theme.bodyMedium?.copyWith(
                            color: colors.mutedInk,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (unit.price != null && !unit.isStopped) ...[
                    const SizedBox(width: 12),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          aiFormatValue(unit.price, 'money'),
                          style: aiTextStyle(context, 'numeric', 'strong'),
                        ),
                        Text(
                          l10n.aiUiStockUnitPrice,
                          style: aiTextStyle(context, 'caption', null),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 10),
              Wrap(spacing: 6, runSpacing: 6, children: _pills(context, unit)),
              if (unit.isStopped) ...[
                const SizedBox(height: 12),
                PointyDetailCallout(
                  icon: Icons.do_not_disturb_on_outlined,
                  tone: PointyCalloutTone.danger,
                  title: unit.availability == 'expired'
                      ? l10n.aiUiStockUnitExpired
                      : l10n.aiUiStockUnitRecalled,
                  message: l10n.aiUiStockUnitStopped,
                ),
              ],
              if (details.isNotEmpty) ...[
                const SizedBox(height: 12),
                PointySummaryList(rows: details),
              ],
              const SizedBox(height: 8),
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      l10n.aiUiStockUnitOpen,
                      style: theme.labelLarge?.copyWith(
                        color: colors.primaryStrong,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(width: 4),
                    // Mirrors itself under RTL, so it points the way the
                    // sentence reads.
                    Icon(
                      Icons.arrow_forward_rounded,
                      size: 16,
                      color: colors.primaryStrong,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One article as a row in a short list — several units in one answer.
class _CompactUnitRow extends StatelessWidget {
  const _CompactUnitRow({required this.unit, required this.onTap});

  final AiStockUnitCardData unit;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final subtitle = [
      _ltr(unit.code),
      if (unit.warehouse.isNotEmpty) unit.warehouse,
      if (unit.lot.isNotEmpty) _ltr(unit.lot),
    ].join(' · ');
    return PointyDataRow(
      title: unit.product,
      subtitle: subtitle,
      minHeight: 56,
      leading: _UnitGlyph(stopped: unit.isStopped),
      trailing: unit.price != null && !unit.isStopped
          ? Text(
              aiFormatValue(unit.price, 'money'),
              style: aiTextStyle(context, 'numeric', 'strong'),
            )
          : null,
      badges: _pills(context, unit),
      onTap: onTap,
    );
  }
}

final List<CatalogItem> aiStockUnitItems = <CatalogItem>[aiStockUnitCard];
