from rest_framework import serializers

from .models import SalesChannel


class SalesChannelSerializer(serializers.ModelSerializer):
    has_api_key = serializers.SerializerMethodField()

    class Meta:
        model = SalesChannel
        fields = [
            "id",
            "name",
            "slug",
            "channel_type",
            "is_active",
            "is_system",
            "notes",
            "has_api_key",
            "api_key_prefix",
            "api_key_generated_at",
            "api_key_last_used_at",
            "created_at",
            "updated_at",
        ]
        # The channel identity and its credential state are controlled by the
        # backend only; clients may edit the descriptive fields and the
        # authorization flag.
        read_only_fields = (
            "slug",
            "is_system",
            "api_key_prefix",
            "api_key_generated_at",
            "api_key_last_used_at",
        )

    def get_has_api_key(self, channel) -> bool:
        return bool(channel.api_key_hash)

    def validate(self, attrs):
        instance = self.instance
        if instance is not None and instance.is_system:
            if attrs.get("is_active") is False:
                raise serializers.ValidationError(
                    {"is_active": "The built-in POS channel cannot be deauthorized."}
                )
            channel_type = attrs.get("channel_type")
            if channel_type is not None and channel_type != instance.channel_type:
                raise serializers.ValidationError(
                    {"channel_type": "The built-in POS channel type cannot be changed."}
                )
        elif attrs.get("channel_type") == SalesChannel.ChannelType.POS:
            raise serializers.ValidationError(
                {"channel_type": "The POS type is reserved for the built-in channel."}
            )
        return attrs

    def create(self, validated_data):
        validated_data["slug"] = SalesChannel.build_unique_slug(validated_data["name"])
        return super().create(validated_data)
