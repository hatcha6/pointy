"""Routes for the invoice intake, mounted under ``/api/`` by ``pointy.urls``.

A ``SimpleRouter`` rather than a ``DefaultRouter``: the project router already
owns the ``api-root`` view under this prefix, and a second one would collide
with it on reverse.
"""

from rest_framework.routers import SimpleRouter

from .views import InvoiceIntakeViewSet

router = SimpleRouter()
router.register("invoice-intakes", InvoiceIntakeViewSet, basename="invoice-intake")

urlpatterns = router.urls
