import hashlib
import hmac
import secrets

from django.db import models
from django.utils import timezone
from django.utils.text import slugify

from apps.core.models import TimeStampedModel

# The visible key prefix is stored in clear for lookup and display ("pck_ab12cd34…");
# the full key is only ever stored as a SHA-256 hash.
API_KEY_PREFIX_HEX_CHARS = 8
API_KEY_SENTINEL = "pck"
API_KEY_MAX_LENGTH = 256


def hash_api_key(raw_key: str) -> str:
    return hashlib.sha256(raw_key.encode("utf-8")).hexdigest()


def generate_api_key() -> tuple[str, str]:
    """Return ``(raw_key, prefix)`` for a new channel API key.

    The raw key is shown to the admin exactly once at creation/rotation time;
    afterwards only its hash can be compared, never recovered.
    """
    prefix = secrets.token_hex(API_KEY_PREFIX_HEX_CHARS // 2)
    secret = secrets.token_urlsafe(32)
    return f"{API_KEY_SENTINEL}_{prefix}_{secret}", prefix


class SalesChannel(TimeStampedModel):
    """A source of sales: the shop's own POS app, a delivery app, a web shop.

    The channel a request belongs to is always derived on the backend from the
    credential that authenticated the request — a session login maps to the
    built-in POS channel, a channel API key maps to the channel that owns the
    key. It is never accepted from client input, so an external integration
    cannot pose as the POS or as another integration.
    """

    POS_SLUG = "pos"
    POS_NAME = "نقطة البيع"

    class ChannelType(models.TextChoices):
        POS = "pos", "Point of sale"
        DELIVERY = "delivery", "Delivery app"
        ECOMMERCE = "ecommerce", "E-commerce"
        MARKETPLACE = "marketplace", "Marketplace"
        OTHER = "other", "Other"

    name = models.CharField(max_length=120)
    slug = models.SlugField(max_length=64, unique=True, allow_unicode=True)
    channel_type = models.CharField(
        max_length=24,
        choices=ChannelType.choices,
        default=ChannelType.OTHER,
    )
    is_active = models.BooleanField(default=True)
    # The built-in channel for the shop's own POS app. It authenticates via
    # user sessions rather than an API key and is protected from deactivation
    # and deletion so the shop can never lock itself out of its own register.
    is_system = models.BooleanField(default=False)
    notes = models.TextField(blank=True)
    api_key_prefix = models.CharField(max_length=16, blank=True, db_index=True)
    api_key_hash = models.CharField(max_length=128, blank=True, editable=False)
    api_key_generated_at = models.DateTimeField(blank=True, null=True)
    api_key_last_used_at = models.DateTimeField(blank=True, null=True)

    class Meta:
        ordering = ["-is_system", "name"]

    def __str__(self) -> str:
        return self.name

    @classmethod
    def pos_channel(cls) -> "SalesChannel":
        channel, _created = cls.objects.get_or_create(
            slug=cls.POS_SLUG,
            defaults={
                "name": cls.POS_NAME,
                "channel_type": cls.ChannelType.POS,
                "is_system": True,
                "is_active": True,
            },
        )
        return channel

    @classmethod
    def build_unique_slug(cls, name: str) -> str:
        base = slugify(name, allow_unicode=True)[:48] or "channel"
        slug = base
        while cls.objects.filter(slug=slug).exists():
            slug = f"{base}-{secrets.token_hex(2)}"
        return slug

    def assign_new_api_key(self) -> str:
        raw_key, prefix = generate_api_key()
        self.api_key_prefix = prefix
        self.api_key_hash = hash_api_key(raw_key)
        self.api_key_generated_at = timezone.now()
        self.api_key_last_used_at = None
        self.save(
            update_fields=[
                "api_key_prefix",
                "api_key_hash",
                "api_key_generated_at",
                "api_key_last_used_at",
                "updated_at",
            ]
        )
        return raw_key

    @classmethod
    def authenticate_api_key(cls, raw_key: str) -> "SalesChannel | None":
        """Return the channel owning ``raw_key``, or ``None`` for a bad key.

        Returns inactive channels too so callers can distinguish "unknown key"
        (401) from "deauthorized channel" (403). The hash comparison is
        constant-time; the indexed prefix only narrows the candidate set.
        """
        if not raw_key or len(raw_key) > API_KEY_MAX_LENGTH:
            return None
        parts = raw_key.split("_", 2)
        if len(parts) != 3 or parts[0] != API_KEY_SENTINEL:
            return None
        candidate_hash = hash_api_key(raw_key)
        channels = cls.objects.filter(api_key_prefix=parts[1]).exclude(api_key_hash="")
        for channel in channels:
            if hmac.compare_digest(channel.api_key_hash, candidate_hash):
                return channel
        return None
