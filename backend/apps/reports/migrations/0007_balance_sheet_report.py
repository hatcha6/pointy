from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("reports", "0006_identified_reports"),
    ]

    operations = [
        migrations.AlterField(
            model_name="reportrun",
            name="report_type",
            field=models.CharField(
                choices=[
                    ("sales_summary", "Sales summary"),
                    ("payment_methods", "Payment methods"),
                    ("register_closure", "Register closure"),
                    ("inventory_status", "Inventory status"),
                    ("stock_movements", "Stock movements"),
                    ("purchasing_summary", "Purchasing summary"),
                    ("reorder_items", "Reorder items"),
                    ("payroll_summary", "Payroll summary"),
                    ("profit_costs", "Profit and costs"),
                    ("receivables_aging", "Receivables aging"),
                    ("payables_aging", "Payables aging"),
                    ("customer_statement", "Customer statement"),
                    ("supplier_statement", "Supplier statement"),
                    ("cash_position", "Cash and bank position"),
                    ("expense_breakdown", "Expenses by category"),
                    ("product_margin", "Gross margin by product"),
                    ("discount_audit", "Discounts, voids and returns"),
                    ("sales_by_staff", "Sales by staff and hour"),
                    ("month_end_pack", "Month-end pack"),
                    ("unit_aging", "Identified stock aging"),
                    ("unit_margin", "Margin per identified article"),
                    ("unit_ledger", "One article's life"),
                    ("consignment_ledger", "Consignment ledger and payables"),
                    ("balance_sheet", "Balance sheet and zakat"),
                ],
                max_length=48,
            ),
        ),
    ]
