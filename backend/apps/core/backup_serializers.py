from rest_framework import serializers

from .backup import (
    BackupValidationError,
    active_maintenance_job,
    latest_maintenance_job,
    next_scheduled_backup_at,
    validate_backup_destination,
)
from .models import SystemBackupSchedule, SystemMaintenanceJob


class BackupDestinationSerializer(serializers.Serializer):
    label = serializers.CharField()
    path = serializers.CharField()
    backup_path = serializers.CharField()
    is_available = serializers.BooleanField()
    is_writable = serializers.BooleanField()
    total_bytes = serializers.IntegerField()
    free_bytes = serializers.IntegerField()


class SystemMaintenanceJobSerializer(serializers.ModelSerializer):
    class Meta:
        model = SystemMaintenanceJob
        fields = [
            "id",
            "operation",
            "status",
            "progress_percent",
            "progress_message",
            "destination_path",
            "backup_file_name",
            "archive_size_bytes",
            "error_message",
            "metadata",
            "initiated_by_user_id",
            "initiated_by_username",
            "created_at",
            "updated_at",
            "started_at",
            "completed_at",
        ]
        read_only_fields = fields


class SystemBackupScheduleSerializer(serializers.ModelSerializer):
    next_scheduled_at = serializers.SerializerMethodField()

    class Meta:
        model = SystemBackupSchedule
        fields = [
            "enabled",
            "destination_path",
            "scheduled_time",
            "retention_count",
            "next_scheduled_at",
            "updated_at",
        ]
        read_only_fields = ["next_scheduled_at", "updated_at"]

    def get_next_scheduled_at(self, schedule):
        next_backup = next_scheduled_backup_at(schedule)
        return next_backup.isoformat() if next_backup is not None else None

    def validate_destination_path(self, value):
        value = value.strip()
        if value:
            try:
                validate_backup_destination(value)
            except BackupValidationError as exception:
                raise serializers.ValidationError(str(exception)) from exception
        return value

    def validate(self, attrs):
        enabled = attrs.get("enabled", getattr(self.instance, "enabled", False))
        destination_path = attrs.get(
            "destination_path",
            getattr(self.instance, "destination_path", ""),
        )
        if enabled and not destination_path:
            raise serializers.ValidationError(
                {"destination_path": "Backup destination is required."}
            )
        return attrs


class BackupOperationsStatusSerializer(serializers.Serializer):
    schedule = SystemBackupScheduleSerializer()
    active_job = SystemMaintenanceJobSerializer(allow_null=True)
    latest_backup_job = SystemMaintenanceJobSerializer(allow_null=True)
    latest_restore_job = SystemMaintenanceJobSerializer(allow_null=True)


def backup_operations_status_data():
    schedule = SystemBackupSchedule.load()
    return {
        "schedule": schedule,
        "active_job": active_maintenance_job(),
        "latest_backup_job": latest_maintenance_job(
            SystemMaintenanceJob.Operation.BACKUP
        ),
        "latest_restore_job": latest_maintenance_job(
            SystemMaintenanceJob.Operation.RESTORE
        ),
    }
