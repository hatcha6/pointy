# The shop app's web build (app.dftr.ly), as an image of plain files the
# relay image copies in (relay/Dockerfile). Built by .github/workflows/
# app-web.yml only when frontend/ changes, so a relay release never compiles
# Flutter. Context: frontend/, after `make frontend-web-build` (the build and
# its post-build step, which adds the compressed copies the relay sends).
FROM scratch
COPY build/web /app-web
