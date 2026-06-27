# syntax=docker/dockerfile:1

FROM python:3.12-slim AS build

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /app

COPY backend/pyproject.toml /app/backend/pyproject.toml
COPY backend /app/backend

RUN python -m venv /opt/pointy-venv \
    && /opt/pointy-venv/bin/python -m pip install --upgrade pip \
    && /opt/pointy-venv/bin/python -m pip install --editable /app/backend \
    && rm -rf \
        /opt/pointy-venv/bin/pip* \
        /opt/pointy-venv/lib/python3.12/site-packages/pip \
        /opt/pointy-venv/lib/python3.12/site-packages/pip-*.dist-info

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

COPY backend /app/backend

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
