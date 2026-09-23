/// A balance sheet exactly as `apps/reports/builders/balance_sheet.py` builds
/// it, for the shop in the backend's `test_balance_sheet.py`: the same figures,
/// so the two halves of the feature are tested against one story.
Map<String, Object?> balanceSheetPayload() {
  const pairColumns = ['line', 'opening_balance', 'closing_balance', 'change'];
  const pairTypes = {
    'line': 'label',
    'opening_balance': 'money',
    'closing_balance': 'money',
    'change': 'money',
  };
  const amountColumns = ['line', 'amount'];
  const amountTypes = {'line': 'label', 'amount': 'money'};

  Map<String, Object?> pair(String line, String opening, String closing) {
    final change = (num.parse(closing) - num.parse(opening)).toStringAsFixed(2);
    return {
      'line': line,
      'opening_balance': opening,
      'closing_balance': closing,
      'change': change,
    };
  }

  Map<String, Object?> section(
    String key,
    List<String> columns,
    Map<String, String> types,
    List<Map<String, Object?>> rows, {
    Map<String, Object?>? totals,
  }) {
    return {
      'key': key,
      'columns': columns,
      'column_types': types,
      'rows': rows,
      'metadata': {
        'returned_count': rows.length,
        'total_count': rows.length,
        'omitted_count': 0,
        'truncated': false,
      },
      if (totals != null) 'totals': {'shown': totals, 'full': totals},
    };
  }

  return {
    'report_type': 'balance_sheet',
    'category': 'close',
    'headline': [
      'net_position',
      'total_assets',
      'total_liabilities',
      'zakat_due',
    ],
    'summary': {
      'net_position': '122.00',
      'total_assets': '172.00',
      'total_liabilities': '50.00',
      'zakat_due': '4.25',
      'opening_net_position': '105.00',
      'net_position_change': '17.00',
      'period_result': '-8.00',
      'zakat_base': '170.00',
    },
    'period': {'start_date': '2026-09-16', 'end_date': '2026-09-23'},
    'sections': [
      section(
        'summary',
        const ['metric', 'value'],
        const {'metric': 'label', 'value': 'text'},
        [
          {'metric': 'net_position', 'value': '122.00'},
          {'metric': 'zakat_due', 'value': '4.25'},
        ],
      ),
      section(
        'balance_assets',
        pairColumns,
        pairTypes,
        [
          pair('stock_at_cost', '20.00', '12.00'),
          pair('cash_and_bank', '120.00', '90.00'),
          pair('customer_receivables', '50.00', '50.00'),
          pair('employee_loans', '30.00', '20.00'),
        ],
        totals: {'opening_balance': '220.00', 'closing_balance': '172.00', 'change': '-48.00'},
      ),
      section(
        'balance_liabilities',
        pairColumns,
        pairTypes,
        [
          pair('supplier_payables', '80.00', '50.00'),
          pair('employee_payables', '35.00', '0.00'),
        ],
        totals: {'opening_balance': '115.00', 'closing_balance': '50.00', 'change': '-65.00'},
      ),
      section('balance_net', pairColumns, pairTypes, [
        pair('total_assets', '220.00', '172.00'),
        pair('total_liabilities', '115.00', '50.00'),
        pair('net_position', '105.00', '122.00'),
      ]),
      section('net_position_movement', amountColumns, amountTypes, [
        {'line': 'opening_net_position', 'amount': '105.00'},
        {'line': 'outside_money_added', 'amount': '40.00'},
        {'line': 'outside_money_withdrawn', 'amount': '-15.00'},
        {'line': 'period_result', 'amount': '-8.00'},
        {'line': 'closing_net_position', 'amount': '122.00'},
      ]),
      section('zakat', amountColumns, amountTypes, [
        {'line': 'stock_at_selling_price', 'amount': '60.00'},
        {'line': 'cash_and_bank', 'amount': '90.00'},
        {'line': 'customer_receivables', 'amount': '50.00'},
        {'line': 'employee_loans', 'amount': '20.00'},
        {'line': 'zakat_assets_total', 'amount': '220.00'},
        {'line': 'zakat_liabilities', 'amount': '-50.00'},
        {'line': 'zakat_base', 'amount': '170.00'},
        {'line': 'zakat_due', 'amount': '4.25'},
      ]),
    ],
    'notes': [
      {
        'code': 'balance_positions',
        'args': {'opening': '2026-09-15', 'closing': '2026-09-23'},
      },
      {'code': 'balance_stock_at_cost'},
      {'code': 'balance_net_is_equity'},
      {'code': 'period_result_basis'},
      {'code': 'balances_are_derived'},
      {'code': 'zakat_basis'},
      {'code': 'zakat_conditions'},
      {'code': 'period_open'},
    ],
    'audit': {'row_count': 24, 'truncated': false, 'omitted_count': 0},
    'generated_at': '2026-09-23T10:00:00Z',
  };
}
