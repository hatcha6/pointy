#!/usr/bin/env bash
# One-time setup: the key every Android release is signed with, forever.
#
# Android installs an update over an installed app ONLY when both are signed
# with the same key. Until this exists, CI signs each APK with a debug key the
# runner invents on the spot — a different one every release — so every update
# failed with "App not installed as package conflicts with an existing package".
#
# This script:
#   1. generates the release keystore (RSA 4096, valid ~27 years) with a random
#      password, in KEY_DIR (default ~/.pointy/android-release), never the repo;
#   2. writes KEY_DIR/key.properties beside it (the passwords — keep both files);
#   3. stores the four signing secrets in the GitHub repository (gh secret set);
#   4. writes the certificate's SHA-256 to frontend/android/release-signing-cert.sha256,
#      which you COMMIT: release CI refuses any APK whose signer does not match it.
#
# BACK UP KEY_DIR (password manager / offline copy). Losing the keystore means
# every till must uninstall and reinstall the app again — the very problem this
# fixes. It refuses to replace a key that already exists unless --force is given,
# and you should almost never give it.
#
# Usage: make android-release-key            (or: scripts/android-release-key.sh [--force])
set -euo pipefail

FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KEY_DIR="${KEY_DIR:-$HOME/.pointy/android-release}"
KEYSTORE="$KEY_DIR/pointy-android-release.jks"
PROPERTIES="$KEY_DIR/key.properties"
ALIAS="pointy"
PIN_FILE="$REPO_ROOT/frontend/android/release-signing-cert.sha256"

die() { echo "ERROR: $*" >&2; exit 1; }

for tool in keytool gh openssl base64; do
  command -v "$tool" >/dev/null 2>&1 || die "'$tool' is not installed."
done
gh auth status >/dev/null 2>&1 || die "gh is not signed in (run: gh auth login)."

if [ "$FORCE" -ne 1 ]; then
  if [ -e "$KEYSTORE" ]; then
    die "$KEYSTORE already exists. Replacing the release key breaks updates on every till; re-run with --force only if you mean it."
  fi
  if gh secret list 2>/dev/null | awk '{print $1}' | grep -qx ANDROID_KEYSTORE_BASE64; then
    die "the repository already has ANDROID_KEYSTORE_BASE64. Replacing the release key breaks updates on every till; re-run with --force only if you mean it."
  fi
fi

mkdir -p "$KEY_DIR"
chmod 700 "$KEY_DIR"
rm -f "$KEYSTORE"

# PKCS12 keeps one password for the store and the key. Letters and digits only,
# so it survives every properties/YAML/shell layer it passes through.
RANDOM_CHARS="$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9')"
PASSWORD="${RANDOM_CHARS:0:32}"
unset RANDOM_CHARS
[ "${#PASSWORD}" -eq 32 ] || die "could not generate a password."
export POINTY_ANDROID_KEY_PASSWORD="$PASSWORD"

echo "==> Generating the release keystore in $KEY_DIR"
keytool -genkeypair -noprompt \
  -keystore "$KEYSTORE" -storetype PKCS12 \
  -storepass:env POINTY_ANDROID_KEY_PASSWORD \
  -keypass:env POINTY_ANDROID_KEY_PASSWORD \
  -alias "$ALIAS" -keyalg RSA -keysize 4096 -validity 10000 \
  -dname "CN=Daftar, O=Daftar, C=LY" >/dev/null
chmod 600 "$KEYSTORE"

umask 077
cat > "$PROPERTIES" <<EOF
storeFile=$KEYSTORE
storePassword=$PASSWORD
keyAlias=$ALIAS
keyPassword=$PASSWORD
EOF

FINGERPRINT="$(
  keytool -list -v -keystore "$KEYSTORE" -alias "$ALIAS" \
    -storepass:env POINTY_ANDROID_KEY_PASSWORD \
  | awk -F': ' '/SHA256:/ && !seen {print $2; seen = 1}' | tr -d ':' | tr 'A-F' 'a-f'
)"
[ "${#FINGERPRINT}" -eq 64 ] || die "could not read the certificate fingerprint."

echo "==> Storing the signing secrets in the GitHub repository"
base64 < "$KEYSTORE" | tr -d '\n' | gh secret set ANDROID_KEYSTORE_BASE64
printf '%s' "$PASSWORD" | gh secret set ANDROID_KEYSTORE_PASSWORD
printf '%s' "$ALIAS" | gh secret set ANDROID_KEY_ALIAS
printf '%s' "$PASSWORD" | gh secret set ANDROID_KEY_PASSWORD
unset POINTY_ANDROID_KEY_PASSWORD PASSWORD

printf '%s\n' "$FINGERPRINT" > "$PIN_FILE"

cat <<MSG

Done. Release APKs are now signed with one key, so every update installs over
the app already on a till.

  Keystore:   $KEYSTORE
  Passwords:  $PROPERTIES
  Cert SHA-256: $FINGERPRINT

NEXT:
  1. BACK UP $KEY_DIR somewhere safe (password manager or offline copy).
  2. Commit ${PIN_FILE#"$REPO_ROOT"/} — release CI checks every APK against it.
  3. Tills running an APK from an earlier release must uninstall the app ONCE
     and install the next release from the shop's /clients/ page; after that,
     updates install in place.
MSG
