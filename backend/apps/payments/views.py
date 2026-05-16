from rest_framework import viewsets
from rest_framework.permissions import IsAuthenticated

from apps.core.permissions import HasPointyPermission
from apps.core.roles import user_is_manager
from .models import Payment
from .serializers import PaymentSerializer


def payment_owner_key(request):
    return f"user:{request.user.pk}"


class PaymentViewSet(viewsets.ModelViewSet):
    serializer_class = PaymentSerializer
    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {
        "list": ("payments.view_payment",),
        "retrieve": ("payments.view_payment",),
        "create": ("payments.add_payment",),
        "update": ("payments.change_payment",),
        "partial_update": ("payments.change_payment",),
        "destroy": ("payments.delete_payment",),
    }
    queryset = Payment.objects.select_related("order")
    filterset_fields = ("method", "order")
    search_fields = ("order__receipt_number", "external_reference")
    ordering_fields = ("created_at", "amount")

    def get_queryset(self):
        queryset = super().get_queryset()
        if user_is_manager(self.request.user):
            return queryset
        return queryset.filter(
            order__register_session__owner_key=payment_owner_key(self.request)
        )
