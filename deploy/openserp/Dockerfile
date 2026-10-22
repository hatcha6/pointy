# OpenSERP — the relay's product image search engine — repackaged on Debian 12
# for LibyanSpider JPaaS.
#
# The upstream image (karust/openserp) sits on Debian 13, which the Jelastic
# Docker engine refuses: "The image is based on non-supported OS template".
# This keeps upstream's own pieces (the pinned OpenSERP binary, its config, and
# chromedp's headless-shell browser) and only swaps the OS underneath.
#
# Keep headless-shell rather than the distro's Chromium: Ecosia answered every
# search from Alpine's Chromium with a captcha, and headless-shell with results.
#
#   docker build -t pointy-openserp deploy/openserp
#   docker run --rm --init -p 127.0.0.1:7000:7000 pointy-openserp
#
# It has no auth of its own: expose port 7000 only on the private network the
# relay reaches it through (POINTY_RELAY_OPENSERP_BASE_URL).

FROM karust/openserp:0.8.14 AS upstream

FROM debian:12-slim

# headless-shell's shared libraries, fonts for page layout, wget for the
# health check.
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    libnspr4 libnss3 libexpat1 libfontconfig1 libuuid1 libglib2.0-0 libdbus-1-3 \
    libx11-6 libxcomposite1 libxdamage1 libxext6 libxfixes3 libxrandr2 libxcb1 \
    libxkbcommon0 libgbm1 libasound2 libatk1.0-0 libatk-bridge2.0-0 libcups2 \
    libpango-1.0-0 libcairo2 libdrm2 fonts-liberation ca-certificates tzdata wget \
  && rm -rf /var/lib/apt/lists/* \
  && useradd --create-home --uid 1001 --shell /bin/bash chrome

COPY --from=upstream /headless-shell /headless-shell
COPY --from=upstream /usr/local/bin/openserp /usr/local/bin/openserp
WORKDIR /usr/src/app
COPY --from=upstream --chown=chrome:chrome /usr/src/app/config.yaml ./config.yaml
# OpenSERP writes logs.txt beside its config.
RUN chown chrome:chrome /usr/src/app

# Pin the browser so OpenSERP never tries to download its own Chromium.
ENV OPENSERP_APP_BROWSER_PATH=/headless-shell/headless-shell \
  OPENSERP_SERVER_HOST=0.0.0.0 \
  OPENSERP_SERVER_PORT=7000

USER chrome
EXPOSE 7000

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD wget --quiet --tries=1 --spider "http://127.0.0.1:${OPENSERP_SERVER_PORT}/health" || exit 1

ENTRYPOINT ["openserp"]
CMD ["serve", "-a", "0.0.0.0", "-p", "7000"]
