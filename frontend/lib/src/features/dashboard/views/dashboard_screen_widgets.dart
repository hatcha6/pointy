part of 'dashboard_screen.dart';

/// Festive banner announcing today's holiday/special event(s). The event
/// name(s) are the headline (so staff — and Pointy — visibly know the day is
/// special); a single supporting line carries the chrome. Names come localized
/// from the server; multiple same-day events (e.g. Independence Day + Christmas
/// Eve) are joined with a separator.
class _SpecialDayBanner extends StatelessWidget {
  const _SpecialDayBanner({required this.specialDays});

  final List<DashboardSpecialDay> specialDays;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final languageCode = Localizations.localeOf(context).languageCode;
    final names = specialDays
        .map((day) => day.localizedName(languageCode))
        .where((name) => name.isNotEmpty)
        .toList(growable: false);
    if (names.isEmpty) {
      return const SizedBox.shrink();
    }
    return PointyDetailCallout(
      icon: Icons.celebration_outlined,
      title: names.join(' · '),
      message: l10n.dashboardSpecialDayMessage,
    );
  }
}

/// The dashboard's AI daily-brief headline: the model-written summary sentence,
/// shown in the same card chrome as every other dashboard card (so it sits at
/// the top without looking out of place). Tapping it opens the AI chat for the
/// full picture (the brief itself is auto-sent there).
class _AiBriefHeadline extends StatelessWidget {
  const _AiBriefHeadline({required this.brief, required this.onOpen});

  final String brief;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;

    return _DashboardCardShell(
      onTap: onOpen,
      title: l10n.aiDailyBriefLabel,
      trailing: const PointyDisclosureChevron(),
      child: Text(
        brief,
        style: textTheme.bodyLarge?.copyWith(color: colors.ink, height: 1.45),
      ),
    );
  }
}

/// The brief headline's loading placeholder, in the same card chrome — so while
/// the digest generates, the dashboard shows the card is on its way rather than
/// popping in from nothing.
class _AiBriefSkeleton extends StatelessWidget {
  const _AiBriefSkeleton();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return _DashboardCardShell(
      title: l10n.aiDailyBriefLabel,
      child: const PointySkeleton(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PointySkeletonBox(height: 12),
            SizedBox(height: 8),
            PointySkeletonBox(height: 12, width: 220),
          ],
        ),
      ),
    );
  }
}

/// The shared dashboard-card chrome (matching [PointyDetailSection]): a raised
/// white card with an AI-marked header and an optional tap. Used by the brief
/// headline and its skeleton so they're visually identical to the data cards.
class _DashboardCardShell extends StatelessWidget {
  const _DashboardCardShell({
    required this.title,
    required this.child,
    this.onTap,
    this.trailing,
  });

  final String title;
  final Widget child;
  final VoidCallback? onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;

    return DecoratedBox(
      decoration: const BoxDecoration(
        borderRadius: BorderRadius.all(Radius.circular(PointyRadii.card)),
        boxShadow: PointyShadows.raised,
      ),
      child: Card(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: spacing.compactPadding,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(Icons.auto_awesome, color: colors.primaryStrong),
                    SizedBox(width: spacing.sm),
                    Expanded(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    ?trailing,
                  ],
                ),
                SizedBox(height: spacing.sm),
                child,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Wraps a dashboard card with the AI explainer line the digest produced for it:
/// a clickable, tinted one-liner sitting directly under the card. Tapping opens
/// the AI chat to go deeper on that card's topic.
class _AiExplainerCard extends StatelessWidget {
  const _AiExplainerCard({
    required this.card,
    required this.text,
    required this.onTap,
  });

  final Widget card;
  final String text;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final accent = colors.primaryStrong;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        card,
        SizedBox(height: spacing.xs),
        Material(
          color: Color.alphaBlend(
            accent.withValues(alpha: 0.08),
            colors.surface,
          ),
          borderRadius: BorderRadius.circular(PointyRadii.chip),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: spacing.sm,
                vertical: spacing.xs,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.auto_awesome, size: 14, color: accent),
                  SizedBox(width: spacing.xs),
                  Expanded(
                    child: Text(
                      text,
                      style: textTheme.bodySmall?.copyWith(
                        color: colors.primaryDark,
                        height: 1.35,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _SalesTrendChart extends StatelessWidget {
  const _SalesTrendChart({required this.points});

  final List<SalesTrendPoint> points;

  @override
  Widget build(BuildContext context) {
    if (points.every((point) => point.netSales == 0)) {
      return const _EmptyWidgetData();
    }
    final colors = context.pointyColors;
    final maxY = _maxValue(points.map((point) => point.netSales));
    return SizedBox(
      height: 220,
      child: LineChart(
        LineChartData(
          minY: 0,
          maxY: maxY,
          gridData: const FlGridData(show: true),
          borderData: FlBorderData(show: false),
          titlesData: _axisTitles(context),
          lineBarsData: [
            LineChartBarData(
              spots: [
                for (var index = 0; index < points.length; index += 1)
                  FlSpot(index.toDouble(), points[index].netSales),
              ],
              isCurved: true,
              color: colors.primaryStrong,
              barWidth: 3,
              dotData: const FlDotData(show: false),
              belowBarData: BarAreaData(
                show: true,
                color: colors.primaryStrong.withValues(alpha: 0.14),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HourlySalesChart extends StatelessWidget {
  const _HourlySalesChart({required this.points});

  final List<HourlySalesPoint> points;

  @override
  Widget build(BuildContext context) {
    if (points.every((point) => point.netSales == 0)) {
      return const _EmptyWidgetData();
    }
    final visible = points
        .where((point) => point.hour % 3 == 0 || point.netSales > 0)
        .toList(growable: false);
    return SizedBox(
      height: 220,
      child: BarChart(
        BarChartData(
          gridData: const FlGridData(show: true),
          borderData: FlBorderData(show: false),
          titlesData: _axisTitles(context),
          barGroups: [
            for (final point in visible)
              BarChartGroupData(
                x: point.hour,
                barRods: [
                  BarChartRodData(
                    toY: point.netSales,
                    width: 9,
                    borderRadius: BorderRadius.circular(4),
                    color: context.pointyColors.accentAmber,
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

/// What the payment mix is split by.
///
/// The same three methods tell two different stories: cash can be most of the
/// takings while cards are most of the *transactions*, and a shop deciding
/// whether a card terminal is earning its commission needs the second number,
/// not the first. Value is the default because the dashboard around it is about
/// money.
enum _PaymentMixMetric { value, volume }

/// The payment-mix donut, with its value/volume switch.
///
/// Owns the whole card rather than just the chart so the switch sits under the
/// title where it reads as part of the card, and so the legend can restate
/// every figure in whichever unit is selected.
class _PaymentMixCard extends StatefulWidget {
  const _PaymentMixCard({required this.methods});

  final List<PaymentMethodInsight> methods;

  @override
  State<_PaymentMixCard> createState() => _PaymentMixCardState();
}

class _PaymentMixCardState extends State<_PaymentMixCard> {
  _PaymentMixMetric _metric = _PaymentMixMetric.value;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

    return PointyDetailSection(
      title: l10n.dashboardPaymentMixTitle,
      icon: Icons.pie_chart_outline,
      minHeight: 300,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: SegmentedButton<_PaymentMixMetric>(
              showSelectedIcon: false,
              style: const ButtonStyle(
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              segments: [
                ButtonSegment(
                  value: _PaymentMixMetric.value,
                  label: Text(l10n.dashboardPaymentMixByValue),
                ),
                ButtonSegment(
                  value: _PaymentMixMetric.volume,
                  label: Text(l10n.dashboardPaymentMixByCount),
                ),
              ],
              selected: {_metric},
              onSelectionChanged: (selection) =>
                  setState(() => _metric = selection.first),
            ),
          ),
          SizedBox(height: spacing.sm),
          _PaymentMixChart(methods: widget.methods, metric: _metric),
        ],
      ),
    );
  }
}

class _PaymentMixChart extends StatelessWidget {
  const _PaymentMixChart({required this.methods, required this.metric});

  final List<PaymentMethodInsight> methods;
  final _PaymentMixMetric metric;

  /// Below this share a slice is too thin to letter, so it is left bare and
  /// read off the legend instead of being overprinted with its neighbour.
  static const double _minLabelledShare = 0.07;

  double _amount(PaymentMethodInsight method) => switch (metric) {
    _PaymentMixMetric.value => method.total.abs(),
    _PaymentMixMetric.volume => method.count.toDouble(),
  };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final spacing = AdaptiveSpacing.of(context);
    final nonZero = methods
        .where((method) => _amount(method) > 0)
        .toList(growable: false);
    if (nonZero.isEmpty) {
      return const _EmptyWidgetData();
    }
    final palette = _chartColors(context);
    final total = nonZero.fold<double>(0, (sum, m) => sum + _amount(m));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 190,
          child: Stack(
            alignment: Alignment.center,
            children: [
              PieChart(
                PieChartData(
                  centerSpaceRadius: 46,
                  sectionsSpace: 2,
                  sections: [
                    for (var index = 0; index < nonZero.length; index += 1)
                      PieChartSectionData(
                        value: _amount(nonZero[index]),
                        showTitle:
                            total > 0 &&
                            _amount(nonZero[index]) / total >=
                                _minLabelledShare,
                        title:
                            '${((_amount(nonZero[index]) / total) * 100).round()}%',
                        radius: 44,
                        color: palette[index % palette.length],
                        titleStyle: theme.textTheme.labelSmall?.copyWith(
                          color: context.pointyColors.surface,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                  ],
                ),
              ),
              // The hole would otherwise be the emptiest part of the card, and
              // the one number every split implies is the total it splits.
              _PaymentMixTotal(total: total, metric: metric),
            ],
          ),
        ),
        SizedBox(height: spacing.sm),
        Wrap(
          spacing: spacing.md,
          runSpacing: spacing.xs,
          children: [
            for (var index = 0; index < nonZero.length; index += 1)
              _PaymentMixLegendEntry(
                color: palette[index % palette.length],
                label: _paymentMethodLabel(l10n, nonZero[index].method),
                amount: switch (metric) {
                  _PaymentMixMetric.value => formatMoney(
                    nonZero[index].total.abs(),
                  ),
                  _PaymentMixMetric.volume => _formatNumber(
                    nonZero[index].count,
                  ),
                },
              ),
          ],
        ),
      ],
    );
  }
}

class _PaymentMixTotal extends StatelessWidget {
  const _PaymentMixTotal({required this.total, required this.metric});

  final double total;
  final _PaymentMixMetric metric;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = context.pointyColors;

    return SizedBox(
      width: 76,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              switch (metric) {
                // Compact inside the donut's hole: the legend below carries
                // the exact figures, this one only has to give the scale.
                _PaymentMixMetric.value =>
                  '${_compactNumber(total)} $currencySymbol',
                _PaymentMixMetric.volume => _formatNumber(total.round()),
              },
              maxLines: 1,
              style: switch (theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
              )) {
                final style? => PointyTypography.numeric(style),
                null => null,
              },
            ),
          ),
          Text(
            switch (metric) {
              _PaymentMixMetric.value => l10n.dashboardPaymentMixTotalValue,
              _PaymentMixMetric.volume => l10n.dashboardPaymentMixTotalCount,
            },
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: theme.textTheme.labelSmall?.copyWith(color: colors.mutedInk),
          ),
        ],
      ),
    );
  }
}

class _PaymentMixLegendEntry extends StatelessWidget {
  const _PaymentMixLegendEntry({
    required this.color,
    required this.label,
    required this.amount,
  });

  final Color color;
  final String label;
  final String amount;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.pointyColors;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(label, style: theme.textTheme.labelMedium),
        const SizedBox(width: 4),
        Text(
          amount,
          style: switch (theme.textTheme.labelMedium?.copyWith(
            color: colors.mutedInk,
          )) {
            final style? => PointyTypography.numeric(style),
            null => null,
          },
        ),
      ],
    );
  }
}

class _TopProductsList extends StatelessWidget {
  const _TopProductsList({required this.products, this.showProfit = false});

  final List<TopProductInsight> products;

  /// When true the trailing value shows per-product profit instead of revenue.
  final bool showProfit;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    if (products.isEmpty) {
      return const _EmptyWidgetData();
    }
    return _InsightRows(
      rows: [
        for (final product in products)
          _InsightRowData(
            title: product.productName,
            subtitle: product.sku.isEmpty
                ? l10n.dashboardQuantityOnly(product.quantity)
                : l10n.dashboardQuantityWithSku(product.quantity, product.sku),
            trailing: formatMoney(
              showProfit ? product.profit : product.revenue,
            ),
          ),
      ],
    );
  }
}

class _TopCategoriesList extends StatelessWidget {
  const _TopCategoriesList({required this.categories});

  final List<TopCategoryInsight> categories;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    if (categories.isEmpty) {
      return const _EmptyWidgetData();
    }
    return _InsightRows(
      rows: [
        for (final category in categories)
          _InsightRowData(
            title: category.categoryName.isEmpty
                ? l10n.dashboardUncategorizedLabel
                : category.categoryName,
            subtitle: l10n.dashboardQuantityOnly(category.quantity),
            trailing: formatMoney(category.revenue),
          ),
      ],
    );
  }
}

class _RecentOrdersList extends StatelessWidget {
  const _RecentOrdersList({required this.orders});

  final List<RecentOrderInsight> orders;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    if (orders.isEmpty) {
      return const _EmptyWidgetData();
    }
    return _InsightRows(
      rows: [
        for (final order in orders)
          _InsightRowData(
            title: order.receiptNumber,
            subtitle: order.customerName.isEmpty
                ? _orderStatusLabel(l10n, order.status)
                : order.customerName,
            trailing: formatMoney(order.total),
          ),
      ],
    );
  }
}

class _RegisterSummaryView extends StatelessWidget {
  const _RegisterSummaryView({required this.summary});

  final RegisterDashboardSummary summary;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return _InsightRows(
      rows: [
        _InsightRowData(
          title: l10n.dashboardOpenRegistersLabel,
          trailing: _formatNumber(summary.openCount),
        ),
        _InsightRowData(
          title: l10n.dashboardClosedRegistersLabel,
          trailing: _formatNumber(summary.closedCount),
        ),
        _InsightRowData(
          title: l10n.dashboardVarianceRegistersLabel,
          subtitle: formatMoney(summary.varianceTotal),
          trailing: _formatNumber(summary.varianceCount),
        ),
      ],
    );
  }
}

class _TeamSummaryView extends StatelessWidget {
  const _TeamSummaryView({required this.summary});

  final PayrollDashboardSummary summary;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return _InsightRows(
      rows: [
        _InsightRowData(
          title: l10n.dashboardSalaryExpenseMetric,
          trailing: formatMoney(summary.salaryExpense),
        ),
        _InsightRowData(
          title: l10n.dashboardPayrollPaidMetric,
          trailing: formatMoney(summary.paidTotal),
        ),
        if (summary.pendingTotal > 0)
          _InsightRowData(
            title: l10n.dashboardPayrollPendingMetric,
            trailing: formatMoney(summary.pendingTotal),
          ),
        _InsightRowData(
          title: l10n.dashboardActiveEmployeesMetric,
          trailing: _formatNumber(summary.activeEmployeeCount),
        ),
      ],
    );
  }
}

class _CustomersSummaryView extends StatelessWidget {
  const _CustomersSummaryView({required this.summary});

  final CustomersDashboardSummary summary;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return _InsightRows(
      rows: [
        _InsightRowData(
          title: l10n.dashboardActiveCustomersMetric,
          trailing: _formatNumber(summary.activeCustomerCount),
        ),
        _InsightRowData(
          title: l10n.dashboardNewCustomersMetric,
          trailing: _formatNumber(summary.newCustomerCount),
        ),
        _InsightRowData(
          title: l10n.dashboardRepeatCustomersMetric,
          trailing: _formatNumber(summary.repeatCustomerCount),
        ),
        _InsightRowData(
          title: l10n.dashboardCustomersWithSalesMetric,
          trailing: _formatNumber(summary.customersWithSalesCount),
        ),
      ],
    );
  }
}

class _PaymentMethodList extends StatelessWidget {
  const _PaymentMethodList({required this.methods});

  final List<PaymentMethodInsight> methods;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    if (methods.isEmpty) {
      return const _EmptyWidgetData();
    }
    return _InsightRows(
      rows: [
        for (final method in methods)
          _InsightRowData(
            title: _paymentMethodLabel(l10n, method.method),
            subtitle: l10n.dashboardPaymentMethodCount(method.count),
            trailing: formatMoney(method.total),
          ),
      ],
    );
  }
}

class _StockItemList extends StatelessWidget {
  const _StockItemList({required this.items});

  final List<StockItemInsight> items;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    if (items.isEmpty) {
      return const _EmptyWidgetData();
    }
    return _InsightRows(
      rows: [
        for (final item in items)
          _InsightRowData(
            title: item.productName,
            subtitle: l10n.dashboardStockItemSubtitle(
              item.sku,
              item.reorderLevel,
              item.quantityExpected,
            ),
            trailing: _formatNumber(item.quantityOnHand),
          ),
      ],
    );
  }
}

class _OverduePurchaseList extends StatelessWidget {
  const _OverduePurchaseList({required this.orders});

  final List<OverduePurchaseInsight> orders;

  @override
  Widget build(BuildContext context) {
    if (orders.isEmpty) {
      return const _EmptyWidgetData();
    }
    return _InsightRows(
      rows: [
        for (final order in orders)
          _InsightRowData(
            title: order.orderNumber,
            subtitle: order.supplierName,
            trailing: formatMoney(order.balanceDue),
          ),
      ],
    );
  }
}

class _SupplierBalanceList extends StatelessWidget {
  const _SupplierBalanceList({required this.balances});

  final List<SupplierBalanceInsight> balances;

  @override
  Widget build(BuildContext context) {
    if (balances.isEmpty) {
      return const _EmptyWidgetData();
    }
    return _InsightRows(
      rows: [
        for (final balance in balances)
          _InsightRowData(
            title: balance.supplierName,
            trailing: formatMoney(balance.netBalance),
          ),
      ],
    );
  }
}

class _TopCustomerList extends StatelessWidget {
  const _TopCustomerList({required this.customers});

  final List<TopCustomerInsight> customers;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    if (customers.isEmpty) {
      return const _EmptyWidgetData();
    }
    return _InsightRows(
      rows: [
        for (final customer in customers)
          _InsightRowData(
            title: customer.customerName.isEmpty
                ? l10n.dashboardAnonymousCustomerLabel
                : customer.customerName,
            subtitle: l10n.dashboardOrderCount(customer.orderCount),
            trailing: formatMoney(customer.salesTotal),
          ),
      ],
    );
  }
}

class _DiscountRuleList extends StatelessWidget {
  const _DiscountRuleList({required this.rules});

  final List<DiscountRuleInsight> rules;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    if (rules.isEmpty) {
      return const _EmptyWidgetData();
    }
    return _InsightRows(
      rows: [
        for (final rule in rules)
          _InsightRowData(
            title: rule.ruleName,
            subtitle: _discountChannelLabel(l10n, rule.channel),
            trailing: formatMoney(rule.discountTotal),
          ),
      ],
    );
  }
}

class _PrintFailureList extends StatelessWidget {
  const _PrintFailureList({required this.failures});

  final List<PrintFailureInsight> failures;

  @override
  Widget build(BuildContext context) {
    if (failures.isEmpty) {
      return const _EmptyWidgetData();
    }
    return _InsightRows(
      rows: [
        for (final failure in failures)
          _InsightRowData(
            title: failure.receiptNumber,
            subtitle: failure.errorMessage,
            trailing: failure.failedAt == null
                ? ''
                : formatDateTime(failure.failedAt!),
          ),
      ],
    );
  }
}

class _InsightRowData {
  const _InsightRowData({
    required this.title,
    this.subtitle,
    this.trailing,
    this.trailingColor,
  });

  final String title;
  final String? subtitle;
  final String? trailing;
  final Color? trailingColor;
}

class _InsightRows extends StatelessWidget {
  const _InsightRows({required this.rows});

  final List<_InsightRowData> rows;

  @override
  Widget build(BuildContext context) {
    final spacing = AdaptiveSpacing.of(context);
    return Column(
      children: [
        for (var index = 0; index < rows.length; index += 1) ...[
          _InsightRow(row: rows[index]),
          if (index < rows.length - 1) SizedBox(height: spacing.xs),
        ],
      ],
    );
  }
}

class _InsightRow extends StatelessWidget {
  const _InsightRow({required this.row});

  final _InsightRowData row;

  @override
  Widget build(BuildContext context) {
    return PointyDataRow(
      title: row.title,
      subtitle: row.subtitle,
      minHeight: 60,
      trailing: row.trailing == null || row.trailing!.isEmpty
          ? null
          : Text(
              row.trailing!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.end,
              style: switch (Theme.of(context).textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w700,
                color: row.trailingColor,
              )) {
                final style? => PointyTypography.numeric(style),
                null => null,
              },
            ),
    );
  }
}

class _EmptyWidgetData extends StatelessWidget {
  const _EmptyWidgetData();

  @override
  Widget build(BuildContext context) {
    return PointyEmptyState(
      icon: Icons.insights_outlined,
      title: AppLocalizations.of(context)!.dashboardNoWidgetData,
    );
  }
}

FlTitlesData _axisTitles(BuildContext context) {
  final textStyle = Theme.of(context).textTheme.labelSmall;
  return FlTitlesData(
    topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
    rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
    leftTitles: AxisTitles(
      sideTitles: SideTitles(
        showTitles: true,
        reservedSize: 42,
        getTitlesWidget: (value, meta) {
          return Text(
            _compactNumber(value),
            style: textStyle,
            textAlign: TextAlign.center,
          );
        },
      ),
    ),
    bottomTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
  );
}

double _maxValue(Iterable<double> values) {
  final max = values.fold<double>(0, (current, value) {
    return value > current ? value : current;
  });
  return max <= 0 ? 1 : max * 1.25;
}

/// Categorical series colours, ordered so that the first few are the ones a
/// reader can actually tell apart. The two greens used to sit side by side,
/// which made a three-method payment mix look like two slices and a sliver of
/// the same colour; the neutral now separates them.
List<Color> _chartColors(BuildContext context) {
  final colors = context.pointyColors;
  return [
    colors.primaryStrong,
    colors.accentAmber,
    colors.mutedInk,
    colors.primaryDark,
    colors.warning,
    colors.danger,
  ];
}

Color _changeColor(BuildContext context, double value) {
  final colors = context.pointyColors;
  if (value < 0) {
    return colors.danger;
  }
  if (value > 0) {
    return colors.success;
  }
  return colors.mutedInk;
}

// Hoisted so the ICU locale data is parsed once, not rebuilt on every call
// (these format the dashboard's metric tiles and every insight-list row).
final NumberFormat _decimalFormat = NumberFormat.decimalPattern('ar');
final NumberFormat _compactFormat = NumberFormat.compact(locale: 'ar');

String _formatNumber(num value) => _decimalFormat.format(value);

String _formatPercent(double value) => '${value.toStringAsFixed(2)}%';

String _formatChange(double value) {
  final prefix = value > 0 ? '+' : '';
  return '$prefix${value.toStringAsFixed(2)}%';
}

String _compactNumber(double value) => _compactFormat.format(value);

String _paymentMethodLabel(AppLocalizations l10n, String method) {
  return switch (method) {
    'cash' => l10n.paymentMethodCash,
    'card' => l10n.paymentMethodCard,
    'transfer' => l10n.paymentMethodTransfer,
    'salary_deduction' => l10n.paymentMethodSalaryDeduction,
    'account_credit' => l10n.paymentMethodAccountCredit,
    _ => method,
  };
}

String _orderStatusLabel(AppLocalizations l10n, String status) {
  return switch (status) {
    'open' => l10n.dashboardOrderStatusOpen,
    'paid' => l10n.dashboardOrderStatusPaid,
    'void' => l10n.dashboardOrderStatusVoid,
    _ => status,
  };
}

String _discountChannelLabel(AppLocalizations l10n, String channel) {
  return switch (channel) {
    'sales' => l10n.discountChannelSales,
    'purchasing' => l10n.discountChannelPurchasing,
    'both' => l10n.discountChannelBoth,
    _ => channel,
  };
}

/// Content-shaped placeholder for the dashboard's first paint: a toolbar bar
/// and a responsive grid of metric-tile skeletons, matching the real layout.
class _DashboardSkeleton extends StatelessWidget {
  const _DashboardSkeleton();

  @override
  Widget build(BuildContext context) {
    final spacing = AdaptiveSpacing.of(context);
    return SingleChildScrollView(
      physics: const NeverScrollableScrollPhysics(),
      padding: spacing.pagePadding,
      child: AdaptiveMaxWidth(
        width: AppContentWidth.workspace,
        child: PointySkeleton(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: const [
                  PointySkeletonBox(width: 180, height: 30),
                  Spacer(),
                  PointySkeletonBox(width: 120, height: 36),
                ],
              ),
              SizedBox(height: spacing.lg),
              LayoutBuilder(
                builder: (context, constraints) {
                  final columns = constraints.maxWidth >= 900
                      ? 3
                      : constraints.maxWidth >= 560
                      ? 2
                      : 1;
                  final gap = spacing.gutter;
                  final tileWidth =
                      (constraints.maxWidth - gap * (columns - 1)) / columns;
                  return Wrap(
                    spacing: gap,
                    runSpacing: gap,
                    children: [
                      for (var i = 0; i < 6; i++)
                        SizedBox(
                          width: tileWidth,
                          child: const _MetricSkeletonTile(),
                        ),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MetricSkeletonTile extends StatelessWidget {
  const _MetricSkeletonTile();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: PointyDimensions.metricTileMinHeight,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        border: Border.all(color: context.pointyColors.line),
        borderRadius: BorderRadius.circular(PointyRadii.card),
      ),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          PointySkeletonBox(width: 90, height: 12),
          PointySkeletonBox(width: 130, height: 26),
          PointySkeletonBox(width: 70, height: 12),
        ],
      ),
    );
  }
}
