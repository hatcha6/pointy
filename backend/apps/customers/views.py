from rest_framework import viewsets
from rest_framework.permissions import IsAuthenticated

from apps.core.permissions import HasPointyPermission
from .models import Customer
from .serializers import CustomerSerializer


class CustomerViewSet(viewsets.ModelViewSet):
    serializer_class = CustomerSerializer
    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {
        "list": ("customers.view_customer",),
        "retrieve": ("customers.view_customer",),
        "create": ("customers.add_customer",),
        "update": ("customers.change_customer",),
        "partial_update": ("customers.change_customer",),
        "destroy": ("customers.delete_customer",),
    }
    queryset = Customer.objects.all()
    filterset_fields = ("is_active", "gender", "marketing_consent")
    search_fields = (
        "customer_number",
        "full_name",
        "phone",
        "email",
    )
    ordering_fields = (
        "full_name",
        "created_at",
        "updated_at",
        "birthday",
        "customer_number",
    )
