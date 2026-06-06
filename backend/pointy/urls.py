from django.contrib import admin
from django.urls import include, path
from drf_spectacular.views import SpectacularAPIView, SpectacularSwaggerView
from rest_framework.routers import DefaultRouter

from apps.analytics.views import AnalyticsEventViewSet
from apps.attachments.views import AttachmentViewSet, StorageVolumeViewSet
from apps.catalog.views import (
    ProductCategoryViewSet,
    ProductVariantViewSet,
    ProductViewSet,
    VariantOptionValueViewSet,
    VariantOptionViewSet,
)
from apps.customers.views import CustomerViewSet
from apps.discounts.views import DiscountRuleViewSet
from apps.employees.views import (
    CompensationPlanViewSet,
    EmployeeViewSet,
    PayrollRunViewSet,
)
from apps.fraud.views import FraudFindingViewSet
from apps.core.views import (
    PosUserViewSet,
    ShopSettingsLogoView,
    ShopSettingsView,
    login_view,
    logout_view,
    me_view,
)
from apps.core.dashboard import DashboardView
from apps.core.relay_views import (
    DiscoveryServiceView,
    RelayConnectorConfigView,
    RelayConnectorHeartbeatView,
    RelayInstallationView,
    RelayPairingView,
)
from apps.inventory.views import StockItemViewSet, StockMovementViewSet
from apps.notifications.views import BusinessNotificationViewSet
from apps.payments.views import PaymentViewSet
from apps.printing.views import (
    PrinterProfileViewSet,
    PrintAgentViewSet,
    PrintAuditEventViewSet,
    PrintJobViewSet,
    PrintTemplateVersionViewSet,
    PrintTemplateViewSet,
)
from apps.purchasing.views import (
    PurchaseOrderViewSet,
    SupplierPaymentViewSet,
    SupplierViewSet,
)
from apps.reports.views import ReportRunViewSet
from apps.sales.views import OrderViewSet, RegisterSessionViewSet

router = DefaultRouter()
router.register("analytics-events", AnalyticsEventViewSet, basename="analytics-event")
router.register("users", PosUserViewSet, basename="pos-user")
router.register("employees", EmployeeViewSet, basename="employee")
router.register(
    "compensation-plans",
    CompensationPlanViewSet,
    basename="compensation-plan",
)
router.register("payroll-runs", PayrollRunViewSet, basename="payroll-run")
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
router.register("fraud-findings", FraudFindingViewSet, basename="fraud-finding")
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
router.register("print-audit-events", PrintAuditEventViewSet)
router.register("print-jobs", PrintJobViewSet)
router.register("reports", ReportRunViewSet, basename="report")
router.register(
    "business-notifications",
    BusinessNotificationViewSet,
    basename="business-notification",
)
router.register("attachments", AttachmentViewSet, basename="attachment")
router.register(
    "attachment-storage-volumes",
    StorageVolumeViewSet,
    basename="storagevolume",
)

urlpatterns = [
    path("admin/", admin.site.urls),
    path("api/auth/login/", login_view, name="auth-login"),
    path("api/auth/logout/", logout_view, name="auth-logout"),
    path("api/auth/me/", me_view, name="auth-me"),
    path("api/dashboard/", DashboardView.as_view(), name="dashboard"),
    path(
        "api/discovery/service/",
        DiscoveryServiceView.as_view(),
        name="discovery-service",
    ),
    path(
        "api/relay/installation/",
        RelayInstallationView.as_view(),
        name="relay-installation",
    ),
    path("api/relay/pairing/", RelayPairingView.as_view(), name="relay-pairing"),
    path(
        "api/relay/connector-config/",
        RelayConnectorConfigView.as_view(),
        name="relay-connector-config",
    ),
    path(
        "api/relay/connector-heartbeat/",
        RelayConnectorHeartbeatView.as_view(),
        name="relay-connector-heartbeat",
    ),
    path("api/shop-settings/", ShopSettingsView.as_view(), name="shop-settings"),
    path(
        "api/shop-settings/logo/",
        ShopSettingsLogoView.as_view(),
        name="shop-settings-logo",
    ),
    path("api/", include(router.urls)),
    path("api/schema/", SpectacularAPIView.as_view(), name="schema"),
    path("api/docs/", SpectacularSwaggerView.as_view(url_name="schema"), name="swagger-ui"),
]
