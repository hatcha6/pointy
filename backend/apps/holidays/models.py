from django.db import models

from . import rules


class Holiday(models.Model):
    """A special calendar day (holiday / event), interpreted by the rule engine.

    One row models any of the three rule shapes (``fixed``, ``nth_weekday``,
    ``range``) via the ``rule_type`` discriminator; unused fields stay null. The
    ``key`` is the stable slug snapshotted onto sales/purchases, so it must never
    change once shipped. Rows arrive from three sources: the in-app built-in seed
    (``builtin`` — works offline), the relay control plane (``relay``), and
    shop-scoped local entries (``local``).
    """

    CATEGORY_CHOICES = [(value, value) for value in rules.CATEGORIES]
    RULE_TYPE_CHOICES = [(value, value) for value in rules.RULE_TYPES]
    SOURCE_CHOICES = [(value, value) for value in rules.SOURCES]

    key = models.CharField(max_length=64, unique=True)
    name_en = models.CharField(max_length=120)
    name_ar = models.CharField(max_length=120)
    category = models.CharField(
        max_length=20,
        choices=CATEGORY_CHOICES,
        default=rules.CATEGORY_NATIONAL,
    )
    rule_type = models.CharField(max_length=20, choices=RULE_TYPE_CHOICES)

    # ``fixed`` / ``nth_weekday``
    month = models.PositiveSmallIntegerField(null=True, blank=True)
    day = models.PositiveSmallIntegerField(null=True, blank=True)
    # ``nth_weekday`` — weekday Monday=0..Sunday=6; week_ordinal 1..5 or -1=last.
    weekday = models.SmallIntegerField(null=True, blank=True)
    week_ordinal = models.SmallIntegerField(null=True, blank=True)
    offset_days = models.SmallIntegerField(default=0)
    span_days = models.PositiveSmallIntegerField(default=1)

    # ``range`` — explicit window (moon-based Eids, local events)
    start_date = models.DateField(null=True, blank=True)
    end_date = models.DateField(null=True, blank=True)

    show_in_dashboard = models.BooleanField(default=True)
    active = models.BooleanField(default=True)
    source = models.CharField(
        max_length=20,
        choices=SOURCE_CHOICES,
        default=rules.SOURCE_BUILTIN,
    )
    relay_id = models.CharField(max_length=80, blank=True, default="")

    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ["category", "key"]

    def __str__(self):
        return f"{self.key} ({self.name_en})"

    def to_definition(self) -> rules.Definition:
        """Adapt this row into a persistence-free :class:`rules.Definition`."""
        return rules.Definition(
            key=self.key,
            name_en=self.name_en,
            name_ar=self.name_ar,
            category=self.category,
            rule_type=self.rule_type,
            month=self.month,
            day=self.day,
            weekday=self.weekday,
            week_ordinal=self.week_ordinal,
            offset_days=self.offset_days,
            span_days=self.span_days,
            start_date=self.start_date,
            end_date=self.end_date,
            show_in_dashboard=self.show_in_dashboard,
        )
