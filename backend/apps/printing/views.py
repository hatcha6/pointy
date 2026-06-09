from django.db import transaction
from django.db.models import Q
from django.utils import timezone
from rest_framework import mixins, status, viewsets
from rest_framework.decorators import action
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response

from apps.core.permissions import HasPointyPermission
from apps.core.roles import user_is_manager
from .models import (
    PrinterProfile,
    PrintAgent,
    PrintAuditEvent,
    PrintJob,
    PrintJobEvent,
    PrintTemplate,
    PrintTemplateVersion,
)
from .serializers import (
    PrinterProfileSerializer,
    PrintAgentSerializer,
    PrintAuditEventRecordSerializer,
    PrintAuditEventReportSerializer,
    PrintAuditEventSerializer,
    PrintJobAgentActionSerializer,
    PrintJobEventSerializer,
    PrintJobFailureSerializer,
    PrintJobSerializer,
    PrintJobReportSerializer,
    PrintTemplateSerializer,
    PrintTemplateVersionSerializer,
)
from .services import (
    claim_next_print_job,
    claim_print_job,
    create_job_event,
    publish_template_version,
)


class PrintTemplateViewSet(viewsets.ModelViewSet):
    serializer_class = PrintTemplateSerializer
    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {
        "list": ("printing.view_printtemplate",),
        "retrieve": ("printing.view_printtemplate",),
        "create": ("printing.add_printtemplate",),
        "update": ("printing.change_printtemplate",),
        "partial_update": ("printing.change_printtemplate",),
        "destroy": ("printing.delete_printtemplate",),
    }
    queryset = PrintTemplate.objects.select_related("current_version")
    filterset_fields = ("template_type", "is_active")
    search_fields = ("slug", "name", "description")
    ordering_fields = ("slug", "name", "created_at", "updated_at")


class PrintTemplateVersionViewSet(
    mixins.CreateModelMixin,
    mixins.ListModelMixin,
    mixins.RetrieveModelMixin,
    viewsets.GenericViewSet,
):
    serializer_class = PrintTemplateVersionSerializer
    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {
        "list": ("printing.view_printtemplateversion",),
        "retrieve": ("printing.view_printtemplateversion",),
        "create": ("printing.add_printtemplateversion",),
        "publish": ("printing.change_printtemplateversion",),
        "update": ("printing.change_printtemplateversion",),
        "partial_update": ("printing.change_printtemplateversion",),
        "destroy": ("printing.delete_printtemplateversion",),
        "PUT": ("printing.change_printtemplateversion",),
        "PATCH": ("printing.change_printtemplateversion",),
        "DELETE": ("printing.delete_printtemplateversion",),
    }
    queryset = PrintTemplateVersion.objects.select_related("template", "created_by")
    filterset_fields = ("template", "status")
    search_fields = ("template__slug", "content")
    ordering_fields = ("created_at", "version_number", "published_at")

    @action(detail=True, methods=["post"])
    def publish(self, request, pk=None):
        version = publish_template_version(self.get_object())
        return Response(self.get_serializer(version).data)


class PrinterProfileViewSet(viewsets.ModelViewSet):
    serializer_class = PrinterProfileSerializer
    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {
        "list": ("printing.view_printerprofile",),
        "retrieve": ("printing.view_printerprofile",),
        "create": ("printing.add_printerprofile",),
        "update": ("printing.change_printerprofile",),
        "partial_update": ("printing.change_printerprofile",),
        "destroy": ("printing.delete_printerprofile",),
    }
    queryset = PrinterProfile.objects.all()
    filterset_fields = ("printer_type", "is_default", "is_active")
    search_fields = ("name",)
    ordering_fields = ("name", "created_at", "updated_at")


class PrintAgentViewSet(viewsets.ModelViewSet):
    serializer_class = PrintAgentSerializer
    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {
        "list": ("printing.view_printagent",),
        "retrieve": ("printing.view_printagent",),
        "create": ("printing.add_printagent",),
        "update": ("printing.change_printagent",),
        "partial_update": ("printing.change_printagent",),
        "destroy": ("printing.delete_printagent",),
    }
    queryset = PrintAgent.objects.select_related("printer_profile")
    filterset_fields = ("printer_profile", "is_active")
    search_fields = ("name", "identifier")
    ordering_fields = ("name", "created_at", "updated_at", "last_seen_at")


class PrintAuditEventViewSet(
    mixins.ListModelMixin,
    mixins.RetrieveModelMixin,
    viewsets.GenericViewSet,
):
    serializer_class = PrintAuditEventSerializer
    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {
        "list": ("printing.view_printauditevent",),
        "retrieve": ("printing.view_printauditevent",),
        "record": ("printing.add_printauditevent",),
        "report": ("printing.change_printauditevent",),
    }
    queryset = PrintAuditEvent.objects.select_related(
        "sale_order",
        "purchase_order",
        "print_job",
        "user",
        "agent",
    )
    filterset_fields = (
        "document_type",
        "action",
        "status",
        "sale_order",
        "purchase_order",
        "print_job",
        "agent",
        "user",
    )
    search_fields = (
        "document_number",
        "agent_identifier",
        "device_name",
        "printer_name",
        "message",
    )
    ordering_fields = ("created_at", "updated_at", "document_number")

    def get_queryset(self):
        queryset = super().get_queryset()
        user = self.request.user
        if not user.has_perm("sales.view_order"):
            queryset = queryset.exclude(
                document_type=PrintAuditEvent.DocumentType.SALE_ORDER,
            )
        elif not user_is_manager(user):
            queryset = queryset.filter(
                ~Q(document_type=PrintAuditEvent.DocumentType.SALE_ORDER)
                | Q(
                    document_type=PrintAuditEvent.DocumentType.SALE_ORDER,
                    sale_order__register_session__owner_key=(
                        self._register_session_owner_key()
                    ),
                )
            )
        if not user.has_perm("purchasing.view_purchaseorder"):
            queryset = queryset.exclude(
                document_type=PrintAuditEvent.DocumentType.PURCHASE_ORDER,
            )
        return queryset

    def _register_session_owner_key(self):
        if self.request.user.is_authenticated:
            return f"user:{self.request.user.pk}"
        return "anonymous"

    @action(detail=False, methods=["post"])
    def record(self, request):
        serializer = PrintAuditEventRecordSerializer(
            data=request.data,
            context=self.get_serializer_context(),
        )
        serializer.is_valid(raise_exception=True)
        audit_event = serializer.save()
        return Response(
            self.get_serializer(audit_event).data,
            status=status.HTTP_201_CREATED,
        )

    @action(detail=True, methods=["post"])
    def report(self, request, pk=None):
        serializer = PrintAuditEventReportSerializer(
            self.get_object(),
            data=request.data,
            context=self.get_serializer_context(),
        )
        serializer.is_valid(raise_exception=True)
        audit_event = serializer.save()
        return Response(self.get_serializer(audit_event).data)


class PrintJobViewSet(
    mixins.CreateModelMixin,
    mixins.ListModelMixin,
    mixins.RetrieveModelMixin,
    viewsets.GenericViewSet,
):
    serializer_class = PrintJobSerializer
    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {
        "list": ("printing.view_printjob",),
        "retrieve": ("printing.view_printjob",),
        "create": ("printing.add_printjob",),
        "events": ("printing.view_printjobevent",),
        "claim": ("printing.change_printjob",),
        "claim_next": ("printing.change_printjob",),
        "requeue": ("printing.change_printjob",),
        "cancel": ("printing.change_printjob",),
        "printed": ("printing.change_printjob",),
        "failed": ("printing.change_printjob",),
        "report": ("printing.change_printjob",),
    }
    queryset = (
        PrintJob.objects.select_related(
            "order",
            "template_version",
            "printer_profile",
            "claimed_by",
        )
        .prefetch_related("events__agent", "events__user")
        .all()
    )
    filterset_fields = ("job_type", "status", "order", "printer_profile", "claimed_by")
    search_fields = ("idempotency_key", "order__receipt_number", "error_message")
    ordering_fields = ("created_at", "updated_at", "priority", "attempts")

    @action(detail=True, methods=["get"])
    def events(self, request, pk=None):
        events = self.get_object().events.select_related("agent", "user")
        page = self.paginate_queryset(events)
        if page is not None:
            serializer = PrintJobEventSerializer(page, many=True)
            return self.get_paginated_response(serializer.data)
        return Response(PrintJobEventSerializer(events, many=True).data)

    @action(detail=False, methods=["post"], url_path="claim-next")
    def claim_next(self, request):
        serializer = PrintJobAgentActionSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        agent = serializer.validated_data["agent"]
        job = claim_next_print_job(
            agent,
            user=request.user,
            printer_endpoint=serializer.validated_data.get("printer_endpoint", {}),
        )
        if job is None:
            return Response(status=status.HTTP_204_NO_CONTENT)

        return Response(self.get_serializer(job).data)

    @action(detail=True, methods=["post"])
    def claim(self, request, pk=None):
        serializer = PrintJobAgentActionSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        agent = serializer.validated_data["agent"]
        job = self.get_object()
        try:
            claimed_job = claim_print_job(
                job,
                agent,
                user=request.user,
                printer_endpoint=serializer.validated_data.get("printer_endpoint", {}),
            )
        except ValueError:
            return Response(
                {"detail": "Only queued jobs can be claimed."},
                status=status.HTTP_400_BAD_REQUEST,
            )

        return Response(self.get_serializer(claimed_job).data)

    @action(detail=True, methods=["post"])
    def requeue(self, request, pk=None):
        job = self.get_object()
        if job.status in (PrintJob.Status.PRINTED, PrintJob.Status.CANCELED):
            return Response(
                {"detail": "Printed or canceled jobs cannot be requeued."},
                status=status.HTTP_400_BAD_REQUEST,
            )

        job.status = PrintJob.Status.QUEUED
        job.claimed_by = None
        job.claimed_at = None
        job.lease_expires_at = None
        job.failed_at = None
        job.error_message = ""
        job.save(
            update_fields=[
                "status",
                "claimed_by",
                "claimed_at",
                "lease_expires_at",
                "failed_at",
                "error_message",
                "updated_at",
            ]
        )
        create_job_event(
            job,
            PrintJobEvent.Type.REQUEUED,
            user=request.user,
            message="Print job requeued.",
        )
        return Response(self.get_serializer(job).data)

    @action(detail=True, methods=["post"])
    def cancel(self, request, pk=None):
        job = self.get_object()
        if job.status == PrintJob.Status.PRINTED:
            return Response(
                {"detail": "Printed jobs cannot be canceled."},
                status=status.HTTP_400_BAD_REQUEST,
            )
        if job.status != PrintJob.Status.CANCELED:
            job.status = PrintJob.Status.CANCELED
            job.lease_expires_at = None
            job.save(update_fields=["status", "lease_expires_at", "updated_at"])
            create_job_event(
                job,
                PrintJobEvent.Type.CANCELED,
                user=request.user,
                message="Print job canceled.",
            )
        return Response(self.get_serializer(job).data)

    @action(detail=True, methods=["post"])
    def printed(self, request, pk=None):
        serializer = PrintJobAgentActionSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        agent = serializer.validated_data["agent"]
        job = self.get_object()
        with transaction.atomic():
            job = PrintJob.objects.select_for_update().get(pk=job.pk)
            if job.status != PrintJob.Status.CLAIMED:
                return Response(
                    {"detail": "Only claimed jobs can be reported printed."},
                    status=status.HTTP_400_BAD_REQUEST,
                )
            if job.claimed_by_id is not None and job.claimed_by_id != agent.pk:
                return Response(
                    {"detail": "Only the claiming agent can report this job."},
                    status=status.HTTP_409_CONFLICT,
                )

            now = timezone.now()
            job.status = PrintJob.Status.PRINTED
            job.claimed_by = agent
            job.lease_expires_at = None
            job.printed_at = now
            job.error_message = ""
            job.save(
                update_fields=[
                    "status",
                    "claimed_by",
                    "lease_expires_at",
                    "printed_at",
                    "error_message",
                    "updated_at",
                ]
            )
            agent.last_seen_at = now
            agent.save(update_fields=["last_seen_at", "updated_at"])
            create_job_event(
                job,
                PrintJobEvent.Type.PRINTED,
                user=request.user,
                agent=agent,
                message="Print job completed.",
                metadata={
                    "printer_endpoint": serializer.validated_data.get(
                        "printer_endpoint",
                        {},
                    ),
                },
            )
        return Response(self.get_serializer(job).data)

    @action(detail=True, methods=["post"])
    def failed(self, request, pk=None):
        serializer = PrintJobFailureSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        agent = serializer.validated_data["agent"]
        job = self.get_object()
        with transaction.atomic():
            job = PrintJob.objects.select_for_update().get(pk=job.pk)
            if job.status != PrintJob.Status.CLAIMED:
                return Response(
                    {"detail": "Only claimed jobs can be reported failed."},
                    status=status.HTTP_400_BAD_REQUEST,
                )
            if job.claimed_by_id is not None and job.claimed_by_id != agent.pk:
                return Response(
                    {"detail": "Only the claiming agent can report this job."},
                    status=status.HTTP_409_CONFLICT,
                )

            now = timezone.now()
            job.status = PrintJob.Status.FAILED
            job.claimed_by = agent
            job.lease_expires_at = None
            job.failed_at = now
            job.error_message = serializer.validated_data.get("error_message", "")
            job.save(
                update_fields=[
                    "status",
                    "claimed_by",
                    "lease_expires_at",
                    "failed_at",
                    "error_message",
                    "updated_at",
                ]
            )
            agent.last_seen_at = now
            agent.save(update_fields=["last_seen_at", "updated_at"])
            create_job_event(
                job,
                PrintJobEvent.Type.FAILED,
                user=request.user,
                agent=agent,
                message=job.error_message,
                metadata={
                    "printer_endpoint": serializer.validated_data.get(
                        "printer_endpoint",
                        {},
                    ),
                },
            )
        return Response(self.get_serializer(job).data)

    @action(detail=True, methods=["post"])
    def report(self, request, pk=None):
        serializer = PrintJobReportSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        report_status = serializer.validated_data["status"]
        if report_status in (PrintJob.Status.PRINTED, "completed"):
            return self.printed(request, pk=pk)
        return self.failed(request, pk=pk)
