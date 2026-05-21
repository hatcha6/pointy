from django.contrib import admin
from django.urls import include, path
from drf_spectacular.views import SpectacularAPIView, SpectacularSwaggerView
from rest_framework.routers import DefaultRouter

from apps.catalog.views import (
    ProductCategoryViewSet,
    ProductVariantViewSet,
    ProductViewSet,
    VariantOptionValueViewSet,
    VariantOptionViewSet,
)
from apps.customers.views import CustomerViewSet
from apps.discounts.views import DiscountRuleViewSet
from apps.core.views import (
    PosUserViewSet,
    ShopSettingsView,
    login_view,
    logout_view,
    me_view,
)
from apps.core.dashboard import DashboardView
from apps.inventory.views import StockItemViewSet, StockMovementViewSet
from apps.payments.views import PaymentViewSet
from apps.printing.views import (
    PrinterProfileViewSet,
    PrintAgentViewSet,
    PrintJobViewSet,
    PrintTemplateVersionViewSet,
    PrintTemplateViewSet,
)
from apps.purchasing.views import (
    PurchaseOrderViewSet,
    SupplierPaymentViewSet,
    SupplierViewSet,
)
from apps.sales.views import OrderViewSet, RegisterSessionViewSet

router = DefaultRouter()
router.register("users", PosUserViewSet, basename="pos-user")
router.register("products", ProductViewSet)
router.register(
    "product-variants",
    ProductVariantViewSet,
    basename="product-variant",
)
router.register("product-categories", ProductCategoryViewSet)
router.register("variant-options", VariantOptionViewSet)
router.register("variant-option-values", VariantOptionValueViewSet)
router.register("stock", StockItemViewSet)
router.register("stock-movements", StockMovementViewSet)
router.register("orders", OrderViewSet)
router.register("customers", CustomerViewSet)
router.register("discount-rules", DiscountRuleViewSet)
router.register("suppliers", SupplierViewSet)
router.register("supplier-payments", SupplierPaymentViewSet)
router.register("purchase-orders", PurchaseOrderViewSet)
router.register("register-sessions", RegisterSessionViewSet, basename="register-session")
router.register("payments", PaymentViewSet)
router.register("print-templates", PrintTemplateViewSet)
router.register("print-template-versions", PrintTemplateVersionViewSet)
router.register("printer-profiles", PrinterProfileViewSet)
router.register("print-agents", PrintAgentViewSet)
router.register("print-jobs", PrintJobViewSet)

urlpatterns = [
    path("admin/", admin.site.urls),
    path("api/auth/login/", login_view, name="auth-login"),
    path("api/auth/logout/", logout_view, name="auth-logout"),
    path("api/auth/me/", me_view, name="auth-me"),
    path("api/dashboard/", DashboardView.as_view(), name="dashboard"),
    path("api/shop-settings/", ShopSettingsView.as_view(), name="shop-settings"),
    path("api/", include(router.urls)),
    path("api/schema/", SpectacularAPIView.as_view(), name="schema"),
    path("api/docs/", SpectacularSwaggerView.as_view(url_name="schema"), name="swagger-ui"),
]
