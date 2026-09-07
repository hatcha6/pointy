from rest_framework import serializers

from .drivers.base import StreamQuality
from .models import Camera, Recorder


class CameraSerializer(serializers.ModelSerializer):
    display_name = serializers.CharField(read_only=True)
    recorder_name = serializers.CharField(source="recorder.__str__", read_only=True)

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

    class Meta:
        model = Recorder
        fields = [
            "id",
            "name",
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
        ]
        read_only_fields = [
            "id",
            "detected_brand",
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
        ]

    def get_has_password(self, recorder):
        return bool(recorder.password)

    def update(self, instance, validated_data):
        # A blank password on update means "unchanged". Without this, opening
        # the form and pressing save would wipe the credential and take the
        # cameras down.
        if not validated_data.get("password"):
            validated_data.pop("password", None)
        return super().update(instance, validated_data)


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

    class Meta:
        model = Camera
        fields = ["id", "display_name", "channel", "status"]


QUALITY_CHOICES = StreamQuality.CHOICES
