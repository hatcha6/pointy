from rest_framework import parsers, status, views
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response

from .backup import (
    BackupValidationError,
    backup_destination_options,
    queue_backup_job,
    queue_restore_job,
)
from .backup_serializers import (
    BackupDestinationSerializer,
    BackupOperationsStatusSerializer,
    SystemBackupScheduleSerializer,
    SystemMaintenanceJobSerializer,
    backup_operations_status_data,
)
from .models import SystemBackupSchedule
from .permissions import HasPointyPermission


class BackupDestinationListView(views.APIView):
    permission_classes = [IsAuthenticated, HasPointyPermission]

    def get_required_permissions(self, request):
        return ("core.change_shopsettings",)

    def get(self, request):
        serializer = BackupDestinationSerializer(
            backup_destination_options(),
            many=True,
        )
        return Response({"destinations": serializer.data})


class BackupOperationsView(views.APIView):
    permission_classes = [IsAuthenticated, HasPointyPermission]

    def get_required_permissions(self, request):
        return ("core.change_shopsettings",)

    def get(self, request):
        return Response(self._status_data())

    def patch(self, request):
        schedule = SystemBackupSchedule.load()
        serializer = SystemBackupScheduleSerializer(
            schedule,
            data=request.data,
            partial=True,
        )
        serializer.is_valid(raise_exception=True)
        serializer.save()
        return Response(self._status_data())

    def post(self, request):
        try:
            job = queue_backup_job(user=request.user)
        except BackupValidationError as exception:
            return Response(
                {"detail": str(exception)},
                status=status.HTTP_400_BAD_REQUEST,
            )
        return Response(
            SystemMaintenanceJobSerializer(job).data,
            status=status.HTTP_202_ACCEPTED,
        )

    def _status_data(self):
        return BackupOperationsStatusSerializer(backup_operations_status_data()).data


class RestoreUploadView(views.APIView):
    permission_classes = [IsAuthenticated, HasPointyPermission]
    parser_classes = [parsers.MultiPartParser, parsers.FormParser]

    def get_required_permissions(self, request):
        return ("core.change_shopsettings",)

    def post(self, request):
        uploaded_file = request.data.get("file")
        try:
            job = queue_restore_job(uploaded_file, user=request.user)
        except BackupValidationError as exception:
            return Response(
                {"detail": str(exception)},
                status=status.HTTP_400_BAD_REQUEST,
            )
        return Response(
            SystemMaintenanceJobSerializer(job).data,
            status=status.HTTP_202_ACCEPTED,
        )
