"""Routes for Shop Settings → Integrations.

Its own module (mounted at ``api/integrations/``) rather than rows on the
project router: the resource is keyed by provider key, not by a database id,
so there is nothing for a ModelViewSet to be a viewset *of*.
"""

from django.urls import path

from .views import (
    IntegrationAccountView,
    IntegrationCardView,
    IntegrationCatalogView,
    IntegrationFloatView,
    IntegrationHistoryView,
    IntegrationLookupView,
    IntegrationPricesView,
    IntegrationProbeView,
    IntegrationSubscriberView,
)

urlpatterns = [
    path("", IntegrationCatalogView.as_view(), name="integrations-catalog"),
    path("<str:provider>/", IntegrationAccountView.as_view(), name="integrations-account"),
    path("<str:provider>/probe/", IntegrationProbeView.as_view(), name="integrations-probe"),
    path(
        "<str:provider>/float/",
        IntegrationFloatView.as_view(),
        name="integrations-float",
    ),
    path(
        "<str:provider>/prices/",
        IntegrationPricesView.as_view(),
        name="integrations-prices",
    ),
    path("<str:provider>/lookup/", IntegrationLookupView.as_view(), name="integrations-lookup"),
    # Till-facing: one call for the card, its live prices and the cart variant.
    path("<str:provider>/card/", IntegrationCardView.as_view(), name="integrations-card"),
    path(
        "<str:provider>/subscribers/<str:subscriber_ref>/",
        IntegrationSubscriberView.as_view(),
        name="integrations-subscriber",
    ),
    path(
        "<str:provider>/history/",
        IntegrationHistoryView.as_view(),
        name="integrations-history",
    ),
]
