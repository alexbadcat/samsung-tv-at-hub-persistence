#!/bin/bash
# Build patched static ARM dropbear for Samsung Tizen TV.
# Requires: debian/ubuntu with gcc-arm-linux-gnueabihf, autoconf, patchelf (optional).
set -e
DROPBEAR_VER="2026.94"   # tested version
WORKDIR="${WORKDIR:-/tmp/dropbear-build}"

mkdir -p "$WORKDIR"
cd "$WORKDIR"
if [ ! -d dropbear-git ]; then
  git clone --depth 1 https://github.com/mkj/dropbear.git dropbear-git
fi
cd dropbear-git

# Apply patch
if ! grep -q "FAKE_ROOT fallback" src/common-session.c 2>/dev/null; then
  git apply "$(dirname "$0")/fakeroot.patch"
fi

# Local options
cp "$(dirname "$0")/localoptions.h" ./localoptions.h

autoreconf -fi
CC=arm-linux-gnueabihf-gcc \
  LDFLAGS="-static" \
  CFLAGS="-Os" \
  ./configure --host=arm-linux-gnueabihf --disable-syslog --disable-zlib
make -j4 PROGRAMS="dropbear dropbearkey" MULTI=0
file dropbear dropbearkey
echo ""
echo "Done. Binaries:"
ls -la "$WORKDIR/dropbear-git/dropbear" "$WORKDIR/dropbear-git/dropbearkey"
