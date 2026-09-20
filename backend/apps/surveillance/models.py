"""The shop's recorders and their channels.

Credentials are stored as entered, for the same reason the BioTime integration
does: the driver has to re-authenticate against the box on every control call
and every snapshot, so there is nothing a hash could be compared against. They
never leave the backend — no client ever receives them, which is the whole
reason video is proxied rather than pulled directly by the tills.
"""

from django.core.validators import MaxValueValidator, MinValueValidator
from django.db import models

from apps.core.models import TimeStampedModel

from .drivers.base import RecorderTarget, StreamQuality


class Recorder(TimeStampedModel):
    """One DVR/NVR box on the LAN.

    A shop may have more than one — a second box for the store room is normal —
    so this is not a singleton even though most installs will hold exactly one
    row.
    """

    class Brand(models.TextChoices):
        AUTO = "auto", "Detect automatically"
        HIKVISION = "hikvision", "Hikvision"
        DAHUA = "dahua", "Dahua"
        # Everything else. ONVIF covers the boxes that answer a standard rather
        # than a vendor dialect; DIRECT_RTSP covers the ones that answer no
        # control protocol at all and only have a stream. Between them they are
        # most of what is actually installed in Libyan shops.
        # Spoken natively rather than through ONVIF: it is the only way to
        # get channel names and recording search out of this hardware, and
        # recording search is what invoice-linked footage is built on.
        XIONGMAI = "xiongmai", "Xiongmai / XMEye"
        ONVIF = "onvif", "ONVIF (other brands)"
        DIRECT_RTSP = "generic_rtsp", "Direct RTSP (live view only)"

    class Status(models.TextChoices):
        NEVER = "never", "Never connected"
        OK = "ok", "Connected"
        ERROR = "error", "Last attempt failed"

    name = models.CharField(max_length=120, blank=True)
    brand = models.CharField(
        max_length=16,
        choices=Brand.choices,
        default=Brand.AUTO,
    )
    # What probing actually found. Kept apart from ``brand`` so a row saved as
    # "detect automatically" still records the answer, and so a box that is
    # replaced with the other brand at the same IP re-detects instead of
    # failing against a stale guess.
    detected_brand = models.CharField(max_length=16, blank=True)

    host = models.CharField(max_length=120)
    port = models.PositiveIntegerField(
        default=80,
        validators=[MinValueValidator(1), MaxValueValidator(65535)],
    )
    rtsp_port = models.PositiveIntegerField(
        default=554,
        validators=[MinValueValidator(1), MaxValueValidator(65535)],
    )
    username = models.CharField(max_length=120, blank=True)
    password = models.CharField(max_length=255, blank=True)
    use_https = models.BooleanField(default=False)
    is_enabled = models.BooleanField(default=True)
    # Only for ``DIRECT_RTSP``: the stream path, with ``{channel}`` and
    # ``{stream}`` placeholders. See apps.surveillance.drivers.generic_rtsp.
    # ``db_default`` so a live update stays safe: the previous release keeps
    # serving for about a minute against the new schema, and its INSERTs name
    # no such column. Same reason as core.ShopSettings.enable_surveillance.
    rtsp_path_template = models.CharField(max_length=255, blank=True, db_default="")
    # Only for ``ONVIF``, and only when autodetection fails: OEM firmwares put
    # the device service on a handful of different paths and the driver tries
    # them all, so this stays empty on nearly every install.
    onvif_service_path = models.CharField(max_length=120, blank=True, db_default="")
    # How many live streams this box will serve at once, when somebody knows.
    # Left empty on nearly every install: a DVR does not announce its session
    # cap and nobody reads the datasheet, so the usual path is that we learn it
    # from a stream that failed while its neighbours were fine — see
    # apps.surveillance.budget. Setting it here overrides what we learned, for
    # the installer who does know.
    # ``db_default`` for the same reason as the two fields above: a zero-downtime
    # update leaves the previous release inserting rows that name no such column.
    max_concurrent_streams = models.PositiveSmallIntegerField(
        null=True, blank=True, db_default=None
    )

    # Identity, from the last successful probe.
    model_name = models.CharField(max_length=120, blank=True)
    firmware = models.CharField(max_length=120, blank=True)
    serial_number = models.CharField(max_length=120, blank=True)
    channel_count = models.PositiveSmallIntegerField(default=0)

    # Minutes the recorder's clock is ahead of UTC, as measured at the last
    # probe. Playback windows are addressed in the device's terms, so this is
    # what makes "play the moment this invoice was rung up" land on the right
    # minute on a DVR whose timezone was never set. See
    # ``RecorderDriver.read_clock_offset_minutes``.
    clock_offset_minutes = models.SmallIntegerField(default=0)
    clock_offset_is_measured = models.BooleanField(default=False)

    status = models.CharField(
        max_length=16,
        choices=Status.choices,
        default=Status.NEVER,
    )
    last_error = models.TextField(blank=True)
    last_seen_at = models.DateTimeField(blank=True, null=True)

    class Meta:
        ordering = ["name", "host"]
        constraints = [
            models.UniqueConstraint(
                fields=["host", "port"],
                name="unique_recorder_endpoint",
            )
        ]

    def __str__(self):
        return self.name or f"{self.host}:{self.port}"

    @property
    def is_configured(self):
        return bool(self.host and self.username)

    @property
    def effective_brand(self):
        """The brand to build a driver with: the detection result wins.

        A row explicitly set to Hikvision that probed as Dahua is an installer's
        mistake, not an instruction, and honouring the mistake would mean the
        shop's cameras simply never appear.
        """
        if self.detected_brand:
            return self.detected_brand
        return self.brand

    @property
    def driver_capabilities(self) -> dict:
        """What this recorder's brand can do, without opening a connection.

        The client asks before it draws: a Direct-RTSP box gets live tiles and
        no playback control, rather than a control that fails when pressed.
        ONVIF is the one brand whose answer here is a floor rather than the
        truth — Profile G is discovered per device, so a probe may widen it.
        """
        from .drivers.registry import driver_class_for_brand

        driver_class = driver_class_for_brand(self.effective_brand)
        if driver_class is None:
            return {"playback": False, "search": False, "snapshot": False}
        return {
            "playback": driver_class.supports_playback,
            "search": driver_class.supports_search,
            "snapshot": driver_class.supports_snapshot,
        }

    def as_target(self) -> RecorderTarget:
        return RecorderTarget(
            host=self.host,
            port=self.port,
            rtsp_port=self.rtsp_port,
            username=self.username,
            password=self.password,
            use_https=self.use_https,
            clock_offset_minutes=self.clock_offset_minutes,
            # Per-brand configuration the shipped two never need. Carried in
            # ``extra`` so ``RecorderTarget`` stays a connection description
            # rather than growing a column per brand.
            extra={
                "rtsp_path_template": self.rtsp_path_template,
                "onvif_service_path": self.onvif_service_path,
                "channel_count": self.channel_count,
            },
        )


class Camera(TimeStampedModel):
    """One channel on a recorder, as the shop thinks of it.

    ``name`` is ours, not the device's. Renaming a channel on the DVR needs
    admin rights on the DVR, changes it for every other client of that box, and
    is rejected outright by a good share of the firmware in the field — so the
    name a cashier types here is stored here, takes effect immediately, and can
    be changed back. ``device_name`` keeps whatever the box calls it so the two
    can be told apart during setup.
    """

    class Status(models.TextChoices):
        UNKNOWN = "unknown", "Not checked"
        ONLINE = "online", "Online"
        OFFLINE = "offline", "Offline"

    recorder = models.ForeignKey(
        Recorder,
        on_delete=models.CASCADE,
        related_name="cameras",
    )
    channel = models.PositiveSmallIntegerField()
    name = models.CharField(max_length=120, blank=True)
    device_name = models.CharField(max_length=120, blank=True)
    is_enabled = models.BooleanField(default=True)
    display_order = models.PositiveSmallIntegerField(default=0)

    # Offered on an invoice's page as "what this sale looked like". Off by
    # default: a camera on the back door has nothing to do with a receipt, and
    # showing every channel there would bury the one that matters.
    covers_checkout = models.BooleanField(default=False)

    # Which encoder track the wall pulls. Sub by default — a tile is 320px wide
    # and a 16-channel DVR will refuse the ninth simultaneous main-stream pull.
    live_quality = models.CharField(
        max_length=8,
        choices=[(value, value) for value in StreamQuality.CHOICES],
        default=StreamQuality.SUB,
    )
    playback_quality = models.CharField(
        max_length=8,
        choices=[(value, value) for value in StreamQuality.CHOICES],
        default=StreamQuality.MAIN,
    )

    # Whether this channel carries sound, as measured by ffprobe — never
    # guessed. NULL means "not asked yet", which is the state every camera
    # starts in; the check costs an RTSP session, so it is made once, on the
    # first attempt to listen, and kept.
    #
    # Tri-state rather than a boolean default because "no microphone" and "not
    # yet checked" need different answers from the UI: the first hides the
    # listen button for good, the second leaves it to be tried. Defaulting to
    # False would hide sound on every camera that has it until something
    # re-checked; defaulting to True is the snapshot-polling mistake again.
    has_audio = models.BooleanField(null=True, blank=True, default=None)
    audio_checked_at = models.DateTimeField(blank=True, null=True)

    status = models.CharField(
        max_length=16,
        choices=Status.choices,
        default=Status.UNKNOWN,
    )
    last_frame_at = models.DateTimeField(blank=True, null=True)

    class Meta:
        ordering = ["display_order", "channel", "id"]
        constraints = [
            models.UniqueConstraint(
                fields=["recorder", "channel"],
                name="unique_camera_channel_per_recorder",
            )
        ]
        permissions = [
            # Watching, scrubbing history, and taking a copy away are three
            # different levels of trust — "the supervisor may watch the wall but
            # not export" is a request shops actually make — so they are three
            # permissions rather than one.
            ("view_live", "Can watch live camera streams"),
            ("view_playback", "Can watch recorded footage"),
            ("export_footage", "Can export video clips"),
        ]

    def __str__(self):
        return self.display_name

    @property
    def display_name(self):
        return self.name or self.device_name or f"قناة {self.channel}"
