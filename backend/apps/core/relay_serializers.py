from rest_framework import serializers


class RelayInstallationStatusSerializer(serializers.Serializer):
    configured = serializers.BooleanField()
    remote_access_supported = serializers.BooleanField()
    installation_id = serializers.CharField(allow_blank=True)
    shop_name = serializers.CharField(allow_blank=True)
    relay_public_api_url = serializers.URLField(allow_blank=True)
    relay_connector_address = serializers.CharField(allow_blank=True)
    relay_enabled = serializers.BooleanField()
    subscription_active = serializers.BooleanField()
    ai_enabled = serializers.BooleanField()
    subscription_ends_at = serializers.DateTimeField(allow_null=True)
    last_synced_at = serializers.DateTimeField(allow_null=True)
    connector_last_seen_at = serializers.DateTimeField(allow_null=True)
    connector_version = serializers.CharField(allow_blank=True)


class RelayInstallationProvisionSerializer(serializers.Serializer):
    sync = serializers.BooleanField(required=False, default=True)


class RelayPairingRequestSerializer(serializers.Serializer):
    device_id = serializers.CharField(required=False, allow_blank=True, max_length=120)
    device_name = serializers.CharField(required=False, allow_blank=True, max_length=120)


class RelayPairingResponseSerializer(serializers.Serializer):
    remote_access_supported = serializers.BooleanField()
    installation_id = serializers.CharField(allow_blank=True)
    shop_name = serializers.CharField(allow_blank=True)
    relay_public_api_url = serializers.URLField(allow_blank=True)
    relay_token = serializers.CharField(allow_blank=True)
    issued_at = serializers.DateTimeField(allow_null=True)
    expires_at = serializers.DateTimeField(allow_null=True)
    relay_refresh_token = serializers.CharField(allow_blank=True)
    refresh_expires_at = serializers.DateTimeField(allow_null=True)
    reason = serializers.CharField(allow_blank=True)


class RelayConnectorConfigSerializer(serializers.Serializer):
    installation_id = serializers.CharField()
    shop_name = serializers.CharField(allow_blank=True)
    relay_connector_address = serializers.CharField()
    connector_token = serializers.CharField()
    tls_server_name = serializers.CharField(allow_blank=True)
    connector_certificate_pem = serializers.CharField(allow_blank=True)
    connector_ca_certificate_pem = serializers.CharField(allow_blank=True)
    connector_certificate_expires_at = serializers.DateTimeField(allow_null=True)


class RelayConnectorConfigRequestSerializer(serializers.Serializer):
    csr_pem = serializers.CharField(required=False, allow_blank=True)


class RelayConnectorHeartbeatSerializer(serializers.Serializer):
    version = serializers.CharField(required=False, allow_blank=True, max_length=80)
