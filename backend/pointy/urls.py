from django.contrib import admin
from django.urls import include, path
from drf_spectacular.views import SpectacularAPIView, SpectacularSwaggerView
from rest_framework.routers import DefaultRouter

from apps.catalog.views import ProductViewSet
from apps.core.views import (
    PosUserViewSet,
    ShopSettingsView,
    login_view,
    logout_view,
    me_view,
)
from apps.inventory.views import StockItemViewSet
from apps.payments.views import PaymentViewSet
from apps.sales.views import OrderViewSet, RegisterSessionViewSet

router = DefaultRouter()
router.register("users", PosUserViewSet, basename="pos-user")
router.register("products", ProductViewSet)
router.register("stock", StockItemViewSet)
router.register("orders", OrderViewSet)
router.register("register-sessions", RegisterSessionViewSet, basename="register-session")
router.register("payments", PaymentViewSet)

urlpatterns = [
    path("admin/", admin.site.urls),
    path("api/auth/login/", login_view, name="auth-login"),
    path("api/auth/logout/", logout_view, name="auth-logout"),
    path("api/auth/me/", me_view, name="auth-me"),
    path("api/shop-settings/", ShopSettingsView.as_view(), name="shop-settings"),
    path("api/", include(router.urls)),
    path("api/schema/", SpectacularAPIView.as_view(), name="schema"),
    path("api/docs/", SpectacularSwaggerView.as_view(url_name="schema"), name="swagger-ui"),
]
