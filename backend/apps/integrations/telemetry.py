"""What we learn when a provider breaks, without waiting for a shop to tell us.

These integrations drive somebody else's website. Nobody versions it, nobody
announces a change, and the failure mode is silent: a column moves, a form is
renamed, a WAF rule tightens, and a till that worked on Friday says "not found"
on Monday for every customer. The question this module exists to answer is not
*that* it broke — a cashier reports that within the hour — but **where**, well
enough to fix a parser without asking anyone for a HAR.

So a row records the **step the conversation reached**. "Login succeeded, search
succeeded, the recharge form did not render" names a changed selector. "The
login page carried no CSRF token" names a changed login page. "A search returned
a page with no results table at all" names changed markup, which is a different
thing from a customer who genuinely has no line — and today both of those arrive
as ``not_found``, which is precisely the ambiguity that would waste a day.

Three rules, and the first two are inherited from the outage telemetry caused
once already (see apps.surveillance.telemetry):

**Never raises, never blocks.** A telemetry bug must not be why a shop cannot
sell. Every entry point swallows its own errors and rows go through the
analytics buffer, which batches and drops rather than retries.

**Reads are throttled; repeats inside a window are counted, not written.** A
portal that is down is one fact however many times a till rediscovers it.

**Writes are NEVER throttled.** This is the deliberate difference from cameras.
A recharge moves real money and is attempted at most once, ever; there is no
retry loop to storm with, and the one row describing an indeterminate charge is
the row somebody will need most. Folding two of those into a count would erase
the evidence for a second customer's money.

**No customer identifiers, ever.** Analytics rows are exported off the shop's
machine. A card number is a subscriber and an LNET username is a person, so
neither appears here; a row names the *account* and, for a write, the
fulfillment id, which is enough to join back to the truth on the shop's own
database and useless to anyone without it.
"""

from __future__ import annotations

import logging
import threading
import time
from dataclasses import dataclass, field

from django.conf import settings

logger = logging.getLogger(__name__)

EVENT_NAME = "integration.call"

# --- what was being attempted (closed vocabulary) ---------------------------
OP_PROBE = "probe"
OP_LOOKUP = "lookup"
OP_OFFERS = "offers"
OP_PROFILE = "profile"
OP_HISTORY = "history"
OP_RECHARGE = "recharge"

#: The methods worth a row. ``recharge`` is the money one and is treated apart.
OPERATIONS = {
    "probe": OP_PROBE,
    "lookup": OP_LOOKUP,
    "offers": OP_OFFERS,
    "subscriber_profile": OP_PROFILE,
    "purchase_history": OP_HISTORY,
    "recharge": OP_RECHARGE,
}

WRITE_OPERATIONS = frozenset({OP_RECHARGE})

# --- how far the conversation got (closed vocabulary) -----------------------
#: Nothing left the machine yet — configuration, or a refusal to even try.
STEP_START = "start"
#: Fetching the page that carries the login form and its token.
STEP_LOGIN_PAGE = "login_page"
#: Posting credentials.
STEP_LOGIN = "login"
#: Finding the subscriber.
STEP_SEARCH = "search"
#: Loading the page a quote or a write is composed from.
STEP_FORM = "form"
#: Reading a fetched document into our own shape.
STEP_PARSE = "parse"
#: The first write. For LNET this is the one that credits the customer.
STEP_SUBMIT = "submit"
#: The second write. LNET only: debits the agency float.
STEP_COMMIT = "commit"
#: Everything we meant to do, done.
STEP_DONE = "done"

#: Seconds a repeated read failure for one account is folded into a count.
DEFAULT_FAILURE_WINDOW_SECONDS = 300.0


def _setting(name, default):
    return getattr(settings, name, default)


def enabled() -> bool:
    return bool(_setting("POINTY_INTEGRATION_TELEMETRY", True))


@dataclass
class CallReport:
    """One logical provider call, however many HTTP requests it took."""

    provider: str = ""
    operation: str = ""
    account_id: int | None = None
    #: The last step reached. On a failure this is the diagnosis.
    step: str = STEP_START
    #: ``""`` while it is going well, then the driver's own error code.
    error_code: str = ""
    #: Short, already free of credentials. Never a customer identifier.
    detail: str = ""
    duration_ms: int = 0
    #: HTTP status of the last response, when one was seen. A portal that
    #: starts answering 403 to a whole network looks like bad credentials
    #: until you can see this.
    http_status: int | None = None
    #: ``False`` when a document parsed but did not look like what we expect —
    #: the signature of their markup changing, and the one signal that
    #: separates "no such customer" from "our parser has gone blind".
    shape_ok: bool | None = None
    #: How many candidates a lookup matched. One phone holding several lines is
    #: ordinary for LNET; zero where the page rendered is the interesting case.
    matches: int | None = None
    #: Set for a write, so an indeterminate charge can be joined to its row.
    fulfillment_id: int | None = None
    #: Set for a write that got far enough to be told one.
    provider_reference: str = ""
    extra: dict = field(default_factory=dict)

    @property
    def ok(self) -> bool:
        return not self.error_code

    @property
    def is_write(self) -> bool:
        return self.operation in WRITE_OPERATIONS

    def note(self, step: str) -> None:
        self.step = step

    def as_attributes(self) -> dict:
        attributes = {
            "provider": self.provider,
            "operation": self.operation,
            "step": self.step,
            "outcome": "ok" if self.ok else self.error_code,
        }
        if self.account_id:
            attributes["account_id"] = self.account_id
        if self.http_status is not None:
            attributes["http_status"] = self.http_status
        if self.shape_ok is not None:
            attributes["shape_ok"] = self.shape_ok
        if self.fulfillment_id:
            attributes["fulfillment_id"] = self.fulfillment_id
        if self.provider_reference:
            attributes["provider_reference"] = self.provider_reference[:64]
        if self.detail:
            attributes["detail"] = self.detail[:200]
        attributes.update(self.extra)
        return attributes

    def as_metrics(self) -> dict:
        metrics = {"duration_ms": self.duration_ms}
        if self.matches is not None:
            metrics["matches"] = self.matches
        return metrics


class _FailureThrottle:
    """Fold repeated read failures for one account into a count.

    Keyed on the account, operation, error code **and step** — two different
    diagnoses inside one window are two facts, and folding the second into the
    first is how a portal that changed failure mode looks like one that did
    not. All four are closed vocabularies or small integers, so this cannot
    multiply rows the way keying on a message would.
    """

    def __init__(self):
        self._lock = threading.Lock()
        self._seen: dict[tuple, tuple[float, int]] = {}

    @property
    def window(self) -> float:
        return float(
            _setting(
                "POINTY_INTEGRATION_TELEMETRY_FAILURE_WINDOW",
                DEFAULT_FAILURE_WINDOW_SECONDS,
            )
        )

    def take(self, key) -> int | None:
        """``None`` to suppress, otherwise how many were folded into this one."""
        now = time.monotonic()
        window = self.window
        with self._lock:
            # Opportunistic sweep, bounded by providers × operations × codes.
            if len(self._seen) > 256:
                self._seen = {
                    k: v for k, v in self._seen.items() if now - v[0] < window
                }
            seen_at, count = self._seen.get(key, (0.0, 0))
            if seen_at and now - seen_at < window:
                self._seen[key] = (seen_at, count + 1)
                return None
            self._seen[key] = (now, 0)
            return count


_failures = _FailureThrottle()


def reset():
    """Test seam: forget what has been throttled."""
    global _failures
    _failures = _FailureThrottle()


def record(report: CallReport, *, user=None) -> None:
    """Write one call. Never raises."""
    if not enabled():
        return
    try:
        _record(report, user)
    except Exception:  # noqa: BLE001 - telemetry must never break a sale
        logger.debug("integration telemetry failed", exc_info=True)


def _record(report: CallReport, user) -> None:
    from apps.analytics.models import AnalyticsEvent

    from apps.analytics.services import record_event_buffered

    attributes = report.as_attributes()
    metrics = report.as_metrics()

    if report.ok:
        severity = AnalyticsEvent.Severity.INFO
        event_type = AnalyticsEvent.EventType.USAGE
    else:
        severity = AnalyticsEvent.Severity.WARNING
        event_type = AnalyticsEvent.EventType.ERROR

    if report.is_write:
        # Money. Every attempt gets a row, and a charge whose outcome nobody
        # knows is the loudest thing this module can say — it is the one a
        # person has to act on, and there may be a customer's money inside it.
        if not report.ok:
            severity = (
                AnalyticsEvent.Severity.CRITICAL
                if report.error_code == "indeterminate"
                else AnalyticsEvent.Severity.ERROR
            )
    elif not report.ok:
        folded = _failures.take(
            (report.account_id, report.operation, report.error_code, report.step)
        )
        if folded is None:
            return
        if folded:
            metrics["suppressed_repeats"] = folded

    record_event_buffered(
        name=EVENT_NAME,
        event_type=event_type,
        severity=severity,
        source=AnalyticsEvent.Source.INTEGRATION,
        user=user,
        entity_type="integration_account",
        entity_id=str(report.account_id or ""),
        attributes=attributes,
        metrics=metrics,
    )


# --- automatic instrumentation ---------------------------------------------
#: Result fields a driver's return value may carry, in the order we trust them.
_ERROR_FIELD = "error_code"


def observe(cls):
    """Wrap a driver's public methods so every call produces a row.

    Applied by ``providers.base.register``, so a driver written next year is
    observable without its author remembering to be — the same totality
    argument as :class:`~apps.integrations.providers.base.PlannedProvider`.
    Drivers refine the row by calling ``self._note(step)``; everything else —
    duration, outcome, and the fact that a row happens at all — is free.
    """
    for method_name, operation in OPERATIONS.items():
        original = getattr(cls, method_name, None)
        if original is None or getattr(original, "_observed", False):
            continue
        setattr(cls, method_name, _wrap(original, operation))
    return cls


def _wrap(method, operation):
    def wrapper(self, *args, **kwargs):
        report = CallReport(
            provider=getattr(self, "key", "") or "",
            operation=operation,
            account_id=getattr(getattr(self, "account", None), "pk", None),
        )
        # Drivers reach this through ``self._note``; it is deliberately a plain
        # attribute on a per-call driver instance rather than thread state,
        # because ``provider_for()`` builds a fresh driver for every call.
        self._call = report
        started = time.monotonic()
        try:
            result = method(self, *args, **kwargs)
        except Exception as exc:  # noqa: BLE001 - drivers are contracted not to
            report.duration_ms = int((time.monotonic() - started) * 1000)
            report.error_code = "driver_exception"
            report.detail = f"{type(exc).__name__}: {exc}"
            record(report)
            raise
        report.duration_ms = int((time.monotonic() - started) * 1000)
        _read_outcome(report, result)
        record(report)
        return result

    wrapper._observed = True
    wrapper.__name__ = getattr(method, "__name__", operation)
    wrapper.__doc__ = getattr(method, "__doc__", None)
    return wrapper


def _read_outcome(report: CallReport, result) -> None:
    """Take what the returned dataclass already says, without asking drivers."""
    code = getattr(result, _ERROR_FIELD, "") or ""
    if code:
        report.error_code = code
        detail = getattr(result, "error_detail", "") or ""
        if detail and not report.detail:
            report.detail = detail
    elif report.step == STEP_START:
        report.step = STEP_DONE
    # A write that came back indeterminate carries its reference when it got
    # one; that is the handle reconciliation will need.
    reference = getattr(result, "reference", "") or ""
    if reference and not report.provider_reference:
        report.provider_reference = reference
    candidates = getattr(result, "candidates", None)
    if candidates is not None:
        report.matches = len(candidates)
