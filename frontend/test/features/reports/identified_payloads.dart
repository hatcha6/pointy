import 'dart:convert';

/// The four identified-stock reports exactly as the backend built them.
///
/// Captured from `apps/reports/builders/identified.py` over one small shop:
/// three handsets received at 1000.00, two sold (one at a loss), a third
/// left 120 days on the shelf, and two consignments from سالم, one of them
/// sold. Real payloads rather than hand-written ones, so a label missing for
/// any key the server actually sends fails a test instead of printing بيان.
Map<String, Object?> identifiedPayload(String reportKey) {
  final all = jsonDecode(_payloads) as Map<String, Object?>;
  return (all[reportKey]! as Map).cast<String, Object?>();
}

const _payloads = r'''
{
 "unit_aging": {
  "summary": {
   "unit_count": 2,
   "capital_on_shelf": "1000.00",
   "stale_unit_count": 1,
   "stale_capital": "1000.00",
   "oldest_days": 120
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
      "value": 2
     },
     {
      "metric": "capital_on_shelf",
      "value": "1000.00"
     },
     {
      "metric": "stale_unit_count",
      "value": 1
     },
     {
      "metric": "oldest_days",
      "value": 120
     },
     {
      "metric": "stale_capital",
      "value": "1000.00"
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
      "unit_count": 0,
      "capital": "0.00",
      "consigned_count": 0
     },
     {
      "bucket": "30-60",
      "unit_count": 1,
      "capital": "0.00",
      "consigned_count": 1
     },
     {
      "bucket": "60-90",
      "unit_count": 0,
      "capital": "0.00",
      "consigned_count": 0
     },
     {
      "bucket": "90-180",
      "unit_count": 1,
      "capital": "1000.00",
      "consigned_count": 0
     },
     {
      "bucket": "180+",
      "unit_count": 0,
      "capital": "0.00",
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
      "unit_count": 2,
      "capital": "1000.00",
      "consigned_count": 1
     },
     "full": {
      "unit_count": 2,
      "capital": "1000.00",
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
      "code": "351234567890124",
      "product_name": "iPhone 13",
      "days_held": 120,
      "capital": "1000.00",
      "asking_price": "1500.00",
      "is_consignment": false
     },
     {
      "code": "CONSIGNED-2",
      "product_name": "iPhone 13",
      "days_held": 40,
      "capital": "0.00",
      "asking_price": "1500.00",
      "is_consignment": true
     }
    ],
    "metadata": {
     "returned_count": 2,
     "total_count": 2,
     "omitted_count": 0,
     "truncated": false,
     "limit": 120
    },
    "totals": {
     "shown": {
      "capital": "1000.00"
     },
     "full": {
      "capital": "1000.00"
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
  "generated_at": "2026-09-23T02:25:14.252736+00:00",
  "audit": {
   "row_count": 12,
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
     "returned_count": 2,
     "total_count": 2,
     "omitted_count": 0,
     "truncated": false,
     "limit": 120
    }
   ]
  }
 },
 "unit_margin": {
  "summary": {
   "units_sold": 3,
   "revenue": "3650.00",
   "cost": "2900.00",
   "gross_profit": "750.00",
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
      "value": 3
     },
     {
      "metric": "revenue",
      "value": "3650.00"
     },
     {
      "metric": "gross_profit",
      "value": "750.00"
     },
     {
      "metric": "loss_making_units",
      "value": 1
     },
     {
      "metric": "cost",
      "value": "2900.00"
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
      "code": "CONSIGNED-1",
      "product_name": "iPhone 13",
      "sold_at": "2026-09-23T02:25:14.180366+00:00",
      "sold_price": "1200.00",
      "unit_cost": "900.00",
      "refurb_cost": "0.00",
      "profit": "300.00",
      "is_consignment": true
     },
     {
      "code": "351234567890132",
      "product_name": "iPhone 13",
      "sold_at": "2026-09-23T02:25:14.122901+00:00",
      "sold_price": "950.00",
      "unit_cost": "1000.00",
      "refurb_cost": "0.00",
      "profit": "-50.00",
      "is_consignment": false
     },
     {
      "code": "351234567890116",
      "product_name": "iPhone 13",
      "sold_at": "2026-09-23T02:25:14.068386+00:00",
      "sold_price": "1500.00",
      "unit_cost": "1000.00",
      "refurb_cost": "0.00",
      "profit": "500.00",
      "is_consignment": false
     }
    ],
    "metadata": {
     "returned_count": 3,
     "total_count": 3,
     "omitted_count": 0,
     "truncated": false,
     "limit": 120
    },
    "totals": {
     "shown": {
      "sold_price": "3650.00",
      "unit_cost": "2900.00",
      "refurb_cost": "0.00",
      "profit": "750.00"
     },
     "full": {
      "sold_price": "3650.00",
      "unit_cost": "2900.00",
      "refurb_cost": "0.00",
      "profit": "750.00"
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
  "generated_at": "2026-09-23T02:25:14.264399+00:00",
  "audit": {
   "row_count": 8,
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
     "returned_count": 3,
     "total_count": 3,
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
      "posting_at": "2026-09-23T02:25:14.005730+00:00",
      "voucher_type": "purchase_receipt",
      "direction": "in",
      "warehouse": "المعرض",
      "batch": "",
      "rate": "1000.00"
     },
     {
      "posting_at": "2026-09-23T02:25:14.072727+00:00",
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
  "generated_at": "2026-09-23T02:25:14.277148+00:00",
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
   "consignor_payable": "900.00",
   "consignor_receivable": "0.00",
   "shop_commission": "300.00",
   "custody_unit_count": 1,
   "custody_declared_value": "1100.00"
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
      "value": "900.00"
     },
     {
      "metric": "shop_commission",
      "value": "300.00"
     },
     {
      "metric": "custody_unit_count",
      "value": 1
     },
     {
      "metric": "custody_declared_value",
      "value": "1100.00"
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
      "consignor": "سالم",
      "code": "CONSIGNED-1",
      "product_name": "iPhone 13",
      "sold_at": "2026-09-23T02:25:14.180366+00:00",
      "payout_due": "900.00",
      "days_waiting": 0
     }
    ],
    "metadata": {
     "returned_count": 1,
     "total_count": 1,
     "omitted_count": 0,
     "truncated": false
    },
    "totals": {
     "shown": {
      "payout_due": "900.00"
     },
     "full": {
      "payout_due": "900.00"
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
      "consignor": "سالم",
      "code": "CONSIGNED-1",
      "product_name": "iPhone 13",
      "sold_at": "2026-09-23T02:25:14.180366+00:00",
      "sold_price": "1200.00",
      "payout": "900.00",
      "commission": "300.00",
      "paid": false
     }
    ],
    "metadata": {
     "returned_count": 1,
     "total_count": 1,
     "omitted_count": 0,
     "truncated": false
    },
    "totals": {
     "shown": {
      "sold_price": "1200.00",
      "payout": "900.00",
      "commission": "300.00"
     },
     "full": {
      "sold_price": "1200.00",
      "payout": "900.00",
      "commission": "300.00"
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
  "generated_at": "2026-09-23T02:25:14.306378+00:00",
  "audit": {
   "row_count": 8,
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
     "returned_count": 1,
     "total_count": 1,
     "omitted_count": 0,
     "truncated": false
    },
    {
     "key": "consignment_sales",
     "returned_count": 1,
     "total_count": 1,
     "omitted_count": 0,
     "truncated": false
    }
   ]
  }
 }
}
''';
