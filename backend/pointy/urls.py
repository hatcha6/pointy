from django.contrib import admin
from django.urls import include, path
from drf_spectacular.views import SpectacularAPIView, SpectacularSwaggerView
from rest_framework.routers import DefaultRouter

from apps.catalog.views import ProductViewSet
from apps.inventory.views import StockItemViewSet
from apps.payments.views import PaymentViewSet
from apps.sales.views import OrderViewSet

router = DefaultRouter()
router.register("products", ProductViewSet)
router.register("stock", StockItemViewSet)
router.register("orders", OrderViewSet)
router.register("payments", PaymentViewSet)

urlpatterns = [
    path("admin/", admin.site.urls),
    path("api/", include(router.urls)),
    path("api/schema/", SpectacularAPIView.as_view(), name="schema"),
    path("api/docs/", SpectacularSwaggerView.as_view(url_name="schema"), name="swagger-ui"),
]
