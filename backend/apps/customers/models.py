from django.core.exceptions import ValidationError
from django.db import models, transaction
from django.utils import timezone

from apps.core.models import TimeStampedModel


class Customer(TimeStampedModel):
    class Gender(models.TextChoices):
        UNSPECIFIED = "", "Unspecified"
        FEMALE = "female", "Female"
        MALE = "male", "Male"
        NON_BINARY = "non_binary", "Non-binary"
        PREFER_NOT_TO_SAY = "prefer_not_to_say", "Prefer not to say"

    customer_number = models.CharField(max_length=32, unique=True, blank=True)
    full_name = models.CharField(max_length=255)
    phone = models.CharField(max_length=64, blank=True)
    email = models.EmailField(blank=True)
    gender = models.CharField(
        max_length=32,
        choices=Gender.choices,
        blank=True,
        default=Gender.UNSPECIFIED,
    )
    birthday = models.DateField(blank=True, null=True)
    marketing_consent = models.BooleanField(default=False)
    notes = models.TextField(blank=True)
    is_active = models.BooleanField(default=True)

    class Meta:
        ordering = ["full_name", "customer_number"]

    def clean(self):
        if self.birthday and self.birthday > timezone.localdate():
            raise ValidationError({"birthday": "Birthday cannot be in the future."})

    def save(self, *args, **kwargs):
        self.full_clean()
        if not self.customer_number:
            with transaction.atomic():
                super().save(*args, **kwargs)
                self.customer_number = f"C{self.created_at:%Y%m%d}{self.id:06d}"
                return super().save(update_fields=["customer_number"])
        return super().save(*args, **kwargs)

    def __str__(self) -> str:
        return self.full_name
