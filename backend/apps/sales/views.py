from rest_framework import viewsets

from .models import Order
from .serializers import OrderSerializer


class OrderViewSet(viewsets.ModelViewSet):
    serializer_class = OrderSerializer
    queryset = Order.objects.prefetch_related("lines__product")
    filterset_fields = ("status",)
    search_fields = ("receipt_number",)
    ordering_fields = ("created_at", "total")
