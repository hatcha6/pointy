# syntax=docker/dockerfile:1

FROM python:3.12-slim AS build

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /app

COPY backend/pyproject.toml /app/backend/pyproject.toml
COPY backend /app/backend

# The AI UI catalog is a data contract the backend reads at
# /app/shared/ai_ui_catalog/pointy_catalog.json (settings.BASE_DIR.parent). It has
# never been copied into the image, so generated UI has been silently disabled on
# every deployment — load_catalog() degrades to an empty catalog by design, so it
# failed quietly. 23 tests assert it is present.
COPY shared /app/shared

RUN python -m venv /opt/pointy-venv \
    && /opt/pointy-venv/bin/python -m pip install --upgrade pip \
    && /opt/pointy-venv/bin/python -m pip install --editable /app/backend \
    && rm -rf \
        /opt/pointy-venv/bin/pip* \
        /opt/pointy-venv/lib/python3.12/site-packages/pip \
        /opt/pointy-venv/lib/python3.12/site-packages/pip-*.dist-info

# ---------------------------------------------------------------------------
# Compile stage: turn the backend into stripped native extensions.
#
# Deliberately independent of the venv: Cython translates source statically, so
# this stage needs a compiler and Cython but none of the app's dependencies.
# Set POINTY_COMPILE=0 to ship plain Python — the escape hatch for the week a
# Cython regression lands next to a release. See backend/docker/compile_backend.py
# and CYTHON_FEASIBILITY.md.
# ---------------------------------------------------------------------------
FROM python:3.12-slim AS compile

ARG POINTY_COMPILE=1
ENV POINTY_COMPILE=${POINTY_COMPILE} \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

# Pinned: Cython 3.3.0 crashes its own code generator on the Django
# dynamic-filter idiom, filter(**{f"{field}__gte": x}). compile_backend.py
# refuses to build on any other version rather than trusting this line alone.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends build-essential; \
    rm -rf /var/lib/apt/lists/*; \
    pip install --no-cache-dir "cython==3.2.4" "setuptools>=69"

WORKDIR /app
COPY backend /app/backend
RUN python /app/backend/docker/compile_backend.py

# ---------------------------------------------------------------------------
# Test stage (CI only, never shipped): the compiled tree against the real venv,
# with the test files still present. Compilation breaks things that are
# invisible in a source run, so the suite has to meet the artifact we ship.
#   docker build --target test -t pointy-backend-test -f backend/Dockerfile .
# ---------------------------------------------------------------------------
FROM build AS test

ENV PATH="/opt/pointy-venv/bin:${PATH}" \
    PYTHONUNBUFFERED=1
# COPY overlays, it does not replace: without this the build stage's .py files
# survive alongside the .so and the suite silently tests a hybrid tree — every
# source-reading guard (apps/core/test_money_definitions.py) would pass in CI and
# fail in the shipped image, which is the exact failure this stage exists to catch.
RUN rm -rf /app/backend
COPY --from=compile /app/backend /app/backend
WORKDIR /app/backend
CMD ["python", "manage.py", "test", "apps"]

FROM python:3.12-slim AS runtime

# Build version, surfaced as POINTY_VERSION so the app reports the real release
# (diagnostics header, fleet status). Defaults to a dev marker for local builds.
ARG POINTY_VERSION=0.0.0-dev

ENV PATH="/opt/pointy-venv/bin:${PATH}" \
    POINTY_VERSION=${POINTY_VERSION} \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PYTHONSAFEPATH=1

WORKDIR /app

# SQL Server source migrations go through pyodbc, which needs the unixODBC
# runtime (libodbc.so.2) — absent from the slim base. Install two ODBC drivers:
# Microsoft's "ODBC Driver 18 for SQL Server" (the transport default, SQL Server
# 2012+) from Microsoft's apt repo, and FreeTDS for very old servers (SQL Server
# 2000, used by the Fahd connector) that Driver 18 no longer talks to. Both are
# registered under the exact names the transport asks for. The Microsoft repo
# config .deb carries the right signing key for the base Debian release (trixie's
# key isn't in the legacy microsoft.asc). Must run before the hardening step
# below removes apt/dpkg.
RUN set -eux; \
    export DEBIAN_FRONTEND=noninteractive; \
    apt-get update; \
    apt-get install -y --no-install-recommends curl ca-certificates; \
    . /etc/os-release; \
    curl -fsSL -o /tmp/ms-prod.deb \
        "https://packages.microsoft.com/config/debian/${VERSION_ID}/packages-microsoft-prod.deb"; \
    apt-get install -y --no-install-recommends /tmp/ms-prod.deb; \
    apt-get update; \
    ACCEPT_EULA=Y apt-get install -y --no-install-recommends unixodbc tdsodbc msodbcsql18; \
    printf '[ODBC Driver 18 for SQL Server]\nDescription = Microsoft ODBC Driver 18 for SQL Server\nDriver = %s\n\n[FreeTDS]\nDescription = FreeTDS (SQL Server 6.5 - 2019)\nDriver = %s\n' \
        "$(dpkg -L msodbcsql18 | grep -m1 'libmsodbcsql-18.*\.so')" \
        "$(dpkg -L tdsodbc | grep -m1 'libtdsodbc\.so')" \
        > /etc/odbcinst.ini; \
    apt-get purge -y curl; \
    apt-get autoremove -y; \
    rm -rf /tmp/ms-prod.deb /etc/apt/sources.list.d/*microsoft* /var/lib/apt/lists/*

RUN groupadd --system pointy \
    && useradd --system --gid pointy --home-dir /var/lib/pointy pointy \
    && mkdir -p \
        /var/lib/pointy/backups \
        /var/lib/pointy/celerybeat \
        /var/lib/pointy/media \
        /var/lib/pointy/staticfiles \
        /tmp/pointy-backup-staging \
    && chown -R pointy:pointy /var/lib/pointy /tmp/pointy-backup-staging

COPY --from=build /opt/pointy-venv /opt/pointy-venv

# The AI UI catalog is a data contract the backend reads at
# /app/shared/ai_ui_catalog/pointy_catalog.json (settings.BASE_DIR.parent). It has
# never been copied into the image, so generated UI has been silently disabled on
# every deployment — load_catalog() degrades to an empty catalog by design, so it
# failed quietly. 23 tests assert it is present.
COPY shared /app/shared

# The compiled tree (or plain source when POINTY_COMPILE=0), never the raw
# working directory — this is what keeps readable Python out of the image.
COPY --from=compile /app/backend /app/backend

RUN chown -R pointy:pointy /app/backend \
    && find /app/backend -type d -name __pycache__ -prune -exec rm -rf {} + \
    && find /app/backend -type f \( -name "tests.py" -o -name "test_*.py" \) -delete \
    && rm -rf \
        /usr/local/bin/pip* \
        /usr/local/lib/python3.12/ensurepip \
        /usr/local/lib/python3.12/site-packages/pip \
        /usr/local/lib/python3.12/site-packages/pip-*.dist-info \
        /usr/local/lib/python3.12/site-packages/setuptools \
        /usr/local/lib/python3.12/site-packages/setuptools-*.dist-info \
        /var/lib/apt/lists/* \
        /usr/share/doc/* \
        /usr/share/man/* \
        /usr/share/info/* \
    && rm -f \
        /bin/bash \
        /bin/dash \
        /bin/sh \
        /usr/bin/apt \
        /usr/bin/apt-cache \
        /usr/bin/apt-get \
        /usr/bin/dpkg \
        /usr/bin/dpkg-deb \
        /usr/bin/dpkg-query \
        /usr/sbin/groupadd \
        /usr/sbin/useradd

USER pointy
WORKDIR /app/backend

EXPOSE 8000
EXPOSE 47777/udp

ENTRYPOINT ["python", "/app/backend/docker/entrypoint.py"]
CMD ["web"]
