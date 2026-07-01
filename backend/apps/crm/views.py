from __future__ import annotations

from django.shortcuts import get_object_or_404
from rest_framework import viewsets
from rest_framework.decorators import action
from rest_framework.exceptions import ValidationError
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from rest_framework.views import APIView

from apps.core.permissions import HasPointyPermission
from apps.customers.models import Customer
from apps.messaging.serializers import OutboundMessageSerializer
from apps.messaging.services import NoGatewayConfigured

from .campaigns import InvalidCampaignState, approve_and_send, preview_campaign
from .consent import apply_consent, consent_state
from .models import Campaign, ConsentEvent, Conversation
from .transactional import NoRecipientPhone, send_invoice_sms
from .serializers import (
    CampaignDetailSerializer,
    CampaignSerializer,
    ConversationDetailSerializer,
    ConversationMessageSerializer,
    ConversationSerializer,
)
from .services import post_reply


class ConversationViewSet(viewsets.ReadOnlyModelViewSet):
    queryset = Conversation.objects.select_related("customer").all()
    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {
        "list": ("crm.view_conversations",),
        "retrieve": ("crm.view_conversations",),
        "reply": ("crm.manage_conversations",),
        "mark_read": ("crm.view_conversations",),
        "close": ("crm.manage_conversations",),
    }

    def get_serializer_class(self):
        if self.action == "retrieve":
            return ConversationDetailSerializer
        return ConversationSerializer

    def get_queryset(self):
        queryset = super().get_queryset()
        status = self.request.query_params.get("status")
        if status:
            queryset = queryset.filter(status=status)
        if self.action == "retrieve":
            queryset = queryset.prefetch_related("messages")
        return queryset

    @action(detail=True, methods=["post"])
    def reply(self, request, pk=None):
        conversation = self.get_object()
        body = (request.data.get("body") or "").strip()
        if not body:
            return Response({"detail": "نص الرسالة مطلوب."}, status=400)
        try:
            message = post_reply(conversation, body, author=request.user)
        except NoGatewayConfigured:
            return Response({"detail": "لا توجد بوابة رسائل مُفعّلة."}, status=400)
        return Response(ConversationMessageSerializer(message).data, status=201)

    @action(detail=True, methods=["post"])
    def mark_read(self, request, pk=None):
        conversation = self.get_object()
        Conversation.objects.filter(pk=conversation.pk).update(unread_count=0)
        conversation.refresh_from_db()
        return Response(ConversationSerializer(conversation).data)

    @action(detail=True, methods=["post"])
    def close(self, request, pk=None):
        conversation = self.get_object()
        conversation.status = Conversation.Status.CLOSED
        conversation.save(update_fields=["status", "updated_at"])
        return Response(ConversationSerializer(conversation).data)


class CustomerConsentView(APIView):
    """Read + set a customer's contact consent. Every change is recorded as a
    ConsentEvent (source=admin_ui). Independent toggles: ``marketing_opted_out``
    and ``do_not_contact``.
    """

    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {
        "GET": ("crm.manage_consent",),
        "POST": ("crm.manage_consent",),
    }

    def get(self, request, customer_id):
        customer = get_object_or_404(Customer, pk=customer_id)
        return Response(consent_state(customer))

    def post(self, request, customer_id):
        customer = get_object_or_404(Customer, pk=customer_id)
        note = (request.data.get("note") or "").strip()
        if "marketing_opted_out" in request.data:
            action = (
                ConsentEvent.Action.OPT_OUT
                if request.data.get("marketing_opted_out")
                else ConsentEvent.Action.OPT_IN
            )
            apply_consent(
                customer,
                action,
                source=ConsentEvent.Source.ADMIN_UI,
                phone=customer.phone,
                note=note,
            )
        if "do_not_contact" in request.data:
            action = (
                ConsentEvent.Action.DO_NOT_CONTACT
                if request.data.get("do_not_contact")
                else ConsentEvent.Action.ALLOW_CONTACT
            )
            apply_consent(
                customer,
                action,
                source=ConsentEvent.Source.ADMIN_UI,
                phone=customer.phone,
                note=note,
            )
        customer.refresh_from_db()
        return Response(consent_state(customer))


class SendInvoiceSmsView(APIView):
    """Send an order's invoice to its customer by SMS (transactional)."""

    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {"POST": ("sales.view_order",)}

    def post(self, request, order_id):
        from apps.sales.models import Order

        order = get_object_or_404(Order, pk=order_id)
        try:
            message = send_invoice_sms(order, actor=request.user)
        except NoRecipientPhone:
            return Response({"detail": "لا يوجد رقم هاتف للعميل."}, status=400)
        except NoGatewayConfigured:
            return Response({"detail": "لا توجد بوابة رسائل مُفعّلة."}, status=400)
        return Response(OutboundMessageSerializer(message).data, status=201)


class CampaignViewSet(viewsets.ModelViewSet):
    """CRUD for campaigns (create = draft only) plus preview / send / cancel.

    ``send`` is the only path that dispatches SMS and is gated by the human-only
    ``crm.send_campaigns`` permission — no generic write and no AI tool can reach
    it, and ``status`` is read-only so a create/update can never bypass it.
    """

    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {
        "list": ("crm.manage_campaigns",),
        "retrieve": ("crm.manage_campaigns",),
        "create": ("crm.manage_campaigns",),
        "update": ("crm.manage_campaigns",),
        "partial_update": ("crm.manage_campaigns",),
        "destroy": ("crm.manage_campaigns",),
        "preview": ("crm.manage_campaigns",),
        "send": ("crm.send_campaigns",),
        "cancel": ("crm.send_campaigns",),
    }

    def get_serializer_class(self):
        if self.action == "retrieve":
            return CampaignDetailSerializer
        return CampaignSerializer

    def get_queryset(self):
        queryset = Campaign.objects.all()
        if self.action == "retrieve":
            queryset = queryset.prefetch_related("recipients__customer")
        status_filter = self.request.query_params.get("status")
        if status_filter:
            queryset = queryset.filter(status=status_filter)
        return queryset

    def perform_create(self, serializer):
        serializer.save(
            created_by=self.request.user,
            created_via=Campaign.CreatedVia.HUMAN,
            status=Campaign.Status.DRAFT,
        )

    def perform_destroy(self, instance):
        if instance.status in (Campaign.Status.SENDING, Campaign.Status.SENT):
            raise ValidationError("لا يمكن حذف حملة قيد الإرسال أو مُرسَلة.")
        instance.delete()

    @action(detail=True, methods=["post"])
    def preview(self, request, pk=None):
        return Response(preview_campaign(self.get_object()))

    @action(detail=True, methods=["post"])
    def send(self, request, pk=None):
        campaign = self.get_object()
        try:
            approve_and_send(campaign, actor=request.user)
        except InvalidCampaignState:
            return Response(
                {"detail": "لا يمكن إرسال هذه الحملة في حالتها الحالية."},
                status=400,
            )
        return Response(CampaignSerializer(campaign).data)

    @action(detail=True, methods=["post"])
    def cancel(self, request, pk=None):
        campaign = self.get_object()
        campaign.status = Campaign.Status.CANCELLED
        campaign.save(update_fields=["status", "updated_at"])
        return Response(CampaignSerializer(campaign).data)
