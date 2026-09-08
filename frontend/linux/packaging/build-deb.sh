#!/usr/bin/env bash
#
# Package the built Linux bundle as an installable .deb — the Linux counterpart
# of the Windows Inno Setup installer.
#
#   bash frontend/linux/packaging/build-deb.sh <version> [bundle-dir] [out-dir]
#
# Why a package at all: the portable tar.gz leaves the shop with a folder and a
# hand-made launcher, and a hand-made launcher has no icon — the desktop only
# draws one for an app whose .desktop file and hicolor icons are installed where
# the icon theme can find them. This puts them there, and registers the app in
# the menu, so a Linux Mint till looks like a Windows one.
#
# Runs on Debian/Ubuntu (Linux Mint is Ubuntu-based) and needs dpkg-deb, which
# is why it lives in CI or on a Linux dev box, not on the release manager's Mac.
set -euo pipefail

PKG_NAME="pointy"
APP_ID="ly.daftr"           # matches APPLICATION_ID in linux/CMakeLists.txt
BINARY="pointy_frontend"    # matches BINARY_NAME there
INSTALL_DIR="/opt/${PKG_NAME}"
ICON_SIZES="16 24 32 48 64 128 256 512"

HERE="$(cd "$(dirname "$0")" && pwd)"
FRONTEND="$(cd "${HERE}/../.." && pwd)"
REPO="$(cd "${FRONTEND}/.." && pwd)"

VERSION="${1:-}"
BUNDLE="${2:-${FRONTEND}/build/linux/x64/release/bundle}"
OUTDIR="${3:-${REPO}/dist}"

[ -n "${VERSION}" ] || { echo "usage: $0 <version> [bundle-dir] [out-dir]" >&2; exit 2; }
VERSION="${VERSION#v}"
# A Debian version must start with a digit; anything else is rejected at install
# time rather than here, which is a much worse place to find out.
case "${VERSION}" in
  [0-9]*) ;;
  *) echo "ERROR: '${VERSION}' is not a usable Debian version (must start with a digit)" >&2; exit 2 ;;
esac

command -v dpkg-deb >/dev/null 2>&1 || {
  echo "ERROR: dpkg-deb not found — build the .deb on Debian/Ubuntu (or in CI)" >&2
  exit 1
}
[ -x "${BUNDLE}/${BINARY}" ] || {
  echo "ERROR: no ${BINARY} in ${BUNDLE} — run 'flutter build linux --release' first" >&2
  exit 1
}

root="$(mktemp -d)"
trap 'rm -rf "${root}"' EXIT

echo "==> Staging ${INSTALL_DIR}…"
install -d "${root}${INSTALL_DIR}"
cp -a "${BUNDLE}/." "${root}${INSTALL_DIR}/"
# The tarball is extracted by a user and keeps whatever the runner left behind;
# a package's files are root-owned and readable by every cashier account on the
# till. Capital X adds +x to directories and to files that already carry it, so
# the app (and any helper a plugin ships) stays executable and a data file does
# not become one.
chmod -R a+rX,go-w "${root}${INSTALL_DIR}"

echo "==> Staging the launcher, the menu entry and the icons…"
install -d "${root}/usr/bin"
ln -s "${INSTALL_DIR}/${BINARY}" "${root}/usr/bin/${PKG_NAME}"

install -d "${root}/usr/share/applications"
install -m 0644 "${HERE}/${APP_ID}.desktop" "${root}/usr/share/applications/${APP_ID}.desktop"

for size in ${ICON_SIZES}; do
  src="${HERE}/icons/${size}x${size}.png"
  [ -f "${src}" ] || { echo "ERROR: missing icon ${src}" >&2; exit 1; }
  install -d "${root}/usr/share/icons/hicolor/${size}x${size}/apps"
  install -m 0644 "${src}" "${root}/usr/share/icons/hicolor/${size}x${size}/apps/${APP_ID}.png"
done

install -d "${root}/usr/share/doc/${PKG_NAME}"
cat > "${root}/usr/share/doc/${PKG_NAME}/README.Debian" <<EOF
دفتر (Daftar) — point of sale.

The application lives in ${INSTALL_DIR}; /usr/bin/${PKG_NAME} launches it from a
terminal and the menu entry launches it from the desktop.

Updates: a till installed from this package cannot replace itself in place —
${INSTALL_DIR} belongs to root. Download the current .deb from the shop server's
LAN page (http://<server>/clients/) and install it over this one.
EOF
chmod 0644 "${root}/usr/share/doc/${PKG_NAME}/README.Debian"

echo "==> Writing package metadata…"
install -d "${root}/DEBIAN"
installed_size="$(du -sk "${root}" | awk '{print $1}')"

# Dependencies are written by hand rather than derived with dpkg-shlibdeps,
# because CI runs on Ubuntu 24.04 where the time_t transition renamed these
# libraries with a "t64" suffix — generated names would install on Mint 22 and
# be unsatisfiable on Mint 21. The alternatives below resolve on both.
#   gtk/glib   the Flutter GTK runner, file_selector_linux, url_launcher_linux,
#              printing (gtk's unix print dialog)
#   gstreamer  audioplayers_linux (barcode scan feedback chimes), record_linux
cat > "${root}/DEBIAN/control" <<EOF
Package: ${PKG_NAME}
Version: ${VERSION}
Section: utils
Priority: optional
Architecture: amd64
Maintainer: Daftar <noreply@daftr.ly>
Installed-Size: ${installed_size}
Depends: libc6, libstdc++6, liblzma5,
 libgtk-3-0 | libgtk-3-0t64,
 libglib2.0-0 | libglib2.0-0t64,
 libgstreamer1.0-0,
 libgstreamer-plugins-base1.0-0
Recommends: gstreamer1.0-plugins-good, gstreamer1.0-plugins-base
Description: Daftar point of sale (دفتر)
 Point of sale, inventory, purchasing and reporting for a shop, talking to the
 shop's own server on the local network.
EOF

# The icon theme and the desktop database are caches: a package that writes into
# them without refreshing them installs an app with no icon, which is the bug
# this package exists to fix.
cat > "${root}/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
if [ "$1" = "configure" ]; then
  if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache -q -f -t /usr/share/icons/hicolor || true
  fi
  if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database -q /usr/share/applications || true
  fi
fi
exit 0
EOF

cat > "${root}/DEBIAN/postrm" <<'EOF'
#!/bin/sh
set -e
if [ "$1" = "remove" ] || [ "$1" = "purge" ]; then
  if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache -q -f -t /usr/share/icons/hicolor || true
  fi
  if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database -q /usr/share/applications || true
  fi
fi
exit 0
EOF

chmod 0755 "${root}/DEBIAN/postinst" "${root}/DEBIAN/postrm"

mkdir -p "${OUTDIR}"
deb="${OUTDIR}/${PKG_NAME}-${VERSION}-linux-x64.deb"
# --root-owner-group so the files land as root:root without needing fakeroot.
dpkg-deb --build --root-owner-group "${root}" "${deb}" >/dev/null

echo "==> ${deb}"
dpkg-deb --info "${deb}" | sed 's/^/    /'
ls -lh "${deb}" | awk '{print "    size: " $5}'

# Diagnostic, not a gate: if a Flutter or plugin upgrade starts linking a
# library that the hand-written Depends above does not cover, it shows up here
# as a soname with no matching line in the control file.
if command -v objdump >/dev/null 2>&1; then
  echo "==> Shared libraries the app and its plugins need (check against Depends):"
  {
    objdump -p "${BUNDLE}/${BINARY}" | awk '/NEEDED/ {print $2}'
    find "${BUNDLE}/lib" -name '*.so' -exec objdump -p {} \; 2>/dev/null | awk '/NEEDED/ {print $2}'
  } | sort -u | sed 's/^/    /'
fi
