#!/bin/sh
# Fails unless a Linux build of the library will load on every distro the
# app supports, whatever machine built it:
#  * no glibc symbol newer than Ubuntu 22.04's (Mint 21), 2.35 by default;
#  * no libstdc++ to depend on (it is linked in: a newer GCC's adds symbol
#    versions an older till's libstdc++.so.6 lacks);
#  * nothing exported but the C ABI, pcw_*.
# A library failing any of these does not load at all on an older till, and
# the till quietly loses its camera. See src/api/glibc_compat.c.
#
#   check_linux_library.sh path/to/libpointy_camera_wedge.so [glibc floor]
set -eu
library=$1
floor=${2:-2.35}
ok=true

newest=$(objdump -T "$library" | grep -oE 'GLIBC_[0-9]+(\.[0-9]+)+' |
  sed 's/^GLIBC_//' | sort -V | tail -n 1)
if [ "$(printf '%s\n%s\n' "$newest" "$floor" | sort -V | tail -n 1)" != "$floor" ]; then
  echo "needs glibc $newest, newer than $floor, for:"
  objdump -T "$library" | grep "(GLIBC_$newest)" | awk '{ print "   " $NF }' | head -n 5
  ok=false
fi

if objdump -p "$library" | grep NEEDED | grep -q 'libstdc++'; then
  echo "depends on the system libstdc++ (link it in: -static-libstdc++)"
  ok=false
fi

exported=$(nm -D --defined-only "$library" | awk '{ print $NF }' | grep -v '^pcw_' || true)
if [ -n "$exported" ]; then
  echo "exports more than pcw_* ($(echo "$exported" | wc -l) symbols), e.g.:"
  echo "$exported" | head -n 5 | sed 's/^/   /'
  ok=false
fi

if $ok; then
  echo "$library: glibc $newest (floor $floor), no libstdc++, exports:" \
    "$(nm -D --defined-only "$library" | awk '{ print $NF }' | tr '\n' ' ')"
else
  exit 1
fi
