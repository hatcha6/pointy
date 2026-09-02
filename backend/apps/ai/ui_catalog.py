"""The vocabulary the assistant may compose UI from, and its validator.

The catalog itself is owned by the Flutter app — those are the widgets that
actually render — and exported to ``shared/ai_ui_catalog/pointy_catalog.json``
by a frontend test. This module reads that contract to do two things:

* describe the components in the system prompt, so the model knows what exists;
* refuse any payload that steps outside it, so a generated screen cannot drift
  away from the product's design.

The refusal is the important half. Nothing here trusts the model: an unknown
component, an unknown property, a dangling child reference or a missing root is
an error handed back to the model to correct, never something a client renders.
"""

from __future__ import annotations

import json
import re
from functools import lru_cache
from pathlib import Path

from django.conf import settings

# Matches the catalog id the Flutter client checks before rendering a surface.
CATALOG_ID = "https://pointy.app/ai-ui/v1"

# A surface is one answer's worth of UI. These bounds keep a generated payload
# from becoming a denial-of-service on the client's layout pass or on the SSE.
MAX_COMPONENTS = 120
MAX_SURFACE_BYTES = 96_000
MAX_SURFACES_PER_TURN = 4

_ID_RE = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
_SURFACE_ID_RE = re.compile(r"^[A-Za-z0-9_-]{1,64}$")

# Properties every component may carry regardless of its own schema: the id and
# type discriminators, plus the layout weight A2UI defines for flex children.
_UNIVERSAL_PROPERTIES = frozenset({"id", "component", "weight"})


def _catalog_path() -> Path:
    override = getattr(settings, "AI_UI_CATALOG_PATH", None)
    if override:
        return Path(override)
    return Path(settings.BASE_DIR).parent / "shared" / "ai_ui_catalog" / "pointy_catalog.json"


@lru_cache(maxsize=1)
def load_catalog() -> dict:
    """The exported catalog, or an empty one when the file is missing.

    A missing file disables generated UI rather than breaking chat: the tool is
    simply not advertised, so the assistant answers in prose as it always has.
    """
    path = _catalog_path()
    try:
        with path.open(encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError):
        return {"catalogId": CATALOG_ID, "components": {}}
    if not isinstance(data, dict) or not isinstance(data.get("components"), dict):
        return {"catalogId": CATALOG_ID, "components": {}}
    return data


def catalog_available() -> bool:
    return bool(load_catalog().get("components"))


def component_names() -> list[str]:
    return sorted(load_catalog().get("components", {}).keys())


# --------------------------------------------------------------------------
# Prompt rendering
# --------------------------------------------------------------------------


def _render_property(name: str, spec: dict, indent: str) -> list[str]:
    bits: list[str] = []
    description = spec.get("description") or ""
    kind = spec.get("type") or ("value" if spec.get("bindable") else "")
    enum = spec.get("enum")
    head = f"{indent}- {name}"
    if kind:
        head += f" ({kind})"
    if description:
        head += f": {description}"
    bits.append(head)
    if enum:
        bits.append(f"{indent}  one of: {', '.join(str(v) for v in enum)}")
    items = spec.get("items")
    if isinstance(items, dict) and isinstance(items.get("properties"), dict):
        required = set(items.get("required") or [])
        fields = []
        for field, field_spec in items["properties"].items():
            marker = "*" if field in required else ""
            enum_values = field_spec.get("enum") if isinstance(field_spec, dict) else None
            if enum_values:
                fields.append(f"{field}{marker}({'|'.join(str(v) for v in enum_values)})")
            else:
                fields.append(f"{field}{marker}")
        bits.append(f"{indent}  each item: {{{', '.join(fields)}}}")
    return bits


def catalog_prompt() -> str:
    """A compact, readable listing of every component for the system prompt."""
    catalog = load_catalog()
    components = catalog.get("components", {})
    if not components:
        return ""
    lines: list[str] = []
    for name, spec in components.items():
        description = spec.get("description") or ""
        lines.append(f"### {name}")
        if description:
            lines.append(description)
        required = set(spec.get("required") or [])
        properties = spec.get("properties") or {}
        for prop_name, prop_spec in properties.items():
            if not isinstance(prop_spec, dict):
                continue
            marker = " (required)" if prop_name in required else ""
            rendered = _render_property(f"{prop_name}{marker}", prop_spec, "")
            lines.extend(rendered)
        lines.append("")
    return "\n".join(lines).strip()


# --------------------------------------------------------------------------
# Validation
# --------------------------------------------------------------------------


class UiValidationError(Exception):
    """Raised with a list of human-readable problems for the model to fix."""

    def __init__(self, problems: list[str]):
        self.problems = problems
        super().__init__("; ".join(problems))


def _child_ids(value) -> list[str]:
    """Every component id referenced by a property value.

    Covers both A2UI child shapes: an explicit list of ids, and a template
    ``{"template": id, "path": "/..."}`` that repeats one component over a list.
    """
    if isinstance(value, str):
        return [value]
    if isinstance(value, list):
        return [entry for entry in value if isinstance(entry, str)]
    if isinstance(value, dict):
        found = []
        for key in ("template", "componentId"):
            candidate = value.get(key)
            if isinstance(candidate, str):
                found.append(candidate)
        return found
    return []


# Properties whose values are component references, by component name.
_CHILD_PROPERTIES = {"child", "children"}


def validate_surface(payload: dict) -> dict:
    """Check one ``render_ui`` payload and return the normalised surface.

    Returns ``{"surface_id", "title", "components", "data"}``. Raises
    :class:`UiValidationError` listing every problem found, so the model can fix
    them all in one retry rather than discovering them one round at a time.
    """
    problems: list[str] = []
    catalog = load_catalog().get("components", {})
    if not catalog:
        raise UiValidationError(["generated UI is not available on this server"])

    surface_id = payload.get("surface_id") or payload.get("surfaceId") or ""
    if not isinstance(surface_id, str) or not _SURFACE_ID_RE.match(surface_id):
        problems.append(
            "surface_id must be 1-64 characters of letters, digits, underscore or hyphen"
        )

    raw_components = payload.get("components")
    if not isinstance(raw_components, list) or not raw_components:
        raise UiValidationError(problems + ["components must be a non-empty array"])
    if len(raw_components) > MAX_COMPONENTS:
        problems.append(
            f"too many components ({len(raw_components)}); the limit is {MAX_COMPONENTS}"
        )
        raw_components = raw_components[:MAX_COMPONENTS]

    seen: set[str] = set()
    components: list[dict] = []
    referenced: set[str] = set()

    for index, entry in enumerate(raw_components):
        if not isinstance(entry, dict):
            problems.append(f"component #{index} is not an object")
            continue
        component_id = entry.get("id")
        component_type = entry.get("component")
        if not isinstance(component_id, str) or not _ID_RE.match(component_id):
            problems.append(f"component #{index} has a missing or invalid id")
            continue
        if component_id in seen:
            problems.append(f"duplicate component id '{component_id}'")
            continue
        seen.add(component_id)
        if component_type not in catalog:
            problems.append(
                f"'{component_type}' is not a component in this app. "
                f"Available: {', '.join(sorted(catalog))}"
            )
            continue

        spec = catalog[component_type]
        allowed = set(spec.get("properties", {}).keys()) | _UNIVERSAL_PROPERTIES
        unknown = [key for key in entry if key not in allowed]
        if unknown:
            problems.append(
                f"{component_type} '{component_id}' has properties this app does not "
                f"support: {', '.join(sorted(unknown))}. "
                f"Allowed: {', '.join(sorted(allowed - {'id', 'component'}))}"
            )
        missing = [key for key in spec.get("required", []) if key not in entry]
        if missing:
            problems.append(
                f"{component_type} '{component_id}' is missing required "
                f"{', '.join(missing)}"
            )
        for prop in _CHILD_PROPERTIES & set(entry):
            referenced.update(_child_ids(entry[prop]))
        components.append(entry)

    if "root" not in seen:
        problems.append("exactly one component must have the id 'root'")

    dangling = sorted(referenced - seen)
    if dangling:
        problems.append(
            "these child ids are referenced but never defined: " + ", ".join(dangling)
        )

    data = payload.get("data")
    if data is not None and not isinstance(data, dict):
        problems.append("data must be an object keyed by binding path")

    title = payload.get("title") or ""
    if not isinstance(title, str):
        title = ""

    surface = {
        "surface_id": surface_id,
        "title": title[:120],
        "components": components,
        "data": data or {},
    }

    if not problems:
        try:
            size = len(json.dumps(surface, ensure_ascii=False).encode("utf-8"))
        except (TypeError, ValueError):
            problems.append("the surface contains values that cannot be serialised")
        else:
            if size > MAX_SURFACE_BYTES:
                problems.append(
                    f"the surface is too large ({size} bytes); "
                    f"the limit is {MAX_SURFACE_BYTES}. Summarise or show fewer rows."
                )

    if problems:
        raise UiValidationError(problems)
    return surface
