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
    IntegrationChargeView,
    IntegrationFloatView,
    IntegrationHistoryView,
    IntegrationLookupView,
    IntegrationPricesView,
    IntegrationProbeView,
    IntegrationSearchesView,
    IntegrationProfilesView,
    IntegrationSubscriberView,
    IntegrationVerificationConfirmView,
    IntegrationVerificationSendView,
    IntegrationVerificationView,
    IntegrationVoucherView,
)

urlpatterns = [
    path("", IntegrationCatalogView.as_view(), name="integrations-catalog"),
    # Two segments, so it can never be mistaken for a provider key.
    path(
        "fulfillments/charge/",
        IntegrationChargeView.as_view(),
        name="integrations-charge",
    ),
    # Till-facing: one card product's live availability, for its picker.
    # Addressed by product — the till knows the product, and the product
    # knows whose shelf it came off.
    path(
        "vouchers/<int:product_id>/",
        IntegrationVoucherView.as_view(),
        name="integrations-vouchers",
    ),
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
    # Till-facing: the searches that found something, newest first.
    path(
        "<str:provider>/searches/",
        IntegrationSearchesView.as_view(),
        name="integrations-searches",
    ),
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
    # Shop Settings: trusting this Pointy as a device the provider knows.
    path(
        "<str:provider>/verification/",
        IntegrationVerificationView.as_view(),
        name="integrations-verification",
    ),
    path(
        "<str:provider>/verification/send/",
        IntegrationVerificationSendView.as_view(),
        name="integrations-verification-send",
    ),
    path(
        "<str:provider>/verification/confirm/",
        IntegrationVerificationConfirmView.as_view(),
        name="integrations-verification-confirm",
    ),
    # Shop Settings: which of the login's profiles (shops) Pointy buys as.
    path(
        "<str:provider>/profiles/",
        IntegrationProfilesView.as_view(),
        name="integrations-profiles",
    ),
]
