from django.db import IntegrityError, transaction
from django.utils import timezone
from rest_framework import mixins, serializers, status, viewsets
from rest_framework.decorators import action
from rest_framework.response import Response

from .models import Order, RegisterSession
from .serializers import (
    CheckoutSerializer,
    OrderSerializer,
    RegisterSessionCloseSerializer,
    RegisterSessionSerializer,
    RegisterSessionStartSerializer,
)


class OrderViewSet(viewsets.ModelViewSet):
    serializer_class = OrderSerializer
    queryset = Order.objects.select_related("register_session").prefetch_related(
        "lines__product"
    )
    filterset_fields = ("status", "register_session", "register_session__status")
    search_fields = ("receipt_number", "lines__product__name", "lines__product__sku")
    ordering_fields = ("created_at", "updated_at", "total", "receipt_number")

    def _open_register_session(self, request):
        return RegisterSession.objects.filter(
            owner_key=register_session_owner_key(request),
            status=RegisterSession.Status.OPEN,
        ).first()

    def perform_create(self, serializer):
        session = self._open_register_session(self.request)
        if session is None:
            raise serializers.ValidationError(
                {"detail": "No open register session for this request owner."}
            )
        serializer.save(register_session=session)

    @action(detail=False, methods=["post"])
    def checkout(self, request):
        session = self._open_register_session(request)
        if session is None:
            return Response(
                {"detail": "No open register session for this request owner."},
                status=status.HTTP_400_BAD_REQUEST,
            )

        serializer = CheckoutSerializer(
            data=request.data,
            context={"register_session": session},
        )
        serializer.is_valid(raise_exception=True)
        order = serializer.save()
        return Response(OrderSerializer(order).data, status=status.HTTP_201_CREATED)


def register_session_owner_key(request):
    if request.user.is_authenticated:
        return f"user:{request.user.pk}"
    return "anonymous"


def register_session_owner(request):
    if request.user.is_authenticated:
        return request.user
    return None


class RegisterSessionViewSet(
    mixins.ListModelMixin,
    mixins.RetrieveModelMixin,
    viewsets.GenericViewSet,
):
    serializer_class = RegisterSessionSerializer
    queryset = RegisterSession.objects.select_related("owner")

    def get_queryset(self):
        return super().get_queryset().filter(owner_key=register_session_owner_key(self.request))

    @action(detail=True, methods=["get"])
    def orders(self, request, pk=None):
        session = self.get_object()
        orders = (
            session.orders.select_related("register_session")
            .prefetch_related("lines__product")
            .order_by("-created_at")
        )
        return Response(OrderSerializer(orders, many=True).data)

    @action(detail=False, methods=["get"])
    def current(self, request):
        session = self.get_queryset().filter(status=RegisterSession.Status.OPEN).first()
        if session is None:
            return Response(status=status.HTTP_204_NO_CONTENT)
        return Response(self.get_serializer(session).data)

    @action(detail=False, methods=["post"])
    def start(self, request):
        serializer = RegisterSessionStartSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)

        owner_key = register_session_owner_key(request)
        defaults = {
            "owner": register_session_owner(request),
            "opening_cash": serializer.validated_data.get("opening_cash", 0),
        }

        try:
            with transaction.atomic():
                session = (
                    RegisterSession.objects.select_for_update()
                    .filter(owner_key=owner_key, status=RegisterSession.Status.OPEN)
                    .first()
                )
                if session is None:
                    session = RegisterSession.objects.create(owner_key=owner_key, **defaults)
        except IntegrityError:
            session = RegisterSession.objects.get(
                owner_key=owner_key,
                status=RegisterSession.Status.OPEN,
            )

        return Response(self.get_serializer(session).data)

    @action(detail=True, methods=["post"])
    def close(self, request, pk=None):
        session = self.get_object()
        if session.status != RegisterSession.Status.OPEN:
            return Response(
                {"detail": "Register session is already closed."},
                status=status.HTTP_400_BAD_REQUEST,
            )

        serializer = RegisterSessionCloseSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)

        for field, value in serializer.validated_data.items():
            setattr(session, field, value)
        session.status = RegisterSession.Status.CLOSED
        session.closed_at = timezone.now()
        session.save(
            update_fields=[
                "status",
                "closing_cash",
                "count_025",
                "count_050",
                "count_075",
                "count_100",
                "closed_at",
                "updated_at",
            ]
        )

        return Response(self.get_serializer(session).data)
