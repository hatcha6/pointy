# One image for every service in the rig that needs Python or ffmpeg: the fake
# DVR, the fake ONVIF device and the publisher that feeds MediaMTX. Building it
# ourselves rather than pulling three unrelated ffmpeg images keeps the rig
# reproducible — the encoder that makes the trap frames is the same version
# every time, and the trap depends on what the encoder writes.
FROM python:3.12-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends ffmpeg curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /rig
COPY fake_dvr.py fake_onvif.py /rig/
