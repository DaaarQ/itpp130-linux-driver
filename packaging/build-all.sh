#!/bin/sh
#
# SPDX-License-Identifier: GPL-2.0-or-later
#
# build-all.sh [target] - build itpp130-linux-driver packages.
#
# Targets:
#   all  (default)  - everything below
#   tars            - source tar.gz + prebuilt binary tar.gz
#   deb             - Debian/Ubuntu .deb
#   rpm             - RHEL/Fedora/openSUSE .rpm (rpmbuild builds natively)
#   arch            - Arch Linux .pkg.tar.zst
#
# Run natively on each distro's build host (LXC/VM/container) so that the
# filter binary is compiled against that distro's glibc and CUPS libraries.
#
#   Debian/Ubuntu:  apt-get install gcc libcups2-dev libcupsimage2-dev \
#                   dpkg-dev zstd libarchive-tools python3
#   Fedora/RHEL:    dnf install gcc rpm-build cups-devel zstd libarchive \
#                   python3
#
# Produces, in dist/:
#   itpp130-linux-driver-<ver>-src.tar.gz   (sources + packaging, no binaries)
#   itpp130-linux-driver-<ver>-bin.tar.gz
#   itpp130-linux-driver_<ver>-1_amd64.deb
#   itpp130-linux-driver-<ver>-1.x86_64.rpm
#   itpp130-linux-driver-<ver>-1-x86_64.pkg.tar.zst
#
set -e

VER="1.0.1"
NAME="itpp130-linux-driver"
TARGET="${1:-all}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${TMPDIR:-/tmp}/itpp130-pkgbuild"
DIST="$ROOT/dist"
SRCSTAGE="$BUILD/$NAME-$VER"

# Architecture detection: packages are built natively per host, so the
# artifacts (and the payload binary) match the build host's arch.
# deb: dpkg --print-architecture  (amd64, arm64, armhf, ...)
# rpm: rpmbuild derives it from the host automatically (no BuildArch in
#      the spec), the artifact lands in RPMS/<arch>/.
# pacman-style: uname -m mapped to pacman arch names.
DEB_ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"
case "$(uname -m)" in
  x86_64) PAC_ARCH="x86_64" ;;
  aarch64) PAC_ARCH="aarch64" ;;
  armv7l) PAC_ARCH="armv7h" ;;
  armv6l) PAC_ARCH="armv6h" ;;
  *) PAC_ARCH="$(uname -m)" ;;
esac

stage()
{
  echo "==> staging source tree"
  rm -rf "$BUILD"
  mkdir -p "$BUILD" "$DIST" "$SRCSTAGE/packaging" \
           "$SRCSTAGE/tests/golden"
  cp "$ROOT/rastertolabel-itpp130.c" "$ROOT/gstoraster2tspl" \
     "$ROOT/ITPP130-Label-printer.ppd" "$ROOT/install.sh" \
     "$ROOT/README.md" "$ROOT/REVERSE-ENGINEERING.md" "$ROOT/NOTICE" \
     "$ROOT/LICENSE" "$ROOT/Makefile" "$ROOT/CHANGELOG.md" \
     "$ROOT/CONTRIBUTING.md" "$ROOT/SECURITY.md" "$ROOT/calib.pdf" \
     "$SRCSTAGE/"
  cp -r "$ROOT/packaging"/* "$SRCSTAGE/packaging/"
  install -m 644 "$ROOT/tests/make_fixtures.c" "$SRCSTAGE/tests/"
  install -m 755 "$ROOT/tests/run-tests.sh" "$SRCSTAGE/tests/"
  install -m 644 "$ROOT/tests/golden"/*.tspl "$SRCSTAGE/tests/golden/"
}

build_src_tar()
{
  src_archive="$DIST/$NAME-$VER-src.tar.gz"

  # source archive: sources + packaging recipes + tests, no binaries
  echo "==> source tar.gz"
  tar -C "$BUILD" --exclude="$NAME-$VER/rastertolabel-itpp130" \
      -czf "$src_archive" "$NAME-$VER"

  # Generate ready-to-use Arch and Alpine recipes next to the immutable
  # source archive.  Keeping checksum placeholders in the templates avoids
  # the impossible self-reference of embedding an archive's checksum inside
  # that same archive.
  source_sha256="$(sha256sum "$src_archive" | awk '{print $1}')"
  source_sha512="$(sha512sum "$src_archive" | awk '{print $1}')"
  sed "s/@SOURCE_SHA256@/$source_sha256/" \
      "$ROOT/packaging/PKGBUILD.in" > "$DIST/PKGBUILD"
  sed "s/@SOURCE_SHA512@/$source_sha512/" \
      "$ROOT/packaging/APKBUILD.in" > "$DIST/APKBUILD"
}

build_binary()
{
  echo "==> building the filter binary (native)"
  cc -O2 -Wall -Wno-deprecated-declarations \
     -o "$SRCSTAGE/rastertolabel-itpp130" \
     "$SRCSTAGE/rastertolabel-itpp130.c" -lcups -lcupsimage
  echo "==> running regression and PPD checks"
  "$SRCSTAGE/tests/run-tests.sh" "$SRCSTAGE/rastertolabel-itpp130"
  cupstestppd -I filters -q "$SRCSTAGE/ITPP130-Label-printer.ppd"
}

build_tars()
{
  build_src_tar
  build_binary
  echo "==> binary tar.gz"
  BINROOT="$BUILD/bin-root"
  mkdir -p "$BINROOT/usr/lib/cups/filter" \
           "$BINROOT/usr/share/cups/model/munbyn" \
           "$BINROOT/usr/share/doc/$NAME"
  install -m 755 "$SRCSTAGE/rastertolabel-itpp130" \
          "$BINROOT/usr/lib/cups/filter/"
  install -m 755 "$SRCSTAGE/gstoraster2tspl" \
          "$BINROOT/usr/lib/cups/filter/"
  install -m 644 "$SRCSTAGE/ITPP130-Label-printer.ppd" \
          "$BINROOT/usr/share/cups/model/munbyn/"
  install -m 644 "$SRCSTAGE/README.md" "$SRCSTAGE/REVERSE-ENGINEERING.md" \
          "$SRCSTAGE/NOTICE" "$SRCSTAGE/LICENSE" "$SRCSTAGE/CHANGELOG.md" \
          "$SRCSTAGE/SECURITY.md" "$SRCSTAGE/calib.pdf" \
          "$BINROOT/usr/share/doc/$NAME/"
  install -m 755 "$SRCSTAGE/install.sh" "$BINROOT/"
  tar -C "$BINROOT" -czf "$DIST/$NAME-$VER-bin.tar.gz" .
}

build_deb()
{
  build_binary
  echo "==> .deb ($DEB_ARCH)"
  DEBROOT="$BUILD/deb-root"
  mkdir -p "$DEBROOT/DEBIAN" \
           "$DEBROOT/usr/lib/cups/filter" \
           "$DEBROOT/usr/share/cups/model/munbyn" \
           "$DEBROOT/usr/share/doc/$NAME"
  sed "s/^Architecture:.*/Architecture: $DEB_ARCH/" \
      "$ROOT/packaging/debian/control" > "$DEBROOT/DEBIAN/control"
  cp "$ROOT/packaging/debian/copyright" "$DEBROOT/usr/share/doc/$NAME/"
  install -m 755 "$SRCSTAGE/rastertolabel-itpp130" \
          "$DEBROOT/usr/lib/cups/filter/"
  install -m 755 "$SRCSTAGE/gstoraster2tspl" \
          "$DEBROOT/usr/lib/cups/filter/"
  install -m 644 "$SRCSTAGE/ITPP130-Label-printer.ppd" \
          "$DEBROOT/usr/share/cups/model/munbyn/"
  gzip -9n -c "$SRCSTAGE/README.md" \
       > "$DEBROOT/usr/share/doc/$NAME/README.md.gz"
  gzip -9n -c "$SRCSTAGE/REVERSE-ENGINEERING.md" \
       > "$DEBROOT/usr/share/doc/$NAME/REVERSE-ENGINEERING.md.gz"
  gzip -9n -c "$SRCSTAGE/NOTICE" \
       > "$DEBROOT/usr/share/doc/$NAME/NOTICE.gz"
  gzip -9n -c "$SRCSTAGE/LICENSE" \
       > "$DEBROOT/usr/share/doc/$NAME/LICENSE.gz"
  gzip -9n -c "$SRCSTAGE/CHANGELOG.md" \
       > "$DEBROOT/usr/share/doc/$NAME/CHANGELOG.md.gz"
  install -m 644 "$SRCSTAGE/calib.pdf" "$DEBROOT/usr/share/doc/$NAME/"
  dpkg-deb --build --root-owner-group "$DEBROOT" \
           "$DIST/${NAME}_${VER}-1_${DEB_ARCH}.deb"
}

build_rpm()
{
  echo "==> .rpm (native rpmbuild)"
  build_src_tar
  RPMROOT="$BUILD/rpmbuild"
  mkdir -p "$RPMROOT/BUILD" "$RPMROOT/RPMS" "$RPMROOT/SOURCES" \
           "$RPMROOT/SPECS" "$RPMROOT/SRPMS"
  tar -C "$BUILD" -czf "$RPMROOT/SOURCES/$NAME-$VER.tar.gz" "$NAME-$VER"
  rpmbuild --define "_topdir $RPMROOT" \
           --define "_sourcedir $RPMROOT/SOURCES" \
           --define "_specdir $RPMROOT/SPECS" \
           --define "_srcrpmdir $RPMROOT/SRPMS" \
           -bb "$ROOT/packaging/itpp130-linux-driver.spec"
  find "$RPMROOT/RPMS" -name '*.rpm' -exec cp {} "$DIST/" \;
}

build_arch()
{
  build_binary
  echo "==> Arch .pkg.tar.zst ($PAC_ARCH)"
  ARCHROOT="$BUILD/arch-root"
  mkdir -p "$ARCHROOT/usr/lib/cups/filter" \
           "$ARCHROOT/usr/share/cups/model/munbyn" \
           "$ARCHROOT/usr/share/doc/$NAME"
  install -m 755 "$SRCSTAGE/rastertolabel-itpp130" \
          "$ARCHROOT/usr/lib/cups/filter/"
  install -m 755 "$SRCSTAGE/gstoraster2tspl" \
          "$ARCHROOT/usr/lib/cups/filter/"
  install -m 644 "$SRCSTAGE/ITPP130-Label-printer.ppd" \
          "$ARCHROOT/usr/share/cups/model/munbyn/"
  install -m 644 "$SRCSTAGE/README.md" "$SRCSTAGE/REVERSE-ENGINEERING.md" \
          "$SRCSTAGE/NOTICE" "$SRCSTAGE/LICENSE" "$SRCSTAGE/CHANGELOG.md" \
          "$SRCSTAGE/SECURITY.md" "$SRCSTAGE/calib.pdf" \
          "$ARCHROOT/usr/share/doc/$NAME/"
  {
    echo "# Generated by build-all.sh"
    echo "pkgname = $NAME"
    echo "pkgbase = $NAME"
    echo "pkgver = $VER-1"
    echo "pkgdesc = Linux CUPS driver for the Munbyn ITPP130 label printer (TSPL), reverse engineered from the vendor macOS/Windows drivers"
    echo "url = https://github.com/DaaarQ/itpp130-linux-driver"
    echo "builddate = $(date +%s)"
    echo "packager = build-all.sh"
    echo "size = $(du -sb "$ARCHROOT" | awk '{print $1}')"
    echo "arch = $PAC_ARCH"
    echo "license = GPL-2.0-or-later"
    for d in "cups>=2.4" "cups-filters>=1.28" "ghostscript" "libcups" \
             "glibc>=2.34"; do
      echo "depend = $d"
    done
  } > "$ARCHROOT/.PKGINFO"
  (cd "$ARCHROOT" && bsdtar --format=mtree \
    --options='!all,use-set,type,uid,gid,mode,time,size,md5,sha256,link' \
    -cf - --exclude .MTREE . > "$ARCHROOT/.MTREE")
  (cd "$ARCHROOT" && bsdtar -cf - .) | \
    zstd -q -19 -o "$DIST/$NAME-$VER-1-$PAC_ARCH.pkg.tar.zst"
}

stage

case "$TARGET" in
  tars) build_tars ;;
  deb)  build_deb ;;
  rpm)  build_rpm ;;
  arch) build_arch ;;
  all)  build_tars; build_deb; build_rpm; build_arch ;;
  *) echo "unknown target: $TARGET (all|tars|deb|rpm|arch)"; exit 1 ;;
esac

echo "==> done"
ls -la "$DIST"
