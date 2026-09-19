"""The collapse's API: propose, review, edit, approve.

Read-heavy and edit-by-the-row, because that is what §12.4 asks for — the
low-confidence rows listed first and individually editable, and nothing written
until the owner approves. The write actions are deliberately small: change one
row, rename one product, say yes. There is no "apply" here at all; applying is
an ordinary import run that names the plan, which is what keeps the collapse and
the rest of the migration one operation rather than two.
"""

from __future__ import annotations

from rest_framework import status, viewsets
from rest_framework.decorators import action
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response

from apps.core.permissions import HasPointyPermission

from .collapse.planner import recompute_stats
from .collapse_serializers import (
    CollapseCandidateSerializer,
    CollapseClusterSerializer,
    CollapsePlanSerializer,
    CollapseRenameSerializer,
)
from .models import CollapseCandidate, CollapsePlan
from .services import approve_collapse_plan, rename_collapse_cluster


class CollapsePlanViewSet(viewsets.ReadOnlyModelViewSet):
    """Proposals. Created by ``sources/{id}/collapse/``, never by a plain POST."""

    serializer_class = CollapsePlanSerializer
    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {
        "list": ("migration.view_migrationsource",),
        "retrieve": ("migration.view_migrationsource",),
        "clusters": ("migration.view_migrationsource",),
        "candidates": ("migration.view_migrationsource",),
        "configure": ("migration.add_migrationrun",),
        "rename": ("migration.add_migrationrun",),
        "approve": ("migration.add_migrationrun",),
    }
    queryset = CollapsePlan.objects.select_related("source", "asset_type")
    filterset_fields = ("source", "status")

    @action(detail=True, methods=["get"])
    def clusters(self, request, pk=None):
        """The proposal as products — the "340 → 12" screen's own payload."""
        return Response(CollapseClusterSerializer.for_plan(self.get_object()))

    @action(detail=True, methods=["get"])
    def candidates(self, request, pk=None):
        """Every legacy row, **least confident first**.

        The order is the point. A person reviewing 340 rows has time for the
        twenty that are actually uncertain, and a screen that opened on the
        alphabet would spend that time on the ones that were already right.
        """
        plan = self.get_object()
        queryset = plan.candidates.all()
        decision = request.query_params.get("decision")
        if decision:
            queryset = queryset.filter(decision=decision)
        stem_key = request.query_params.get("stem_key")
        if stem_key is not None:
            queryset = queryset.filter(stem_key=stem_key)
        if request.query_params.get("needs_review") in ("1", "true", "yes"):
            from .collapse.extract import LOW_CONFIDENCE

            queryset = queryset.filter(
                decision=CollapseCandidate.Decision.COLLAPSE,
                confidence__lt=LOW_CONFIDENCE,
            )
        search = (request.query_params.get("search") or "").strip()
        if search:
            queryset = queryset.filter(source_name__icontains=search)
        page = self.paginate_queryset(queryset)
        if page is not None:
            return self.get_paginated_response(CollapseCandidateSerializer(page, many=True).data)
        return Response(CollapseCandidateSerializer(queryset, many=True).data)

    # Named ``configure`` rather than ``settings``: DRF's own ``APIView.settings``
    # is the api_settings object every request reads, and an action method of
    # that name replaces it — every error in this viewset then dies inside the
    # exception handler instead of being returned.
    @action(detail=True, methods=["patch"], url_path="settings")
    def configure(self, request, pk=None):
        """Plan-wide choices: what kind of thing these are, and the warranty."""
        plan = self.get_object()
        serializer = CollapsePlanSerializer(plan, data=request.data, partial=True)
        serializer.is_valid(raise_exception=True)
        serializer.save()
        return Response(serializer.data)

    @action(detail=True, methods=["post"])
    def rename(self, request, pk=None):
        """Rename a proposed product — and thereby merge it into another."""
        plan = self.get_object()
        serializer = CollapseRenameSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        moved = rename_collapse_cluster(
            plan,
            stem_key=serializer.validated_data["stem_key"],
            stem=serializer.validated_data["stem"],
        )
        plan.refresh_from_db()
        return Response(
            {
                "moved": moved,
                "plan": CollapsePlanSerializer(plan).data,
                "clusters": CollapseClusterSerializer.for_plan(plan),
            }
        )

    @action(detail=True, methods=["post"])
    def approve(self, request, pk=None):
        plan = approve_collapse_plan(self.get_object(), user=request.user)
        return Response(CollapsePlanSerializer(plan).data)


class CollapseCandidateViewSet(viewsets.GenericViewSet):
    """One row of a proposal, edited by a person who disagrees with the parser."""

    serializer_class = CollapseCandidateSerializer
    permission_classes = [IsAuthenticated, HasPointyPermission]
    http_method_names = ["get", "patch", "head", "options"]
    permission_map = {
        "retrieve": ("migration.view_migrationsource",),
        "partial_update": ("migration.add_migrationrun",),
    }
    queryset = CollapseCandidate.objects.select_related("plan")

    def retrieve(self, request, pk=None):
        return Response(CollapseCandidateSerializer(self.get_object()).data)

    def partial_update(self, request, pk=None):
        candidate = self.get_object()
        serializer = CollapseCandidateSerializer(candidate, data=request.data, partial=True)
        serializer.is_valid(raise_exception=True)
        serializer.save()
        # The headline is recomputed here rather than on read, so "12 products"
        # can never be a memory of the answer before this edit.
        stats = recompute_stats(candidate.plan)
        return Response(
            {"candidate": serializer.data, "stats": stats},
            status=status.HTTP_200_OK,
        )
