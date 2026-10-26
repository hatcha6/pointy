# The card app's web build (cards.dftr.ly), as an image of plain files the
# relay image copies in (relay/Dockerfile). Built by .github/workflows/
# cards-web.yml only when cards/ changes, so a relay release never compiles
# Flutter. Context: cards/, after `make cards-web-build`.
FROM scratch
COPY build/web /cards-web
