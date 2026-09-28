from django.db import transaction
from rest_framework import serializers

from .archive import clock
from .drivers.base import StreamQuality
from .ftp import accounts as ftp_accounts
from .ftp import status as ftp_status
from .models import Camera, FtpAccount, Recorder


class CameraSerializer(serializers.ModelSerializer):
    display_name = serializers.CharField(read_only=True)
    recorder_name = serializers.CharField(source="recorder.__str__", read_only=True)
    # False for a camera that only exists as footage its recorder uploads: the
    # client offers no live view, and the player no "go live" button.
    supports_live = serializers.BooleanField(read_only=True)

    class Meta:
        model = Camera
        fields = [
            "id",
            "recorder",
            "recorder_name",
            "channel",
            "name",
            "device_name",
            "display_name",
            "is_enabled",
            "display_order",
            "covers_checkout",
            "live_quality",
            "playback_quality",
            "status",
            "last_frame_at",
            # Tri-state, and the client must keep it that way: null is "not
            # checked yet", which is a listen button worth offering, and false
            # is "measured, no microphone", which is not.
            "has_audio",
            "supports_live",
        ]
        # Channels come from the recorder, never from a client: a camera row
        # that does not correspond to a real channel would stream nothing and
        # look like a broken camera rather than a bad edit.
        read_only_fields = [
            "id",
            "recorder",
            "recorder_name",
            "channel",
            "device_name",
            "display_name",
            "status",
            "last_frame_at",
            "has_audio",
            "supports_live",
        ]


class RecorderSerializer(serializers.ModelSerializer):
    # Write-only, and never echoed back: the client sends a blank to mean "keep
    # the stored one", which is also why it is not required on update.
    password = serializers.CharField(
        write_only=True,
        required=False,
        allow_blank=True,
        style={"input_type": "password"},
    )
    has_password = serializers.SerializerMethodField()
    camera_count = serializers.IntegerField(read_only=True)
    cameras = CameraSerializer(many=True, read_only=True)
    capabilities = serializers.DictField(
        source="driver_capabilities", read_only=True
    )
    # Chosen once, at creation. See SURVEILLANCE_FTP_PLAN.md.
    connection = serializers.ChoiceField(
        choices=Recorder.Connection.choices,
        required=False,
    )
    # FTP setups only: the server address the installer is being shown, which
    # the client — on the shop's network, unlike this container — works out.
    ftp_host = serializers.CharField(
        write_only=True, required=False, allow_blank=True, max_length=64
    )
    ftp = serializers.SerializerMethodField()

    class Meta:
        model = Recorder
        fields = [
            "id",
            "name",
            "connection",
            "ftp",
            "ftp_host",
            "brand",
            "detected_brand",
            "host",
            "port",
            "rtsp_port",
            "username",
            "password",
            "has_password",
            "use_https",
            "is_enabled",
            "rtsp_path_template",
            "onvif_service_path",
            "max_concurrent_streams",
            "model_name",
            "firmware",
            "serial_number",
            "channel_count",
            "clock_offset_minutes",
            "clock_offset_is_measured",
            "status",
            "last_error",
            "last_seen_at",
            "camera_count",
            "cameras",
            "capabilities",
        ]
        read_only_fields = [
            "id",
            "detected_brand",
            "model_name",
            "firmware",
            "serial_number",
            "clock_offset_minutes",
            "clock_offset_is_measured",
            "status",
            "last_error",
            "last_seen_at",
            "camera_count",
            "cameras",
            "capabilities",
        ]
        # The endpoint uniqueness is checked in ``validate``. DRF's generated
        # validator would demand ``host`` of an FTP setup, which has none, and
        # ``connection`` of every older client, which never sends it.
        validators = []

    def get_has_password(self, recorder):
        return bool(recorder.password)

    def get_ftp(self, recorder):
        """Everything the installer types into the DVR, and how it is going.

        The password is included only for someone who may change recorders:
        the installer needs to read it again, a cashier with view access does
        not.
        """
        if not recorder.is_ftp:
            return None
        account = getattr(recorder, "ftp_account", None)
        if account is None:
            return None
        request = self.context.get("request")
        user = getattr(request, "user", None)
        may_see_password = bool(
            user
            and user.is_authenticated
            and (
                user.has_perm("surveillance.change_recorder")
                or user.has_perm("surveillance.add_recorder")
            )
        )
        return {
            "username": account.username,
            "password": account.password if may_see_password else None,
            "host": account.advertised_host,
            "server": ftp_status.summary(),
            "last_login_at": account.last_login_at,
            "last_login_peer": account.last_login_peer,
            "last_upload_at": account.last_upload_at,
            "last_upload_peer": account.last_upload_peer,
            "last_upload_name": account.last_upload_name,
            "failed_login_count": account.failed_login_count,
            "failed_login_at": account.failed_login_at,
            "failed_login_peer": account.failed_login_peer,
            "files_received": account.files_received,
            "files_kept": account.files_kept,
            "files_discarded": account.files_discarded,
            "files_unreadable": account.files_unreadable,
            "last_ingest_error": account.last_ingest_error,
            "last_ingest_error_at": account.last_ingest_error_at,
        }

    def validate_ftp_host(self, value):
        if value and not ftp_accounts.normalise_host(value):
            raise serializers.ValidationError(
                "عنوان الخادم غير صالح — اكتب عنوان IP في شبكة المحل."
            )
        return ftp_accounts.normalise_host(value)

    def validate(self, attrs):
        """A Direct-RTSP recorder is unusable without the two things only a
        person can supply, so it is refused at the form rather than at the
        stream — where the failure would read as a broken camera.

        Both fields fall back to the stored row so a PATCH that touches neither
        still validates against what is actually configured.
        """

        def current(name):
            if name in attrs:
                return attrs[name]
            return getattr(self.instance, name, None)

        if self.instance is not None and "connection" in attrs:
            if attrs["connection"] != self.instance.connection:
                raise serializers.ValidationError(
                    {"connection": "طريقة الاتصال لا تتغير بعد الإنشاء — أضف مسجلاً جديداً."}
                )
        if current("connection") == Recorder.Connection.FTP:
            # Nothing of ours dials an FTP recorder, so no address, port or
            # login of its own is kept: stale values would only mislead.
            for field in ("host", "username", "password", "rtsp_path_template", "onvif_service_path"):
                attrs.pop(field, None)
            if self.instance is None:
                attrs.update(host="", username="", password="", brand=Recorder.Brand.AUTO)
            return attrs
        host = str(current("host") or "").strip()
        if not host:
            raise serializers.ValidationError({"host": "This field is required."})
        port = current("port") or 80
        clash = Recorder.objects.filter(
            connection=Recorder.Connection.DIRECT, host=host, port=port
        )
        if self.instance is not None:
            clash = clash.exclude(pk=self.instance.pk)
        if clash.exists():
            raise serializers.ValidationError(
                {"host": "A recorder at this address and port is already set up."}
            )

        if current("brand") != Recorder.Brand.DIRECT_RTSP:
            return attrs
        errors = {}
        if not str(current("rtsp_path_template") or "").strip():
            errors["rtsp_path_template"] = (
                "A Direct-RTSP recorder needs the stream address template, "
                "because it has no API to be asked for one."
            )
        if not (current("channel_count") or 0):
            errors["channel_count"] = (
                "Set how many cameras this recorder has — it cannot be asked."
            )
        if errors:
            raise serializers.ValidationError(errors)
        return attrs

    @transaction.atomic
    def create(self, validated_data):
        ftp_host = validated_data.pop("ftp_host", "")
        if validated_data.get("connection") == Recorder.Connection.FTP:
            # Until an upload proves otherwise, the DVR is assumed to keep the
            # shop's own time — which nearly every recorder here does.
            validated_data["clock_offset_minutes"] = clock.assumed_offset_minutes()
            validated_data["clock_offset_is_measured"] = False
        recorder = super().create(validated_data)
        if recorder.is_ftp:
            ftp_accounts.create_account(recorder, advertised_host=ftp_host)
        return recorder

    def update(self, instance, validated_data):
        ftp_host = validated_data.pop("ftp_host", None)
        validated_data.pop("connection", None)
        # A blank password on update means "unchanged". Without this, opening
        # the form and pressing save would wipe the credential and take the
        # cameras down.
        if not validated_data.get("password"):
            validated_data.pop("password", None)
        recorder = super().update(instance, validated_data)
        if recorder.is_ftp and ftp_host is not None:
            FtpAccount.objects.filter(recorder=recorder).update(advertised_host=ftp_host)
        return recorder


class RecorderTestSerializer(serializers.Serializer):
    """Credentials to try, before anything is saved."""

    host = serializers.CharField(required=False, allow_blank=True)
    port = serializers.IntegerField(required=False, min_value=1, max_value=65535)
    rtsp_port = serializers.IntegerField(required=False, min_value=1, max_value=65535)
    username = serializers.CharField(required=False, allow_blank=True)
    password = serializers.CharField(required=False, allow_blank=True)
    use_https = serializers.BooleanField(required=False)
    brand = serializers.ChoiceField(
        choices=Recorder.Brand.choices,
        required=False,
    )
    # Brand-specific settings the test has to honour too: testing a Direct-RTSP
    # box without its template would report "unreachable" for a recorder that is
    # answering perfectly well.
    rtsp_path_template = serializers.CharField(required=False, allow_blank=True)
    onvif_service_path = serializers.CharField(required=False, allow_blank=True)
    channel_count = serializers.IntegerField(required=False, min_value=0, max_value=256)


class DetectedChannelSerializer(serializers.Serializer):
    channel = serializers.IntegerField()
    name = serializers.CharField(allow_blank=True)
    online = serializers.BooleanField()


class RecordingSegmentSerializer(serializers.Serializer):
    start = serializers.DateTimeField()
    end = serializers.DateTimeField()
    size_bytes = serializers.IntegerField()


class InvoiceFootageCameraSerializer(serializers.ModelSerializer):
    display_name = serializers.CharField(read_only=True)
    supports_live = serializers.BooleanField(read_only=True)
    # True/False for a camera whose footage is on our own disk (FTP), where the
    # answer is known; null for a recorder that can only be asked by playing.
    has_footage = serializers.SerializerMethodField()

    class Meta:
        model = Camera
        fields = ["id", "display_name", "channel", "status", "supports_live", "has_footage"]

    def get_has_footage(self, camera):
        return getattr(camera, "has_footage", None)


class FtpHostSerializer(serializers.Serializer):
    host = serializers.CharField(max_length=64)

    def validate_host(self, value):
        normalised = ftp_accounts.normalise_host(value)
        if not normalised:
            raise serializers.ValidationError(
                "عنوان الخادم غير صالح — اكتب عنوان IP في شبكة المحل."
            )
        return normalised


QUALITY_CHOICES = StreamQuality.CHOICES
