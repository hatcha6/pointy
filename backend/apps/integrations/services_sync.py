"""Keeping the shop's copy of the services directory.

The company's relay publishes one directory — every country, the operators whose
phones can be topped up there, the billers whose bills can be paid — and names
each edition with an ``ETag``. The shop mirrors it into
:class:`~apps.integrations.models.IntegrationServiceCountry`, one row per
country, every five minutes (``integrations.sync_relay_services``), so the
till's screens read their own database and never wait on the relay.

Three rules, all inherited from the card shelf (:mod:`.vouchers`):

**One conditional read.** The edition the mirror holds is sent back as
``If-None-Match``; an unchanged directory answers ``304`` and *nothing is
written* — no row, no config key, no catalog version. The edition is only ever
sent while the mirror still holds rows, and only for the shape of mirror this
code writes (``services_mirror.SCHEMA``): a factory reset empties the mirror, and
an "unchanged" answer to either would leave it empty for good.

**Only what changed is written.** Each country row carries a digest of what the
relay said about it; a changed edition rewrites the countries whose digest moved
and no others, and drops the ones the relay stopped listing.

**One bad country is one bad country.** The driver leaves out whatever it cannot
read; a country the relay *lists* but the driver could not read keeps the row it
had (``skipped``) instead of vanishing from every till for want of a parser.

Flags are fetched after the rows are written, through the same image path and
with the same per-sweep limit as the card shelf's regions (:mod:`.voucher_flags`),
whether or not the directory changed: a flag that could not be had is asked for
again an hour later, and that must not wait for the next edition.
"""

from __future__ import annotations

import hashlib
import json
import logging
from dataclasses import dataclass

from django.db import transaction
from django.utils import timezone

from . import catalog, services_logos, services_mirror, services_options, switches, voucher_flags
from .models import IntegrationAccount, IntegrationServiceCountry
from .providers import provider_for
from .providers.base import ERROR_UNAVAILABLE
from .provisioning import service_variant_for
from .vouchers import _update_config

logger = logging.getLogger(__name__)

#: A country the relay reaches ranks after the popular ones, in the relay's order.
_UNRANKED_FROM = 1000


@dataclass
class SyncReport:
    """What one pass did."""

    provider: str = ""
    ok: bool = True
    error_code: str = ""
    #: Countries the relay listed that could be read.
    countries: int = 0
    #: Countries written (new, changed or dropped).
    changed: int = 0
    #: The relay said the directory is unchanged: nothing was written.
    not_modified: bool = False
    #: Flags this pass changed.
    flags: int = 0

    def as_dict(self) -> dict:
        return {
            "provider": self.provider,
            "ok": self.ok,
            "error_code": self.error_code,
            "countries": self.countries,
            "changed": self.changed,
            "not_modified": self.not_modified,
            "flags": self.flags,
        }


# --- who takes part ---------------------------------------------------------------
def sells_services(account) -> bool:
    spec = account.spec
    return spec is not None and (
        catalog.CAPABILITY_AIRTIME in spec.capabilities
        or catalog.CAPABILITY_BILLS in spec.capabilities
    )


def service_accounts():
    """Every connected account that sells services and is not switched off."""
    for account in switches.running(IntegrationAccount.objects.filter(is_active=True)):
        if sells_services(account) and account.spec.is_available and account.is_configured:
            yield account


def sync_all() -> dict:
    """The periodic sweep: every services account; one failure never stops the rest."""
    reports = []
    for account in service_accounts():
        try:
            reports.append(sync_account(account).as_dict())
        except Exception:  # pragma: no cover - a driver bug must not stop the sweep
            logger.exception("services sync crashed for %s", account.provider)
            reports.append({"provider": account.provider, "ok": False})
    return {"accounts": reports}


# --- the sweep ------------------------------------------------------------------------
def sync_account(account, *, flag_limit: int = voucher_flags.FLAGS_PER_SWEEP) -> SyncReport:
    """Mirror the relay's directory. Never raises on a relay error."""
    report = SyncReport(provider=account.provider)
    result = provider_for(account).services_directory(_directory_etag(account))
    if not result.ok:
        report.ok = False
        report.error_code = result.error_code
        _note_error(account, result.error_code)
        return report
    if result.not_modified:
        report.not_modified = True
        _note_unchanged(account)
        report.flags = _sync_flags(account, flag_limit)
        _sync_logos(account)
        return report
    report.countries = len(result.countries)
    if not result.countries and _holds_rows(account):
        if result.configured and result.priced:
            # A relay that lists nothing yet says it is set up has not loaded
            # its directory: keep what the mirror holds rather than empty every
            # till. The edition is not remembered, so the next sweep reads it
            # again.
            report.ok = False
            report.error_code = "empty_directory"
        else:
            # Not set up, or no rate to price by: say so, and keep the copy
            # (and the flags fetched for it) for the day it is.
            _write_config(account, result, now=timezone.now(), changed=0)
        return report
    report.changed = apply_directory(account, result)
    if report.changed:
        _ensure_service_variants(account)
    report.flags = _sync_flags(account, flag_limit)
    _sync_logos(account)
    return report


def _ensure_service_variants(account) -> None:
    """Make the service products the till's cards point at, here.

    Under the sweep's lock, once — rather than by the first two tills to open the
    menu in the same moment, each trying to make the same product. Never an error:
    the menu makes them itself when they are missing.
    """
    rows = IntegrationServiceCountry.objects.filter(account=account)
    wanted = []
    if rows.filter(airtime_count__gt=0).exists():
        wanted.append(services_options.KIND_AIRTIME)
    if rows.filter(bills_count__gt=0).exists():
        wanted.append(services_options.KIND_BILL)
    for kind in wanted:
        try:
            service_variant_for(account.provider, kind)
        except Exception:  # pragma: no cover - the menu will try again
            logger.warning("could not make the %s service product", kind, exc_info=True)


def _holds_rows(account) -> bool:
    return IntegrationServiceCountry.objects.filter(account=account).exists()


def _directory_etag(account) -> str:
    """The edition to ask "has it changed?" about, or ``""`` to read it all.

    Only while the mirror still holds that edition, written by this shape of
    mirror (see the module note).
    """
    config = account.config or {}
    etag = str(config.get(services_mirror.CONFIG_ETAG) or "")
    if not etag or config.get(services_mirror.CONFIG_SCHEMA) != services_mirror.SCHEMA:
        return ""
    return etag if _holds_rows(account) else ""


def _note_error(account, error_code: str) -> None:
    """Remember, once, that the relay sells no services right now (the menu says so)."""
    if error_code == ERROR_UNAVAILABLE and not (account.config or {}).get(
        services_mirror.CONFIG_ERROR
    ):
        _update_config(account, {services_mirror.CONFIG_ERROR: ERROR_UNAVAILABLE})


def _note_unchanged(account) -> None:
    """An unchanged directory writes nothing — except forgetting an error the
    relay has stopped giving."""
    if services_mirror.CONFIG_ERROR in (account.config or {}):
        _update_config(account, {}, drop=(services_mirror.CONFIG_ERROR,))


def _sync_flags(account, limit: int) -> int:
    """The countries' flags: after the rows, and never an error."""
    if limit <= 0:
        return 0
    try:
        return voucher_flags.sync_flags(account, limit=limit, model=IntegrationServiceCountry)
    except Exception:  # pragma: no cover - a nicety must not fail a sync
        logger.warning("could not fetch %s flags", account.provider, exc_info=True)
        return 0


def _sync_logos(account) -> None:
    """The operators' logos: after the rows, and never an error."""
    try:
        services_logos.sync_logos(account)
    except Exception:  # pragma: no cover - a nicety must not fail a sync
        logger.warning("could not fetch %s logos", account.provider, exc_info=True)


# --- writing it down ---------------------------------------------------------------------
@transaction.atomic
def apply_directory(account, result) -> int:
    """Write a directory into the mirror. Returns how many countries changed.

    The edition the mirror then holds is written in this same transaction, so it
    can never be remembered for a mirror that was not.
    """
    now = timezone.now()
    rows = {
        row.code: row
        for row in IntegrationServiceCountry.objects.filter(account=account).defer(
            "flag", "payload"
        )
    }
    named = set()
    changed = 0
    for index, country in enumerate(result.countries):
        named.add(country.code)
        wanted = _country_fields(country, index)
        digest = _digest(wanted)
        row = rows.get(country.code)
        if row is None:
            IntegrationServiceCountry.objects.create(
                account=account, code=country.code, version=digest, synced_at=now, **wanted
            )
            changed += 1
            continue
        if row.version == digest:
            continue
        if row.flag_path != wanted["flag_path"]:
            # Another picture: fetched on this sweep (see ``voucher_flags``).
            wanted["flag_checked_at"] = None
        for name, value in wanted.items():
            setattr(row, name, value)
        row.version = digest
        row.synced_at = now
        row.save(update_fields=[*wanted, "version", "synced_at", "updated_at"])
        changed += 1

    # A country the relay no longer lists goes; one it lists but the driver
    # could not read stays as it was.
    gone = [code for code in rows if code not in named and code not in result.skipped]
    if gone:
        IntegrationServiceCountry.objects.filter(account=account, code__in=gone).delete()
        changed += len(gone)

    _write_config(account, result, now=now, changed=changed)
    return changed


def _country_fields(country, index: int) -> dict:
    """What a country row says, from what the driver read."""
    operators = list(country.operators)
    billers = list(country.billers)
    offered = [biller for biller in billers if biller.get("type") in services_options.BILL_TYPES]
    payload = {}
    if operators:
        payload["airtime"] = {"operators": operators}
    if billers:
        payload["bills"] = {"billers": billers}
    return {
        "name": country.name,
        "name_en": country.name_en,
        "dial": list(country.dial),
        "currency": country.currency,
        "currency_name": country.currency_name,
        "popular": country.popular,
        "rank": country.popular if country.popular > 0 else _UNRANKED_FROM + index,
        "flag_path": country.flag_path,
        "airtime_count": len(operators),
        "bills_count": len(offered),
        "bill_types": {
            bill_type: count
            for bill_type in services_options.BILL_TYPES
            if (count := sum(1 for biller in offered if biller.get("type") == bill_type))
        },
        "payload": payload,
    }


def _digest(fields: dict) -> str:
    """A short digest of everything the relay said about a country."""
    text = json.dumps(fields, sort_keys=True, ensure_ascii=False, separators=(",", ":"))
    return hashlib.sha256(text.encode("utf-8")).hexdigest()[:32]


def _write_config(account, result, *, now, changed: int) -> None:
    """The directory-wide facts, on the account's config — only if they moved."""
    values = {
        services_mirror.CONFIG_SCHEMA: services_mirror.SCHEMA,
        services_mirror.CONFIG_EDITION: result.edition,
        services_mirror.CONFIG_STATE: {
            "configured": result.configured,
            "priced": result.priced,
            "test_mode": result.test_mode,
            "generated_at": result.generated_at,
        },
        services_mirror.CONFIG_UNSUPPORTED: [dict(country) for country in result.unsupported],
        services_mirror.CONFIG_PRICING: result.pricing or {},
    }
    drop = []
    if result.version:
        values[services_mirror.CONFIG_ETAG] = result.version
    else:
        # A relay that names editions answered without one: forget the last, or
        # a later "unchanged" would vouch for this one.
        drop.append(services_mirror.CONFIG_ETAG)
    config = account.config or {}
    moved = (
        changed
        or services_mirror.CONFIG_ERROR in config
        or any(config.get(key) != value for key, value in values.items())
        or any(key in config for key in drop)
    )
    if not moved:
        return
    values[services_mirror.CONFIG_SYNCED_AT] = now.isoformat()
    _update_config(account, values, drop=(services_mirror.CONFIG_ERROR, *drop))
