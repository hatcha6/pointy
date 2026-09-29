"""The repair of provider top-ups recorded before the float sheet named a source.

Driven through the migration executor on a database that already holds the
broken rows, the way a shop's update meets them. A freshly built test database
never has any, so without this the migration's filter would only ever run
against nothing.
"""

from datetime import timedelta
from decimal import Decimal

from django.db import connection
from django.db.migrations.executor import MigrationExecutor
from django.db.migrations.recorder import MigrationRecorder
from django.test import TransactionTestCase
from django.utils import timezone

from apps.integrations import float_ledger
from apps.treasury.models import MoneyAccount, MoneyTransfer
from apps.treasury.position import outside_money_totals, treasury_position

MIGRATE_FROM = ("integrations", "0015_voucher_brand_logo")
MIGRATE_TO = ("integrations", "0016_top_ups_leave_the_cash_box")


class TopUpSourceRepairTests(TransactionTestCase):
    # The migration writes outside the test's own transaction, so the tables
    # are reset the slow, honest way.
    available_apps = None

    def setUp(self):
        super().setUp()
        self._migrate([MIGRATE_FROM])
        self.today = timezone.localdate()
        # Our own accounts, not the seeded pair: a TransactionTestCase before
        # this one may have flushed those away.
        MoneyAccount.objects.all().delete()
        self.cash = MoneyAccount.objects.create(
            name="الخزينة",
            kind=MoneyAccount.Kind.CASH,
            is_default=True,
            display_order=5,
            opening_at=self.today - timedelta(days=30),
        )
        self.bank = MoneyAccount.objects.create(
            name="المصرف",
            kind=MoneyAccount.Kind.BANK,
            is_default=True,
            opening_at=self.today - timedelta(days=30),
        )
        self.float = MoneyAccount.objects.create(
            name="رصيد LNET — lnet_r67", kind=MoneyAccount.Kind.PROVIDER
        )

    def tearDown(self):
        # Forward to every leaf, never to a pinned name: a rewound schema left
        # behind breaks whichever TransactionTestCase runs next.
        executor = MigrationExecutor(connection)
        executor.loader.build_graph()
        executor.migrate(executor.loader.graph.leaf_nodes())
        applied = set(MigrationRecorder(connection).applied_migrations())
        missing = sorted(set(executor.loader.graph.nodes) - applied)
        self.assertFalse(missing, f"schema left rewound: {missing}")
        super().tearDown()

    def _migrate(self, targets):
        executor = MigrationExecutor(connection)
        executor.loader.build_graph()
        executor.migrate(targets)

    def _sheet_top_up(self, amount, *, moved_at=None, reason=None, to=None):
        """A row exactly as the float sheet wrote one: no source at all."""
        return MoneyTransfer.objects.create(
            from_account=None,
            to_account=to or self.float,
            amount=Decimal(amount),
            moved_at=moved_at or self.today,
            reason=float_ledger.TOP_UP_REASON if reason is None else reason,
        )

    def test_a_top_up_the_sheet_recorded_now_leaves_the_cash_box(self):
        top_up = self._sheet_top_up("1000.00")
        by_bank = MoneyTransfer.objects.create(
            from_account=self.bank,
            to_account=self.float,
            amount=Decimal("300.00"),
            reason=float_ledger.TOP_UP_REASON,
        )
        before = treasury_position()["totals"]
        self.assertEqual(
            outside_money_totals(start=self.today, end=self.today)["added"],
            Decimal("1000.00"),
        )

        self._migrate([MIGRATE_TO])

        top_up.refresh_from_db()
        by_bank.refresh_from_db()
        self.assertEqual(top_up.from_account_id, self.cash.pk)
        self.assertEqual(by_bank.from_account_id, self.bank.pk)
        after = treasury_position()["totals"]
        self.assertEqual(after["cash"], before["cash"] - Decimal("1000.00"))
        self.assertEqual(after["bank"], before["bank"])
        self.assertEqual(after["provider_float"], before["provider_float"])
        # No longer money the owner put in.
        self.assertEqual(
            outside_money_totals(start=self.today, end=self.today)["added"],
            Decimal("0.00"),
        )

    def test_a_side_somebody_chose_is_kept(self):
        # «خارج المحل» picked on the treasury screen, with a reason typed there.
        chosen = self._sheet_top_up("200.00", reason="من جيب المالك")
        # The sheet's wording, but capital into the cash box, not a float.
        capital = self._sheet_top_up("500.00", to=self.cash)

        self._migrate([MIGRATE_TO])

        chosen.refresh_from_db()
        capital.refresh_from_db()
        self.assertIsNone(chosen.from_account_id)
        self.assertIsNone(capital.from_account_id)

    def test_a_top_up_from_before_the_cash_box_opened_is_not_taken_twice(self):
        MoneyAccount.objects.filter(pk=self.cash.pk).update(
            opening_at=self.today - timedelta(days=3)
        )
        earlier = self._sheet_top_up(
            "300.00", moved_at=self.today - timedelta(days=5)
        )
        on_the_day = self._sheet_top_up(
            "100.00", moved_at=self.today - timedelta(days=3)
        )

        self._migrate([MIGRATE_TO])

        earlier.refresh_from_db()
        on_the_day.refresh_from_db()
        # Already out of the opening balance the owner stated for that day.
        self.assertIsNone(earlier.from_account_id)
        self.assertEqual(on_the_day.from_account_id, self.cash.pk)

    def test_the_default_cash_box_pays_not_the_first_listed(self):
        MoneyAccount.objects.create(
            name="الخزنة الحديدية",
            kind=MoneyAccount.Kind.CASH,
            display_order=0,
            opening_at=self.today - timedelta(days=30),
        )
        top_up = self._sheet_top_up("75.00")

        self._migrate([MIGRATE_TO])

        top_up.refresh_from_db()
        self.assertEqual(top_up.from_account_id, self.cash.pk)

    def test_a_shop_with_no_active_cash_box_is_left_as_it_was(self):
        MoneyAccount.objects.filter(kind=MoneyAccount.Kind.CASH).update(
            is_active=False
        )
        top_up = self._sheet_top_up("50.00")

        self._migrate([MIGRATE_TO])

        top_up.refresh_from_db()
        self.assertIsNone(top_up.from_account_id)
