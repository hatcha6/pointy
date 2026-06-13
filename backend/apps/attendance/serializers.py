from rest_framework import serializers

from .models import (
    AttendanceDay,
    AttendanceProfile,
    AttendancePunch,
    BioTimeConnection,
    parse_workdays,
)


class BioTimeConnectionSerializer(serializers.ModelSerializer):
    password = serializers.CharField(
        write_only=True, required=False, allow_blank=True, trim_whitespace=False
    )
    has_password = serializers.SerializerMethodField()

    class Meta:
        model = BioTimeConnection
        fields = [
            "base_url",
            "username",
            "password",
            "has_password",
            "is_enabled",
            "workdays",
            "shift_start",
            "shift_end",
            "grace_minutes",
            "last_synced_at",
            "last_sync_status",
            "last_sync_error",
        ]
        read_only_fields = ["last_synced_at", "last_sync_status", "last_sync_error"]

    def get_has_password(self, connection):
        return bool(connection.password)

    def validate_workdays(self, value):
        if value and not parse_workdays(value):
            raise serializers.ValidationError(
                "Workdays must be comma-separated weekday numbers (0-6)."
            )
        return value

    def update(self, instance, validated_data):
        # An omitted/blank password keeps the stored one.
        password = validated_data.pop("password", None)
        if password:
            instance.password = password
        return super().update(instance, validated_data)


class AttendanceProfileSerializer(serializers.ModelSerializer):
    employee_name = serializers.CharField(source="employee.display_name", read_only=True)
    employee_number = serializers.CharField(
        source="employee.employee_number", read_only=True
    )

    class Meta:
        model = AttendanceProfile
        fields = [
            "id",
            "employee",
            "employee_name",
            "employee_number",
            "biotime_emp_code",
            "biotime_full_name",
            "is_tracked",
            "shift_start",
            "shift_end",
            "workdays",
            "grace_minutes",
        ]
        read_only_fields = ["employee", "biotime_full_name"]

    def validate_biotime_emp_code(self, value):
        value = (value or "").strip()
        if not value:
            return value
        conflict = AttendanceProfile.objects.filter(biotime_emp_code=value)
        if self.instance is not None:
            conflict = conflict.exclude(pk=self.instance.pk)
        if conflict.exists():
            raise serializers.ValidationError(
                "This BioTime code is already linked to another employee."
            )
        return value


class AttendancePunchSerializer(serializers.ModelSerializer):
    employee_name = serializers.CharField(
        source="employee.display_name", read_only=True, default=None
    )

    class Meta:
        model = AttendancePunch
        fields = [
            "id",
            "employee",
            "employee_name",
            "emp_code",
            "punch_time",
            "punch_state",
            "terminal",
            "source",
        ]


class AttendanceDaySerializer(serializers.ModelSerializer):
    employee_name = serializers.CharField(source="employee.display_name", read_only=True)

    class Meta:
        model = AttendanceDay
        fields = [
            "id",
            "employee",
            "employee_name",
            "date",
            "status",
            "first_in",
            "last_out",
            "punch_count",
            "worked_minutes",
            "late_minutes",
            "early_leave_minutes",
            "overtime_minutes",
        ]
