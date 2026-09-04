"""Work out which POS wrote this file.

The old flow opened with a dropdown: "which system are you migrating from?" —
asked of someone who knows their POS as the program with the blue icon, not as
``fahd_sqlite``. And the answer was only ever a hint, because the connector then
introspected the schema anyway to find out whether it could actually read it.

So the introspection *is* the answer. Every connector already declares the tables
and columns each version it supports must have, and already reports exactly what
is missing. Running all of them and taking the best fit removes the question.

When nothing matches, the runner-up is still worth reporting: "this looks like
Fahd, but the CAR_PART table is missing" tells an operator something. "Unknown
file" does not.
"""

from __future__ import annotations

from dataclasses import dataclass, field

from ..connectors import list_connectors

#: A missing table costs more than a missing column: a connector missing one
#: whole table is further from reading this file than one missing three columns
#: off tables that are all present.
_TABLE_PENALTY = 10
_COLUMN_PENALTY = 1


@dataclass
class Candidate:
    system_key: str
    display_name: str
    compatible: bool
    detected_version: str | None
    score: int
    missing_tables: list[str] = field(default_factory=list)
    missing_columns: dict[str, list[str]] = field(default_factory=dict)
    report: dict = field(default_factory=dict)
    error: str = ""

    def as_dict(self) -> dict:
        return {
            "system_key": self.system_key,
            "display_name": self.display_name,
            "compatible": self.compatible,
            "detected_version": self.detected_version,
            "score": self.score,
            "missing_tables": self.missing_tables[:20],
            "missing_columns": {k: v[:20] for k, v in list(self.missing_columns.items())[:20]},
            "error": self.error,
        }


@dataclass
class Detection:
    """The outcome: a winner (or not) plus why the others lost."""

    match: Candidate | None
    candidates: list[Candidate]

    @property
    def matched(self) -> bool:
        return self.match is not None

    def as_dict(self) -> dict:
        return {
            "matched": self.matched,
            "system_key": self.match.system_key if self.match else "",
            "display_name": self.match.display_name if self.match else "",
            "detected_version": self.match.detected_version if self.match else "",
            "candidates": [candidate.as_dict() for candidate in self.candidates[:6]],
        }

    def failure_message(self) -> str:
        """Arabic explanation for a file no connector recognised."""
        closest = next((c for c in self.candidates if not c.error), None)
        if closest is None:
            return "لم نتعرف على النظام الذي أنشأ هذا الملف."
        if closest.missing_tables:
            missing = "، ".join(closest.missing_tables[:4])
            return (
                f"هذا الملف يشبه «{closest.display_name}» لكن تنقصه جداول "
                f"أساسية: {missing}. تأكد من أنه ملف قاعدة البيانات الرئيسي."
            )
        if closest.missing_columns:
            table, columns = next(iter(closest.missing_columns.items()))
            return (
                f"هذا الملف يشبه «{closest.display_name}» لكن الجدول {table} "
                f"تنقصه أعمدة ({'، '.join(columns[:4])}) — قد يكون إصدارًا غير "
                "مدعوم بعد."
            )
        return "لم نتعرف على النظام الذي أنشأ هذا الملف."


def detect(transport, *, only=None, raw=False) -> Detection:
    """Score every connector against an open transport and rank them.

    ``only`` restricts the search to one connector key — used when re-preparing a
    file whose system is already known, so a schema that two connectors both
    accept cannot silently change identity between runs.

    ``raw=True`` scores against ``raw_versions`` instead: the shape a vendor's
    file has *before* its preparation step runs. Detection happens twice for that
    reason — once to decide whether a file needs vendor-specific preparation, and
    again afterwards to confirm the prepared file is what the connector reads.
    """
    candidates: list[Candidate] = []
    for connector in list_connectors():
        if only and connector.system_key != only:
            continue
        if connector.required_transport != transport.kind:
            continue
        if raw and not connector.raw_versions:
            continue
        candidates.append(_score(connector, transport, raw=raw))

    candidates.sort(key=lambda candidate: (not candidate.compatible, candidate.score))
    match = next(
        (candidate for candidate in candidates if candidate.compatible and not candidate.error),
        None,
    )
    return Detection(match=match, candidates=candidates)


def _score(connector, transport, *, raw=False) -> Candidate:
    try:
        report = connector.check_raw(transport) if raw else connector.check_compatibility(transport)
    except Exception as exc:  # noqa: BLE001 - one broken connector must not stop detection
        return Candidate(
            system_key=connector.system_key,
            display_name=connector.display_name,
            compatible=False,
            detected_version=None,
            score=10**6,
            error=str(exc)[:240],
        )
    penalty = _TABLE_PENALTY * len(report.missing_tables) + _COLUMN_PENALTY * sum(
        len(columns) for columns in report.missing_columns.values()
    )
    # Tie-break in favour of the connector that had to prove more: a version spec
    # requiring twelve tables is a far stronger claim than one requiring two, so
    # a perfect match on the bigger spec wins.
    versions = connector.raw_versions if raw else connector.versions
    specificity = max((len(version.required_tables) for version in versions), default=0)
    return Candidate(
        system_key=connector.system_key,
        display_name=connector.display_name,
        compatible=report.compatible,
        detected_version=report.detected_version,
        score=penalty * 1000 - specificity,
        missing_tables=list(report.missing_tables),
        missing_columns=dict(report.missing_columns),
        report=report.as_dict(),
    )
