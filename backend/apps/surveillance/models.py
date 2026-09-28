"""The shop's recorders and their channels.

Credentials are stored as entered, for the same reason the BioTime integration
does: the driver has to re-authenticate against the box on every control call
and every snapshot, so there is nothing a hash could be compared against. They
never leave the backend — no client ever receives them, which is the whole
reason video is proxied rather than pulled directly by the tills.
"""

from django.core.validators import MaxValueValidator, MinValueValidator
from django.db import models
from django.db.models import Q

from apps.core.models import TimeStampedModel

from .drivers.base import RecorderTarget, StreamQuality


class Recorder(TimeStampedModel):
    """One DVR/NVR box on the LAN.

    A shop may have more than one — a second box for the store room is normal —
    so this is not a singleton even though most installs will hold exactly one
    row.
    """

    class Connection(models.TextChoices):
        # We dial the box: live view, and its own recordings played back.
        DIRECT = "direct", "Direct connection"
        # The box dials us: it uploads footage to our FTP server and we keep
        # the invoice moments. No live view; playback is from our own disk.
        # See SURVEILLANCE_FTP_PLAN.md.
        FTP = "ftp", "FTP upload"

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
    # Fixed at creation. ``db_default`` so the previous release, still serving
    # for a minute during a live update, can keep inserting direct recorders
    # without naming a column it has never heard of.
    connection = models.CharField(
        max_length=8,
        choices=Connection.choices,
        default=Connection.DIRECT,
        db_default=Connection.DIRECT,
    )
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

    # Required for a direct recorder (the serializer says so); an FTP recorder
    # has no address of ours to dial — it is the one that connects.
    host = models.CharField(max_length=120, blank=True)
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
            # Only a direct recorder has an endpoint. Two FTP setups both carry
            # a blank host, and that is not two recorders at one address.
            models.UniqueConstraint(
                fields=["host", "port"],
                condition=Q(connection="direct"),
                name="unique_recorder_endpoint",
            )
        ]

    def __str__(self):
        if self.name:
            return self.name
        if self.is_ftp:
            account = getattr(self, "ftp_account", None)
            return f"FTP {account.username}" if account else f"FTP #{self.pk}"
        return f"{self.host}:{self.port}"

    @property
    def is_ftp(self):
        return self.connection == self.Connection.FTP

    @property
    def is_configured(self):
        if self.is_ftp:
            return True
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

        An FTP recorder is the mirror image of Direct RTSP: everything it has
        is on our own disk, so it plays back and is searchable, and it has no
        live picture at all.
        """
        if self.is_ftp:
            return {"playback": True, "search": True, "snapshot": False, "live": False}
        from .drivers.registry import driver_class_for_brand

        driver_class = driver_class_for_brand(self.effective_brand)
        if driver_class is None:
            return {"playback": False, "search": False, "snapshot": False, "live": False}
        return {
            "playback": driver_class.supports_playback,
            "search": driver_class.supports_search,
            "snapshot": driver_class.supports_snapshot,
            "live": True,
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
    # FTP recorders only: which upload source this camera is, as read from the
    # uploaded paths — ``ch:3`` for a numbered channel, ``dir:front door`` for a
    # DVR that names its folders after cameras. Empty on a direct recorder,
    # whose channel number is its identity. See archive/naming.py.
    source_key = models.CharField(max_length=160, blank=True, db_default="")
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
            ),
            models.UniqueConstraint(
                fields=["recorder", "source_key"],
                condition=~Q(source_key=""),
                name="unique_camera_source_per_recorder",
            ),
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

    @property
    def supports_live(self):
        """Whether any live surface can show this camera.

        False for a camera on an FTP recorder: it exists because footage was
        uploaded, and there is no stream of it anywhere to watch.
        """
        return not self.recorder.is_ftp


class FtpAccount(TimeStampedModel):
    """The credentials one FTP recorder logs in with, and what it has done.

    One per FTP recorder. The password is stored as generated rather than
    hashed: the installer has to be shown it again when they come back to
    finish configuring the DVR, and what it protects is write access to one
    camera inbox on the shop's own network. Only users who may change recorders
    ever see it (see RecorderSerializer).
    """

    recorder = models.OneToOneField(
        Recorder,
        on_delete=models.CASCADE,
        related_name="ftp_account",
    )
    username = models.CharField(max_length=32, unique=True)
    password = models.CharField(max_length=64)
    # The server address the installer was shown — the address the DVR was
    # configured with — and therefore the one PASV has to announce. Inside
    # Docker the FTP server only knows a container address, which the DVR
    # cannot reach. Supplied by the client, which can see the shop's network.
    advertised_host = models.CharField(max_length=64, blank=True)

    last_login_at = models.DateTimeField(blank=True, null=True)
    last_login_peer = models.CharField(max_length=64, blank=True)
    last_upload_at = models.DateTimeField(blank=True, null=True)
    last_upload_peer = models.CharField(max_length=64, blank=True)
    last_upload_name = models.CharField(max_length=255, blank=True)
    # Wrong password with this username, since the last good login. A DVR with
    # a typo in its password retries forever, and "a device at 192.168.1.108
    # keeps using the wrong password" is the sentence that ends the support call.
    failed_login_count = models.PositiveIntegerField(default=0)
    failed_login_at = models.DateTimeField(blank=True, null=True)
    failed_login_peer = models.CharField(max_length=64, blank=True)

    files_received = models.BigIntegerField(default=0)
    bytes_received = models.BigIntegerField(default=0)
    files_kept = models.BigIntegerField(default=0)
    files_discarded = models.BigIntegerField(default=0)
    files_unreadable = models.BigIntegerField(default=0)
    last_ingest_error = models.TextField(blank=True)
    last_ingest_error_at = models.DateTimeField(blank=True, null=True)

    # A proposed LOWER clock offset and when it was first seen. Raising the
    # offset is proven by a single upload (nothing arrives before it was
    # recorded); lowering it is what a DVR catching up on a backlog would also
    # look like, so it waits for sustained agreement. See archive/clock.py.
    clock_lower_minutes = models.SmallIntegerField(blank=True, null=True)
    clock_lower_since = models.DateTimeField(blank=True, null=True)

    def __str__(self):
        return self.username


class FootageUpload(models.Model):
    """A file a recorder uploaded that has not been decided on yet.

    Transient by design: the row exists from the moment the upload completes
    until the ingest pass keeps or discards the file, then it is deleted. A DVR
    sending a picture a second per channel would otherwise grow this table by
    hundreds of thousands of rows a day for no reader.
    """

    class Kind(models.TextChoices):
        VIDEO = "video", "Video"
        PICTURE = "picture", "Picture"
        OTHER = "other", "Other"

    class Status(models.TextChoices):
        PENDING = "pending", "Waiting for its decision time"
        CLAIMED = "claimed", "Being processed"

    recorder = models.ForeignKey(
        Recorder,
        on_delete=models.CASCADE,
        related_name="footage_uploads",
    )
    # Relative to the recorder's inbox, with forward slashes.
    path = models.CharField(max_length=1024)
    kind = models.CharField(max_length=8, choices=Kind.choices)
    status = models.CharField(
        max_length=8, choices=Status.choices, default=Status.PENDING
    )
    # False when the transfer broke off. Such a file is held longer in case the
    # DVR resumes it, and never used to measure the recorder's clock: it
    # "arrived" when the connection dropped, not when its footage ended.
    complete = models.BooleanField(default=True)
    size_bytes = models.BigIntegerField(default=0)
    received_at = models.DateTimeField()
    # How long the transfer itself took. A DVR that uploads a finished segment
    # starts sending right after the segment ends, so ``received_at`` minus
    # this is when the footage ended — however slow the link. One that streams
    # a file while recording takes about as long as the footage lasts, and
    # then ``received_at`` itself is the end. See archive/clock.py.
    transfer_seconds = models.FloatField(default=0)
    peer = models.CharField(max_length=64, blank=True)

    # What the path says, read once when the upload lands.
    source_key = models.CharField(max_length=160, blank=True)
    source_label = models.CharField(max_length=120, blank=True)
    channel = models.PositiveSmallIntegerField(blank=True, null=True)
    # The DEVICE's wall clock, stored as if it were UTC. Converted with the
    # recorder's clock offset at decision time, not here, because the offset is
    # measured from these very uploads and may have moved in between.
    wall_start = models.DateTimeField(blank=True, null=True)
    wall_end = models.DateTimeField(blank=True, null=True)

    decide_after = models.DateTimeField()
    claim_token = models.CharField(max_length=32, blank=True)
    claimed_at = models.DateTimeField(blank=True, null=True)
    attempts = models.PositiveSmallIntegerField(default=0)
    error = models.TextField(blank=True)

    class Meta:
        constraints = [
            models.UniqueConstraint(
                fields=["recorder", "path"],
                name="unique_footage_upload_path",
            )
        ]
        indexes = [
            models.Index(
                fields=["status", "decide_after"],
                name="surv_upload_due_idx",
            )
        ]

    def __str__(self):
        return self.path


class FootageClip(TimeStampedModel):
    """A stretch of footage we decided to keep, on our own disk.

    ``start``/``end`` are UTC and describe what the file depicts; for a
    picture they are the same moment. ``path`` is relative to the archive
    root, so moving the footage volume moves nothing in the database.
    """

    class Kind(models.TextChoices):
        VIDEO = "video", "Video"
        PICTURE = "picture", "Picture"

    camera = models.ForeignKey(
        Camera,
        on_delete=models.CASCADE,
        related_name="footage_clips",
    )
    kind = models.CharField(max_length=8, choices=Kind.choices)
    start = models.DateTimeField()
    end = models.DateTimeField()
    path = models.CharField(max_length=512, unique=True)
    size_bytes = models.BigIntegerField(default=0)

    class Meta:
        ordering = ["start", "id"]
        indexes = [
            models.Index(fields=["camera", "start"], name="surv_clip_camera_start_idx"),
            # Retention deletes by age, and the disk budget deletes oldest first.
            models.Index(fields=["end"], name="surv_clip_end_idx"),
        ]

    def __str__(self):
        return self.path
