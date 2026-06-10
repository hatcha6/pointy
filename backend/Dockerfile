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

ENV PATH="/opt/pointy-venv/bin:${PATH}" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PYTHONSAFEPATH=1

WORKDIR /app

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
