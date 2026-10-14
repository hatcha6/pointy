import 'package:flutter/material.dart';
import 'package:genui/genui.dart';
import 'package:json_schema_builder/json_schema_builder.dart';

import '../../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/charts/charts.dart';
import '../../../../shared/components/components.dart';
import '../../../../shared/design/design.dart';
import '../ai_ui_support.dart';

/// Designer-built POS cards. The server composes these from real records when
/// the assistant calls show_product / show_customer / show_sales_summary; the
/// model never lays them out or types their figures.

/// Stock that lasts a week or less at the current pace is worth a warning.
const int _runningOutDays = 7;

int? _int(Object? value) =>
    value is num ? value.toInt() : int.tryParse('${value ?? ''}');

double? _double(Object? value) =>
    value is num ? value.toDouble() : double.tryParse('${value ?? ''}');

/// LTR isolate for codes inside Arabic runs.
String _ltr(String value) => '\u2066$value\u2069';

void _open(CatalogItemContext itemContext, String kind, int id) =>
    aiDispatchAction(itemContext, {
      'event': {
        'name': 'navigate:$kind',
        'context': {'link': 'pointy://$kind/$id'},
      },
    });

/// The shell every POS card shares: a glyph, a title line, an optional
/// headline figure, the body, and the "open" affordance.
class _CardShell extends StatelessWidget {
  const _CardShell({
    required this.icon,
    required this.title,
    this.subtitle = '',
    this.headline,
    this.headlineCaption,
    this.badges = const [],
    required this.body,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final String? headline;
  final String? headlineCaption;
  final List<Widget> badges;
  final List<Widget> body;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final theme = Theme.of(context).textTheme;
    final radius = BorderRadius.circular(PointyRadii.card);

    final content = Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: radius,
        border: Border.all(color: colors.line),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: Color.alphaBlend(
                    colors.primaryStrong.withValues(alpha: 0.12),
                    colors.surface,
                  ),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, size: 22, color: colors.primaryStrong),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: aiTextStyle(context, 'title', 'strong'),
                    ),
                    if (subtitle.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.bodyMedium?.copyWith(
                          color: colors.mutedInk,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (headline != null) ...[
                const SizedBox(width: 12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      headline!,
                      style: aiTextStyle(context, 'numeric', 'strong'),
                    ),
                    if (headlineCaption != null)
                      Text(
                        headlineCaption!,
                        style: aiTextStyle(context, 'caption', null),
                      ),
                  ],
                ),
              ],
            ],
          ),
          if (badges.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(spacing: 6, runSpacing: 6, children: badges),
          ],
          ...body,
          if (onTap != null) ...[
            const SizedBox(height: 8),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    l10n.aiUiCardOpen,
                    style: theme.labelLarge?.copyWith(
                      color: colors.primaryStrong,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    Icons.arrow_forward_rounded,
                    size: 16,
                    color: colors.primaryStrong,
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );

    return Material(
      color: colors.surface,
      borderRadius: radius,
      child: onTap == null
          ? content
          : InkWell(onTap: onTap, borderRadius: radius, child: content),
    );
  }
}

// ── ProductCard ─────────────────────────────────────────────────────────────

/// The product card's data, read once. Public for the preview and tests.
class AiProductCardData {
  const AiProductCardData({
    required this.productId,
    required this.name,
    this.price,
    this.code = '',
    this.category = '',
    this.stock,
    this.soldLast30Days,
    this.daysOfCover,
    this.isService = false,
    this.active = true,
  });

  final int productId;
  final String name;
  final double? price;
  final String code;
  final String category;
  final double? stock;
  final double? soldLast30Days;
  final int? daysOfCover;
  final bool isService;
  final bool active;

  bool get isOut => !isService && stock != null && stock! <= 0;
  bool get isRunningOut =>
      !isOut && daysOfCover != null && daysOfCover! <= _runningOutDays;

  factory AiProductCardData.fromMap(Map<String, Object?> data) =>
      AiProductCardData(
        productId: _int(data['productId']) ?? 0,
        name: aiString(data, 'name'),
        price: _double(data['price']),
        code: aiString(data, 'code'),
        category: aiString(data, 'category'),
        stock: _double(data['stock']),
        soldLast30Days: _double(data['soldLast30Days']),
        daysOfCover: _int(data['daysOfCover']),
        isService: data['isService'] == true,
        active: data['active'] != false,
      );
}

class AiProductCardView extends StatelessWidget {
  const AiProductCardView({super.key, required this.product, this.onTap});

  final AiProductCardData product;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final sold = product.soldLast30Days;
    final subtitle = [
      if (product.code.isNotEmpty) _ltr(product.code),
      if (product.category.isNotEmpty) product.category,
    ].join(' · ');
    return _CardShell(
      icon: Icons.inventory_2_outlined,
      title: product.name,
      subtitle: subtitle,
      headline: product.price == null
          ? null
          : aiFormatValue(product.price, 'money'),
      headlineCaption: l10n.aiUiProductPrice,
      badges: [
        if (!product.active)
          PointyStatusPill(
            label: l10n.aiUiProductInactive,
            icon: Icons.pause_circle_outline,
            color: colors.mutedInk,
          ),
        if (product.isService)
          PointyStatusPill(
            label: l10n.aiUiProductService,
            color: colors.primaryStrong,
          ),
        if (product.isOut)
          PointyStatusPill(
            label: l10n.aiUiProductOutOfStock,
            icon: Icons.remove_shopping_cart_outlined,
            color: colors.danger,
          )
        else if (product.isRunningOut)
          PointyStatusPill(
            label: l10n.aiUiProductRunningOut,
            icon: Icons.schedule_rounded,
            color: colors.warning,
          ),
      ],
      body: [
        const SizedBox(height: 12),
        PointySummaryList(
          rows: [
            if (product.stock != null)
              PointySummaryRow(
                label: l10n.aiUiProductStock,
                value: aiFormatValue(product.stock, 'number'),
                valueColor: product.isOut ? colors.danger : null,
              ),
            if (sold != null)
              PointySummaryRow(
                label: l10n.aiUiProductSold30,
                value: sold > 0
                    ? aiFormatValue(sold, 'number')
                    : l10n.aiUiProductNoSales,
              ),
            if (product.daysOfCover != null && !product.isOut)
              PointySummaryRow(
                label: l10n.aiUiProductCoverLabel,
                value: l10n.aiUiProductCover(product.daysOfCover!),
                valueColor: product.isRunningOut ? colors.warning : null,
              ),
          ],
        ),
      ],
      onTap: onTap,
    );
  }
}

final aiProductCard = CatalogItem(
  name: 'ProductCard',
  dataSchema: S.object(
    description:
        'One product. Drawn by the app from show_product; never compose it '
        'yourself.',
    properties: {
      'productId': S.integer(description: 'The product id.'),
      'name': S.string(description: 'Product name.'),
      'price': S.number(description: 'Selling price, in shop money.'),
      'code': S.string(description: 'Barcode or SKU.'),
      'category': S.string(description: 'Category names.'),
      'stock': S.number(description: 'Quantity on hand.'),
      'soldLast30Days': S.number(description: 'Units sold in 30 days.'),
      'daysOfCover': S.integer(
        description: 'Days the stock lasts at the 30-day pace.',
      ),
      'isService': S.boolean(description: 'A service or made-to-order item.'),
      'active': S.boolean(description: 'False when inactive or archived.'),
    },
    required: ['productId', 'name'],
  ),
  exampleData: [
    () => '''
      [{"id": "root", "component": "ProductCard", "productId": 12,
        "name": "قهوة تركي ٢٥٠غ", "price": 18.5, "code": "6281000000012",
        "stock": 14, "soldLast30Days": 62, "daysOfCover": 6}]
    ''',
  ],
  widgetBuilder: (itemContext) {
    final product = AiProductCardData.fromMap(
      itemContext.data as Map<String, Object?>,
    );
    return AiProductCardView(
      product: product,
      onTap: () => _open(itemContext, 'product', product.productId),
    );
  },
);

// ── CustomerCard ────────────────────────────────────────────────────────────

class AiCustomerCardData {
  const AiCustomerCardData({
    required this.customerId,
    required this.name,
    this.phone = '',
    this.segmentLabel = '',
    this.balanceDue,
    this.creditLimit,
    this.lastPurchase = '',
    this.lifetimeSpend,
    this.orderCount,
  });

  final int customerId;
  final String name;
  final String phone;
  final String segmentLabel;
  final double? balanceDue;
  final double? creditLimit;
  final String lastPurchase;
  final double? lifetimeSpend;
  final int? orderCount;

  bool get owes => (balanceDue ?? 0) > 0;
  bool get overLimit =>
      owes &&
      creditLimit != null &&
      creditLimit! > 0 &&
      balanceDue! > creditLimit!;

  factory AiCustomerCardData.fromMap(Map<String, Object?> data) =>
      AiCustomerCardData(
        customerId: _int(data['customerId']) ?? 0,
        name: aiString(data, 'name'),
        phone: aiString(data, 'phone'),
        segmentLabel: aiString(data, 'segmentLabel'),
        balanceDue: _double(data['balanceDue']),
        creditLimit: _double(data['creditLimit']),
        lastPurchase: aiString(data, 'lastPurchase'),
        lifetimeSpend: _double(data['lifetimeSpend']),
        orderCount: _int(data['orderCount']),
      );
}

class AiCustomerCardView extends StatelessWidget {
  const AiCustomerCardView({super.key, required this.customer, this.onTap});

  final AiCustomerCardData customer;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final balance = customer.balanceDue;
    return _CardShell(
      icon: Icons.person_outline_rounded,
      title: customer.name,
      subtitle: customer.phone.isEmpty ? '' : _ltr(customer.phone),
      headline: balance == null
          ? null
          : (customer.owes
                ? aiFormatValue(balance, 'money')
                : l10n.aiUiCustomerNoDebt),
      headlineCaption: customer.owes ? l10n.aiUiCustomerBalance : null,
      badges: [
        if (customer.segmentLabel.isNotEmpty)
          PointyStatusPill(
            label: customer.segmentLabel,
            icon: Icons.star_outline_rounded,
            color: colors.primaryStrong,
          ),
        if (customer.overLimit)
          PointyStatusPill(
            label: l10n.aiUiCustomerOverLimit,
            icon: Icons.warning_amber_outlined,
            color: colors.danger,
          ),
      ],
      body: [
        const SizedBox(height: 12),
        PointySummaryList(
          rows: [
            if (customer.creditLimit != null && customer.creditLimit! > 0)
              PointySummaryRow(
                label: l10n.aiUiCustomerCreditLimit,
                value: aiFormatValue(customer.creditLimit, 'money'),
              ),
            if (customer.lastPurchase.isNotEmpty)
              PointySummaryRow(
                label: l10n.aiUiCustomerLastPurchase,
                value: aiFormatValue(customer.lastPurchase, 'date'),
              ),
            if (customer.lifetimeSpend != null)
              PointySummaryRow(
                label: l10n.aiUiCustomerLifetime,
                value: aiFormatValue(customer.lifetimeSpend, 'money'),
              ),
            if (customer.orderCount != null)
              PointySummaryRow(
                label: l10n.aiUiCustomerOrders,
                value: aiFormatValue(customer.orderCount, 'number'),
              ),
          ],
        ),
      ],
      onTap: onTap,
    );
  }
}

final aiCustomerCard = CatalogItem(
  name: 'CustomerCard',
  dataSchema: S.object(
    description:
        'One customer. Drawn by the app from show_customer; never compose it '
        'yourself.',
    properties: {
      'customerId': S.integer(description: 'The customer id.'),
      'name': S.string(description: 'Full name.'),
      'phone': S.string(description: 'Phone number.'),
      'segment': S.string(description: 'RFM segment key.'),
      'segmentLabel': S.string(description: 'RFM segment, in Arabic.'),
      'balanceDue': S.number(description: 'What they owe now, shop money.'),
      'creditLimit': S.number(description: 'Their credit ceiling.'),
      'lastPurchase': S.string(description: 'Last purchase, YYYY-MM-DD.'),
      'lifetimeSpend': S.number(description: 'Total they have spent.'),
      'orderCount': S.integer(description: 'How many purchases.'),
    },
    required: ['customerId', 'name'],
  ),
  exampleData: [
    () => '''
      [{"id": "root", "component": "CustomerCard", "customerId": 7,
        "name": "سالم الورفلي", "phone": "0912345678",
        "segmentLabel": "عميل وفيّ", "balanceDue": 240, "creditLimit": 500,
        "lastPurchase": "2026-10-02", "lifetimeSpend": 5120, "orderCount": 38}]
    ''',
  ],
  widgetBuilder: (itemContext) {
    final customer = AiCustomerCardData.fromMap(
      itemContext.data as Map<String, Object?>,
    );
    return AiCustomerCardView(
      customer: customer,
      onTap: () => _open(itemContext, 'customer', customer.customerId),
    );
  },
);

// ── SalesSummaryCard ────────────────────────────────────────────────────────

class AiSalesSummaryData {
  const AiSalesSummaryData({
    required this.periodLabel,
    required this.revenue,
    required this.orders,
    this.averageTicket,
    this.revenueChange,
    this.profit,
    this.marginPercent,
    this.trend = const [],
    this.topProducts = const [],
  });

  final String periodLabel;
  final double revenue;
  final int orders;
  final double? averageTicket;
  final double? revenueChange;
  final double? profit;
  final double? marginPercent;
  final List<PointyChartPoint> trend;
  final List<({int id, String name, double revenue})> topProducts;

  factory AiSalesSummaryData.fromMap(Map<String, Object?> data) {
    return AiSalesSummaryData(
      periodLabel: aiString(data, 'periodLabel'),
      revenue: _double(data['revenue']) ?? 0,
      orders: _int(data['orders']) ?? 0,
      averageTicket: _double(data['averageTicket']),
      revenueChange: _double(data['revenueChange']),
      profit: _double(data['profit']),
      marginPercent: _double(data['marginPercent']),
      trend: [
        for (final point in (data['trend'] as List? ?? const <Object?>[]))
          if (point is Map)
            PointyChartPoint(
              label: '${point['label'] ?? ''}',
              value: _double(point['value']) ?? 0,
            ),
      ],
      topProducts: [
        for (final row in (data['topProducts'] as List? ?? const <Object?>[]))
          if (row is Map)
            (
              id: _int(row['productId']) ?? 0,
              name: '${row['name'] ?? ''}',
              revenue: _double(row['revenue']) ?? 0,
            ),
      ],
    );
  }
}

class AiSalesSummaryView extends StatelessWidget {
  const AiSalesSummaryView({super.key, required this.sales, this.onProduct});

  final AiSalesSummaryData sales;
  final ValueChanged<int>? onProduct;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final theme = Theme.of(context).textTheme;
    final change = sales.revenueChange;
    final changeColor = change == null || change == 0
        ? colors.mutedInk
        : (change > 0 ? colors.success : colors.danger);

    return _CardShell(
      icon: Icons.insights_outlined,
      title: sales.periodLabel,
      headline: aiFormatValue(sales.revenue, 'money'),
      headlineCaption: l10n.aiUiSalesRevenue,
      badges: [
        if (change != null)
          PointyStatusPill(
            label: l10n.aiUiSalesVsPrevious(
              // Isolated LTR so the sign stays before the number in RTL.
              _ltr(
                '${change > 0 ? '+' : ''}${aiFormatValue(change, 'percent')}',
              ),
            ),
            icon: change >= 0
                ? Icons.trending_up_rounded
                : Icons.trending_down_rounded,
            color: changeColor,
          ),
      ],
      body: [
        if (sales.orders == 0) ...[
          const SizedBox(height: 12),
          Text(
            l10n.aiUiSalesEmpty,
            style: theme.bodyMedium?.copyWith(color: colors.mutedInk),
          ),
        ] else ...[
          if (sales.trend.length > 1) ...[
            const SizedBox(height: 12),
            PointySparkline(points: sales.trend, height: 52),
          ],
          const SizedBox(height: 12),
          PointySummaryList(
            rows: [
              PointySummaryRow(
                label: l10n.aiUiSalesOrders,
                value: aiFormatValue(sales.orders, 'number'),
              ),
              if (sales.averageTicket != null)
                PointySummaryRow(
                  label: l10n.aiUiSalesAverage,
                  value: aiFormatValue(sales.averageTicket, 'money'),
                ),
              if (sales.profit != null)
                PointySummaryRow(
                  label: l10n.aiUiSalesProfit,
                  value: aiFormatValue(sales.profit, 'money'),
                ),
              if (sales.marginPercent != null)
                PointySummaryRow(
                  label: l10n.aiUiSalesMargin,
                  value: aiFormatValue(sales.marginPercent, 'percent'),
                ),
            ],
          ),
          if (sales.topProducts.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              l10n.aiUiSalesTopProducts,
              style: aiTextStyle(context, 'caption', 'strong'),
            ),
            const SizedBox(height: 4),
            for (final (index, product) in sales.topProducts.indexed)
              PointyDataRow(
                title: product.name,
                minHeight: 40,
                leading: Text(
                  '${index + 1}',
                  style: aiTextStyle(context, 'numeric', 'strong'),
                ),
                trailing: Text(
                  aiFormatValue(product.revenue, 'money'),
                  style: aiTextStyle(context, 'body', 'strong'),
                ),
                onTap: onProduct == null || product.id == 0
                    ? null
                    : () => onProduct!(product.id),
              ),
          ],
        ],
      ],
    );
  }
}

final aiSalesSummaryCard = CatalogItem(
  name: 'SalesSummaryCard',
  dataSchema: S.object(
    description:
        'Sales for one period against the one before it. Drawn by the app '
        'from show_sales_summary; never compose it yourself.',
    properties: {
      'periodLabel': S.string(description: 'The period, in Arabic.'),
      'revenue': S.number(description: 'Revenue, shop money.'),
      'orders': S.integer(description: 'Number of sales.'),
      'averageTicket': S.number(description: 'Average sale, shop money.'),
      'revenueChange': S.number(
        description: 'Percent change against the previous period.',
      ),
      'ordersChange': S.number(description: 'Percent change in sales count.'),
      'profit': S.number(description: 'Profit, reporting roles only.'),
      'marginPercent': S.number(description: 'Margin percent.'),
      'trend': S.list(
        description: 'Revenue per day (or month) across the period.',
        items: S.object(
          properties: {'label': S.string(), 'value': S.number()},
          required: ['label', 'value'],
        ),
      ),
      'topProducts': S.list(
        description: 'Best sellers by revenue.',
        items: S.object(
          properties: {
            'productId': S.integer(),
            'name': S.string(),
            'revenue': S.number(),
            'units': S.number(),
          },
          required: ['name', 'revenue'],
        ),
      ),
    },
    required: ['periodLabel', 'revenue', 'orders'],
  ),
  exampleData: [
    () => '''
      [{"id": "root", "component": "SalesSummaryCard",
        "periodLabel": "هذا الأسبوع", "revenue": 12840, "orders": 214,
        "averageTicket": 60, "revenueChange": 8.4,
        "trend": [{"label": "10-07", "value": 1500},
                  {"label": "10-08", "value": 2100},
                  {"label": "10-09", "value": 1800}],
        "topProducts": [{"productId": 12, "name": "قهوة تركي", "revenue": 1200}]}]
    ''',
  ],
  widgetBuilder: (itemContext) => AiSalesSummaryView(
    sales: AiSalesSummaryData.fromMap(itemContext.data as Map<String, Object?>),
    onProduct: (id) => _open(itemContext, 'product', id),
  ),
);

final List<CatalogItem> aiPosCardItems = <CatalogItem>[
  aiProductCard,
  aiCustomerCard,
  aiSalesSummaryCard,
];
