from rest_framework import viewsets

from .models import Payment
from .serializers import PaymentSerializer


class PaymentViewSet(viewsets.ModelViewSet):
    serializer_class = PaymentSerializer
    queryset = Payment.objects.select_related("order")
    filterset_fields = ("method", "order")
    search_fields = ("order__receipt_number", "external_reference")
    ordering_fields = ("created_at", "amount")
