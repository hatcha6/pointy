from django.contrib import admin
from django.urls import include, path
from drf_spectacular.views import SpectacularAPIView, SpectacularSwaggerView
from rest_framework.routers import DefaultRouter

from pointy.health import healthz, readyz
from apps.analytics.views import AnalyticsEventViewSet
from apps.attachments.views import AttachmentViewSet, StorageVolumeViewSet
from apps.attendance.views import (
    AttendanceDayViewSet,
    AttendanceProfileViewSet,
    AttendancePunchViewSet,
    BioTimeConnectionView,
    BioTimeSyncView,
    BioTimeTestConnectionView,
)
from apps.migration.views import (
    MigrationRunViewSet,
    MigrationSourceViewSet,
    MigrationSystemsView,
)
from apps.catalog.views import (
    ModifierGroupViewSet,
    ProductCategoryViewSet,
    ProductVariantViewSet,
    ProductViewSet,
    UnitOfMeasureViewSet,
    VariantOptionValueViewSet,
    VariantOptionViewSet,
)
from apps.channels.views import SalesChannelViewSet
from apps.customers.views import CustomerViewSet
from apps.operations.views import (
    AssetViewSet,
    BillOfMaterialsViewSet,
    JobViewSet,
    PublicJobView,
    WorkflowTemplateViewSet,
)
from apps.discounts.views import DiscountRuleViewSet
from apps.price_checker.views import (
    PriceCheckEventViewSet,
    PriceCheckerDeviceViewSet,
    price_lookup_view,
)
from apps.expenses.views import (
    ExpenseCategoryViewSet,
    ExpenseLedgerView,
    ExpenseViewSet,
)
from apps.employees.views import (
    CompensationPlanViewSet,
    EmployeeViewSet,
    EmployeeLoanViewSet,
    PayrollRunViewSet,
)
from apps.ai.views import (
    AiChatResumeView,
    AiChatView,
    AiConversationTruncateView,
    AiConversationViewSet,
    AiUsageView,
)
from apps.fraud.views import FraudFindingViewSet
from apps.core.views import (
    PosUserViewSet,
    ShopSettingsLogoView,
    ShopSettingsView,
    ShopSetupView,
    login_view,
    logout_view,
    me_view,
    password_change_view,
    setup_initial_admin_view,
    setup_status_view,
)
from apps.core.backup_views import (
    BackupDestinationListView,
    BackupOperationsView,
    RestoreUploadView,
)
from apps.core.dashboard import DashboardView
from apps.core.relay_views import (
    DiscoveryServiceView,
    RelayConnectorConfigView,
    RelayConnectorHeartbeatView,
    RelayInstallationView,
    RelayPairingView,
)
from apps.inventory.views import (
    StockCountViewSet,
    StockItemViewSet,
    StockMovementViewSet,
)
from apps.notifications.views import BusinessNotificationViewSet
from apps.payments.views import PaymentViewSet
from apps.printing.views import (
    PrepStationViewSet,
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
from apps.sales.views import OrderViewSet, PublicInvoiceView, RegisterSessionViewSet

router = DefaultRouter()
router.register("analytics-events", AnalyticsEventViewSet, basename="analytics-event")
router.register("users", PosUserViewSet, basename="pos-user")
router.register("employees", EmployeeViewSet, basename="employee")
router.register("employee-loans", EmployeeLoanViewSet, basename="employee-loan")
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
router.register("modifier-groups", ModifierGroupViewSet)
router.register("units-of-measure", UnitOfMeasureViewSet)
router.register("stock", StockItemViewSet)
router.register("stock-movements", StockMovementViewSet)
router.register("stock-counts", StockCountViewSet, basename="stock-count")
router.register("orders", OrderViewSet)
router.register("fraud-findings", FraudFindingViewSet, basename="fraud-finding")
router.register("customers", CustomerViewSet)
router.register("discount-rules", DiscountRuleViewSet)
router.register("expense-categories", ExpenseCategoryViewSet)
router.register("expenses", ExpenseViewSet)
router.register("suppliers", SupplierViewSet)
router.register("supplier-payments", SupplierPaymentViewSet)
router.register("purchase-orders", PurchaseOrderViewSet)
router.register("register-sessions", RegisterSessionViewSet, basename="register-session")
router.register("sales-channels", SalesChannelViewSet, basename="sales-channel")
router.register("jobs", JobViewSet, basename="job")
router.register("assets", AssetViewSet, basename="asset")
router.register(
    "workflow-templates",
    WorkflowTemplateViewSet,
    basename="workflow-template",
)
router.register("boms", BillOfMaterialsViewSet, basename="bom")
router.register("payments", PaymentViewSet)
router.register("print-templates", PrintTemplateViewSet)
router.register("print-template-versions", PrintTemplateVersionViewSet)
router.register("printer-profiles", PrinterProfileViewSet)
router.register("prep-stations", PrepStationViewSet)
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
    "attendance/profiles",
    AttendanceProfileViewSet,
    basename="attendance-profile",
)
router.register(
    "attendance/punches",
    AttendancePunchViewSet,
    basename="attendance-punch",
)
router.register("attendance/days", AttendanceDayViewSet, basename="attendance-day")
router.register(
    "migration/sources",
    MigrationSourceViewSet,
    basename="migration-source",
)
router.register(
    "migration/runs",
    MigrationRunViewSet,
    basename="migration-run",
)
router.register(
    "attachment-storage-volumes",
    StorageVolumeViewSet,
    basename="storagevolume",
)
router.register(
    "price-checker-devices",
    PriceCheckerDeviceViewSet,
    basename="price-checker-device",
)
router.register(
    "price-check-events",
    PriceCheckEventViewSet,
    basename="price-check-event",
)
router.register(
    "ai/conversations",
    AiConversationViewSet,
    basename="ai-conversation",
)

urlpatterns = [
    path("healthz/", healthz, name="healthz"),
    path("readyz/", readyz, name="readyz"),
    path("admin/", admin.site.urls),
    path("api/setup/status/", setup_status_view, name="setup-status"),
    path("api/setup/admin/", setup_initial_admin_view, name="setup-initial-admin"),
    path("api/auth/login/", login_view, name="auth-login"),
    path("api/auth/logout/", logout_view, name="auth-logout"),
    path("api/auth/me/", me_view, name="auth-me"),
    path(
        "api/auth/password/change/",
        password_change_view,
        name="auth-password-change",
    ),
    path("api/dashboard/", DashboardView.as_view(), name="dashboard"),
    path(
        "api/expense-ledger/",
        ExpenseLedgerView.as_view(),
        name="expense-ledger",
    ),
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
    path("api/ai/chat/", AiChatView.as_view(), name="ai-chat"),
    path("api/ai/chat/resume/", AiChatResumeView.as_view(), name="ai-chat-resume"),
    path("api/ai/usage/", AiUsageView.as_view(), name="ai-usage"),
    path(
        "api/ai/conversations/<int:pk>/truncate/",
        AiConversationTruncateView.as_view(),
        name="ai-conversation-truncate",
    ),
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
    path(
        "api/attendance/connection/",
        BioTimeConnectionView.as_view(),
        name="attendance-connection",
    ),
    path(
        "api/attendance/connection/test/",
        BioTimeTestConnectionView.as_view(),
        name="attendance-connection-test",
    ),
    path("api/attendance/sync/", BioTimeSyncView.as_view(), name="attendance-sync"),
    path(
        "api/migration/systems/",
        MigrationSystemsView.as_view(),
        name="migration-systems",
    ),
    path("api/shop-settings/", ShopSettingsView.as_view(), name="shop-settings"),
    path("api/shop-settings/setup/", ShopSetupView.as_view(), name="shop-setup"),
    path(
        "api/shop-settings/logo/",
        ShopSettingsLogoView.as_view(),
        name="shop-settings-logo",
    ),
    path(
        "api/public-invoices/<str:token>/",
        PublicInvoiceView.as_view({"get": "retrieve"}),
        name="public-invoice-detail",
    ),
    path(
        "api/public-jobs/<str:token>/",
        PublicJobView.as_view({"get": "retrieve"}),
        name="public-job-detail",
    ),
    path(
        "api/backup/destinations/",
        BackupDestinationListView.as_view(),
        name="backup-destinations",
    ),
    path("api/backup/", BackupOperationsView.as_view(), name="backup-operations"),
    path("api/backup/restore/", RestoreUploadView.as_view(), name="backup-restore"),
    path(
        "api/price-checker/lookup/",
        price_lookup_view,
        name="price-checker-lookup",
    ),
    path("api/", include(router.urls)),
    path("api/schema/", SpectacularAPIView.as_view(), name="schema"),
    path("api/docs/", SpectacularSwaggerView.as_view(url_name="schema"), name="swagger-ui"),
]
