// Dev-only sample payloads for lib/dev/reports_preview.dart. Not part of
// the shipping app. Safe to delete together with that harness.
import 'dart:convert';

import 'package:pointy_frontend/src/data/models/report_run.dart';

/// What the preview's fake server answers for a report. Anything without a
/// sample of its own gets the balance sheet.
Map<String, Object?> previewPayload(ReportRunType type) {
  return switch (type) {
    ReportRunType.unitAging => _identified('unit_aging'),
    ReportRunType.unitMargin => _identified('unit_margin'),
    ReportRunType.unitLedger => _identified('unit_ledger'),
    ReportRunType.consignmentLedger => _identified('consignment_ledger'),
    _ => _balanceSheet(),
  };
}

/// A handset that was received and sold — the article the unit-ledger
/// preview opens on.
const previewUnitCode = '356938035643809';

/// A shop's year: its closing column is the legacy statement it printed
/// before Pointy, so the two pages can be read side by side.
Map<String, Object?> _balanceSheet() {
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

  Map<String, Object?> amount(String line, String value) {
    return {'line': line, 'amount': value};
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
    'headline': const [
      'net_position',
      'total_assets',
      'total_liabilities',
      'zakat_due',
    ],
    'summary': const {
      'net_position': '21338.54',
      'total_assets': '45244.63',
      'total_liabilities': '23906.09',
      'zakat_due': '1590.15',
      'opening_net_position': '14860.50',
      'net_position_change': '6478.04',
      'period_result': '10078.04',
      'zakat_base': '63605.98',
    },
    'period': const {'start_date': '2026-01-01', 'end_date': '2026-09-23'},
    'sections': [
      section(
        'balance_assets',
        pairColumns,
        pairTypes,
        [
          pair('stock_at_cost', '31050.00', '35412.56'),
          pair('cash_and_bank', '6480.50', '9219.75'),
          pair('customer_receivables', '1210.00', '565.00'),
          pair('employee_loans', '0.00', '47.32'),
        ],
        totals: const {
          'opening_balance': '38740.50',
          'closing_balance': '45244.63',
          'change': '6504.13',
        },
      ),
      section(
        'balance_liabilities',
        pairColumns,
        pairTypes,
        [
          pair('supplier_payables', '14020.00', '12215.93'),
          pair('employee_payables', '9860.00', '11690.16'),
        ],
        totals: const {
          'opening_balance': '23880.00',
          'closing_balance': '23906.09',
          'change': '26.09',
        },
      ),
      section('balance_net', pairColumns, pairTypes, [
        pair('total_assets', '38740.50', '45244.63'),
        pair('total_liabilities', '23880.00', '23906.09'),
        pair('net_position', '14860.50', '21338.54'),
      ]),
      section('net_position_movement', amountColumns, amountTypes, [
        amount('opening_net_position', '14860.50'),
        amount('outside_money_added', '0.00'),
        amount('outside_money_withdrawn', '-3600.00'),
        amount('period_result', '10078.04'),
        amount('closing_net_position', '21338.54'),
      ]),
      section('zakat', amountColumns, amountTypes, [
        amount('stock_at_selling_price', '77680.00'),
        amount('cash_and_bank', '9219.75'),
        amount('customer_receivables', '565.00'),
        amount('employee_loans', '47.32'),
        amount('zakat_assets_total', '87512.07'),
        amount('zakat_liabilities', '-23906.09'),
        amount('zakat_base', '63605.98'),
        amount('zakat_due', '1590.15'),
      ]),
    ],
    'notes': const [
      {
        'code': 'balance_positions',
        'args': {'opening': '2025-12-31', 'closing': '2026-09-23'},
      },
      {'code': 'balance_stock_at_cost'},
      {'code': 'balance_net_is_equity'},
      {'code': 'period_result_basis'},
      {'code': 'balances_are_derived'},
      {'code': 'zakat_basis'},
      {'code': 'zakat_conditions'},
      {'code': 'period_open'},
    ],
    'audit': const {'row_count': 26, 'truncated': false, 'omitted_count': 0},
    'generated_at': '2026-09-23T10:00:00Z',
  };
}

Map<String, Object?> _identified(String key) {
  final all = jsonDecode(_identifiedPayloads) as Map<String, Object?>;
  return (all[key]! as Map).cast<String, Object?>();
}

/// The four identified-stock reports as the backend built them for a small
/// phone shop: three models received, devices standing 12 to 200 days, five
/// sold (one at a loss), and two consignors — one paid a fixed sum, one a
/// share of the price.
const _identifiedPayloads = r'''
{
 "unit_aging": {
  "summary": {
   "unit_count": 6,
   "capital_on_shelf": "3720.00",
   "stale_unit_count": 2,
   "stale_capital": "1070.00",
   "oldest_days": 200
  },
  "sections": [
   {
    "key": "summary",
    "columns": [
     "metric",
     "value"
    ],
    "column_types": {
     "metric": "label",
     "value": "text"
    },
    "rows": [
     {
      "metric": "unit_count",
      "value": 6
     },
     {
      "metric": "capital_on_shelf",
      "value": "3720.00"
     },
     {
      "metric": "stale_unit_count",
      "value": 2
     },
     {
      "metric": "oldest_days",
      "value": 200
     },
     {
      "metric": "stale_capital",
      "value": "1070.00"
     }
    ],
    "metadata": {
     "returned_count": 5,
     "total_count": 5,
     "omitted_count": 0,
     "truncated": false
    }
   },
   {
    "key": "aging_buckets",
    "columns": [
     "bucket",
     "unit_count",
     "capital",
     "consigned_count"
    ],
    "column_types": {
     "bucket": "label",
     "unit_count": "count",
     "capital": "money",
     "consigned_count": "count"
    },
    "rows": [
     {
      "bucket": "0-30",
      "unit_count": 2,
      "capital": "1000.00",
      "consigned_count": 1
     },
     {
      "bucket": "30-60",
      "unit_count": 1,
      "capital": "650.00",
      "consigned_count": 0
     },
     {
      "bucket": "60-90",
      "unit_count": 1,
      "capital": "1000.00",
      "consigned_count": 0
     },
     {
      "bucket": "90-180",
      "unit_count": 1,
      "capital": "650.00",
      "consigned_count": 0
     },
     {
      "bucket": "180+",
      "unit_count": 1,
      "capital": "420.00",
      "consigned_count": 0
     }
    ],
    "metadata": {
     "returned_count": 5,
     "total_count": 5,
     "omitted_count": 0,
     "truncated": false
    },
    "totals": {
     "shown": {
      "unit_count": 6,
      "capital": "3720.00",
      "consigned_count": 1
     },
     "full": {
      "unit_count": 6,
      "capital": "3720.00",
      "consigned_count": 1
     }
    }
   },
   {
    "key": "aging_units",
    "columns": [
     "code",
     "product_name",
     "days_held",
     "capital",
     "asking_price",
     "is_consignment"
    ],
    "column_types": {
     "code": "text",
     "product_name": "text",
     "days_held": "count",
     "capital": "money",
     "asking_price": "money",
     "is_consignment": "choice"
    },
    "rows": [
     {
      "code": "866552041234575",
      "product_name": "Redmi Note 13",
      "days_held": 200,
      "capital": "420.00",
      "asking_price": "600.00",
      "is_consignment": false
     },
     {
      "code": "352099001761507",
      "product_name": "Galaxy A54",
      "days_held": 130,
      "capital": "650.00",
      "asking_price": "900.00",
      "is_consignment": false
     },
     {
      "code": "356938035643825",
      "product_name": "iPhone 13 128GB",
      "days_held": 75,
      "capital": "1000.00",
      "asking_price": "1500.00",
      "is_consignment": false
     },
     {
      "code": "352099001761499",
      "product_name": "Galaxy A54",
      "days_held": 35,
      "capital": "650.00",
      "asking_price": "900.00",
      "is_consignment": false
     },
     {
      "code": "354821099887774",
      "product_name": "Galaxy S21 مستعمل",
      "days_held": 20,
      "capital": "0.00",
      "asking_price": "950.00",
      "is_consignment": true
     },
     {
      "code": "356938035643817",
      "product_name": "iPhone 13 128GB",
      "days_held": 12,
      "capital": "1000.00",
      "asking_price": "1500.00",
      "is_consignment": false
     }
    ],
    "metadata": {
     "returned_count": 6,
     "total_count": 6,
     "omitted_count": 0,
     "truncated": false,
     "limit": 120
    },
    "totals": {
     "shown": {
      "capital": "3720.00"
     },
     "full": {
      "capital": "3720.00"
     }
    }
   }
  ],
  "notes": [
   {
    "code": "aging_counts_consignment"
   },
   {
    "code": "aging_capital_excludes_consignment"
   },
   {
    "code": "period_open"
   }
  ],
  "report_type": "unit_aging",
  "category": "inventory",
  "headline": [
   "unit_count",
   "capital_on_shelf",
   "stale_unit_count",
   "oldest_days"
  ],
  "period": {
   "start_date": "2026-09-01",
   "end_date": "2026-09-23",
   "preset": "month",
   "granularity": "summary",
   "day_count": 23
  },
  "generated_at": "2026-09-23T02:33:37.345533+00:00",
  "audit": {
   "row_count": 16,
   "truncated": false,
   "omitted_count": 0,
   "sections": [
    {
     "key": "summary",
     "returned_count": 5,
     "total_count": 5,
     "omitted_count": 0,
     "truncated": false
    },
    {
     "key": "aging_buckets",
     "returned_count": 5,
     "total_count": 5,
     "omitted_count": 0,
     "truncated": false
    },
    {
     "key": "aging_units",
     "returned_count": 6,
     "total_count": 6,
     "omitted_count": 0,
     "truncated": false,
     "limit": 120
    }
   ]
  }
 },
 "unit_margin": {
  "summary": {
   "units_sold": 5,
   "revenue": "4830.00",
   "cost": "3630.00",
   "gross_profit": "1200.00",
   "loss_making_units": 1
  },
  "sections": [
   {
    "key": "summary",
    "columns": [
     "metric",
     "value"
    ],
    "column_types": {
     "metric": "label",
     "value": "text"
    },
    "rows": [
     {
      "metric": "units_sold",
      "value": 5
     },
     {
      "metric": "revenue",
      "value": "4830.00"
     },
     {
      "metric": "gross_profit",
      "value": "1200.00"
     },
     {
      "metric": "loss_making_units",
      "value": 1
     },
     {
      "metric": "cost",
      "value": "3630.00"
     }
    ],
    "metadata": {
     "returned_count": 5,
     "total_count": 5,
     "omitted_count": 0,
     "truncated": false
    }
   },
   {
    "key": "unit_margin",
    "columns": [
     "code",
     "product_name",
     "sold_at",
     "sold_price",
     "unit_cost",
     "refurb_cost",
     "profit",
     "is_consignment"
    ],
    "column_types": {
     "code": "text",
     "product_name": "text",
     "sold_at": "datetime",
     "sold_price": "money",
     "unit_cost": "money",
     "refurb_cost": "money",
     "profit": "money",
     "is_consignment": "choice"
    },
    "rows": [
     {
      "code": "354821099887766",
      "product_name": "Galaxy S21 مستعمل",
      "sold_at": "2026-09-23T02:33:37.235537+00:00",
      "sold_price": "950.00",
      "unit_cost": "760.00",
      "refurb_cost": "0.00",
      "profit": "190.00",
      "is_consignment": true
     },
     {
      "code": "353045112233445",
      "product_name": "iPhone 12 مستعمل",
      "sold_at": "2026-09-23T02:33:37.113516+00:00",
      "sold_price": "1100.00",
      "unit_cost": "800.00",
      "refurb_cost": "0.00",
      "profit": "300.00",
      "is_consignment": true
     },
     {
      "code": "866552041234567",
      "product_name": "Redmi Note 13",
      "sold_at": "2026-09-23T02:33:37.008737+00:00",
      "sold_price": "400.00",
      "unit_cost": "420.00",
      "refurb_cost": "0.00",
      "profit": "-20.00",
      "is_consignment": false
     },
     {
      "code": "352099001761481",
      "product_name": "Galaxy A54",
      "sold_at": "2026-09-23T02:33:36.913983+00:00",
      "sold_price": "880.00",
      "unit_cost": "650.00",
      "refurb_cost": "0.00",
      "profit": "230.00",
      "is_consignment": false
     },
     {
      "code": "356938035643809",
      "product_name": "iPhone 13 128GB",
      "sold_at": "2026-09-23T02:33:36.827065+00:00",
      "sold_price": "1500.00",
      "unit_cost": "1000.00",
      "refurb_cost": "0.00",
      "profit": "500.00",
      "is_consignment": false
     }
    ],
    "metadata": {
     "returned_count": 5,
     "total_count": 5,
     "omitted_count": 0,
     "truncated": false,
     "limit": 120
    },
    "totals": {
     "shown": {
      "sold_price": "4830.00",
      "unit_cost": "3630.00",
      "refurb_cost": "0.00",
      "profit": "1200.00"
     },
     "full": {
      "sold_price": "4830.00",
      "unit_cost": "3630.00",
      "refurb_cost": "0.00",
      "profit": "1200.00"
     }
    }
   }
  ],
  "notes": [
   {
    "code": "unit_margin_cost_includes_refurb"
   },
   {
    "code": "period_open"
   }
  ],
  "report_type": "unit_margin",
  "category": "inventory",
  "headline": [
   "units_sold",
   "revenue",
   "gross_profit",
   "loss_making_units"
  ],
  "period": {
   "start_date": "2026-09-01",
   "end_date": "2026-09-23",
   "preset": "month",
   "granularity": "summary",
   "day_count": 23
  },
  "generated_at": "2026-09-23T02:33:37.365166+00:00",
  "audit": {
   "row_count": 10,
   "truncated": false,
   "omitted_count": 0,
   "sections": [
    {
     "key": "summary",
     "returned_count": 5,
     "total_count": 5,
     "omitted_count": 0,
     "truncated": false
    },
    {
     "key": "unit_margin",
     "returned_count": 5,
     "total_count": 5,
     "omitted_count": 0,
     "truncated": false,
     "limit": 120
    }
   ]
  }
 },
 "unit_ledger": {
  "summary": {
   "spell_count": 1,
   "event_count": 2,
   "status": "sold",
   "cost": "1000.00"
  },
  "sections": [
   {
    "key": "summary",
    "columns": [
     "metric",
     "value"
    ],
    "column_types": {
     "metric": "label",
     "value": "text"
    },
    "rows": [
     {
      "metric": "status",
      "value": "sold"
     },
     {
      "metric": "spell_count",
      "value": 1
     },
     {
      "metric": "event_count",
      "value": 2
     },
     {
      "metric": "cost",
      "value": "1000.00"
     }
    ],
    "metadata": {
     "returned_count": 4,
     "total_count": 4,
     "omitted_count": 0,
     "truncated": false
    }
   },
   {
    "key": "unit_ledger",
    "columns": [
     "posting_at",
     "voucher_type",
     "direction",
     "warehouse",
     "batch",
     "rate"
    ],
    "column_types": {
     "posting_at": "datetime",
     "voucher_type": "label",
     "direction": "label",
     "warehouse": "text",
     "batch": "text",
     "rate": "money"
    },
    "rows": [
     {
      "posting_at": "2026-09-23T02:33:36.618317+00:00",
      "voucher_type": "purchase_receipt",
      "direction": "in",
      "warehouse": "المعرض",
      "batch": "",
      "rate": "1000.00"
     },
     {
      "posting_at": "2026-09-23T02:33:36.833247+00:00",
      "voucher_type": "sale",
      "direction": "out",
      "warehouse": "المعرض",
      "batch": "",
      "rate": "1000.00"
     }
    ],
    "metadata": {
     "returned_count": 2,
     "total_count": 2,
     "omitted_count": 0,
     "truncated": false
    }
   }
  ],
  "notes": [
   {
    "code": "unit_ledger_is_one_article"
   },
   {
    "code": "period_open"
   }
  ],
  "report_type": "unit_ledger",
  "category": "inventory",
  "headline": [
   "status",
   "spell_count",
   "event_count"
  ],
  "period": {
   "start_date": "2026-09-01",
   "end_date": "2026-09-23",
   "preset": "month",
   "granularity": "summary",
   "day_count": 23
  },
  "generated_at": "2026-09-23T02:33:37.381270+00:00",
  "audit": {
   "row_count": 6,
   "truncated": false,
   "omitted_count": 0,
   "sections": [
    {
     "key": "summary",
     "returned_count": 4,
     "total_count": 4,
     "omitted_count": 0,
     "truncated": false
    },
    {
     "key": "unit_ledger",
     "returned_count": 2,
     "total_count": 2,
     "omitted_count": 0,
     "truncated": false
    }
   ]
  }
 },
 "consignment_ledger": {
  "summary": {
   "consignment_stock_value": "0.00",
   "consignor_payable": "1560.00",
   "consignor_receivable": "0.00",
   "shop_commission": "490.00",
   "custody_unit_count": 1,
   "custody_declared_value": "850.00"
  },
  "sections": [
   {
    "key": "summary",
    "columns": [
     "metric",
     "value"
    ],
    "column_types": {
     "metric": "label",
     "value": "text"
    },
    "rows": [
     {
      "metric": "consignor_payable",
      "value": "1560.00"
     },
     {
      "metric": "shop_commission",
      "value": "490.00"
     },
     {
      "metric": "custody_unit_count",
      "value": 1
     },
     {
      "metric": "custody_declared_value",
      "value": "850.00"
     },
     {
      "metric": "consignment_stock_value",
      "value": "0.00"
     },
     {
      "metric": "consignor_receivable",
      "value": "0.00"
     }
    ],
    "metadata": {
     "returned_count": 6,
     "total_count": 6,
     "omitted_count": 0,
     "truncated": false
    }
   },
   {
    "key": "consignment_payables",
    "columns": [
     "consignor",
     "code",
     "product_name",
     "sold_at",
     "payout_due",
     "days_waiting"
    ],
    "column_types": {
     "consignor": "text",
     "code": "text",
     "product_name": "text",
     "sold_at": "datetime",
     "payout_due": "money",
     "days_waiting": "count"
    },
    "rows": [
     {
      "consignor": "سالم الورفلي",
      "code": "353045112233445",
      "product_name": "iPhone 12 مستعمل",
      "sold_at": "2026-09-23T02:33:37.113516+00:00",
      "payout_due": "800.00",
      "days_waiting": 0
     },
     {
      "consignor": "أحمد المبروك",
      "code": "354821099887766",
      "product_name": "Galaxy S21 مستعمل",
      "sold_at": "2026-09-23T02:33:37.235537+00:00",
      "payout_due": "760.00",
      "days_waiting": 0
     }
    ],
    "metadata": {
     "returned_count": 2,
     "total_count": 2,
     "omitted_count": 0,
     "truncated": false
    },
    "totals": {
     "shown": {
      "payout_due": "1560.00"
     },
     "full": {
      "payout_due": "1560.00"
     }
    }
   },
   {
    "key": "consignment_sales",
    "columns": [
     "consignor",
     "code",
     "product_name",
     "sold_at",
     "sold_price",
     "payout",
     "commission",
     "paid"
    ],
    "column_types": {
     "consignor": "text",
     "code": "text",
     "product_name": "text",
     "sold_at": "datetime",
     "sold_price": "money",
     "payout": "money",
     "commission": "money",
     "paid": "choice"
    },
    "rows": [
     {
      "consignor": "أحمد المبروك",
      "code": "354821099887766",
      "product_name": "Galaxy S21 مستعمل",
      "sold_at": "2026-09-23T02:33:37.235537+00:00",
      "sold_price": "950.00",
      "payout": "760.00",
      "commission": "190.00",
      "paid": false
     },
     {
      "consignor": "سالم الورفلي",
      "code": "353045112233445",
      "product_name": "iPhone 12 مستعمل",
      "sold_at": "2026-09-23T02:33:37.113516+00:00",
      "sold_price": "1100.00",
      "payout": "800.00",
      "commission": "300.00",
      "paid": false
     }
    ],
    "metadata": {
     "returned_count": 2,
     "total_count": 2,
     "omitted_count": 0,
     "truncated": false
    },
    "totals": {
     "shown": {
      "sold_price": "2050.00",
      "payout": "1560.00",
      "commission": "490.00"
     },
     "full": {
      "sold_price": "2050.00",
      "payout": "1560.00",
      "commission": "490.00"
     }
    }
   }
  ],
  "notes": [
   {
    "code": "consignment_stock_value_is_zero"
   },
   {
    "code": "consignment_payable_counts_credit_sales"
   },
   {
    "code": "period_open"
   }
  ],
  "report_type": "consignment_ledger",
  "category": "inventory",
  "headline": [
   "consignor_payable",
   "shop_commission",
   "custody_unit_count",
   "custody_declared_value"
  ],
  "period": {
   "start_date": "2026-09-01",
   "end_date": "2026-09-23",
   "preset": "month",
   "granularity": "summary",
   "day_count": 23
  },
  "generated_at": "2026-09-23T02:33:37.424848+00:00",
  "audit": {
   "row_count": 10,
   "truncated": false,
   "omitted_count": 0,
   "sections": [
    {
     "key": "summary",
     "returned_count": 6,
     "total_count": 6,
     "omitted_count": 0,
     "truncated": false
    },
    {
     "key": "consignment_payables",
     "returned_count": 2,
     "total_count": 2,
     "omitted_count": 0,
     "truncated": false
    },
    {
     "key": "consignment_sales",
     "returned_count": 2,
     "total_count": 2,
     "omitted_count": 0,
     "truncated": false
    }
   ]
  }
 }
}
''';
