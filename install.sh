#!/bin/sh
#
# SPDX-License-Identifier: GPL-2.0-or-later
# install.sh - Install the Munbyn ITPP130 Linux CUPS driver
#
# Installs:
#   /usr/lib/cups/filter/rastertolabel-itpp130   (CUPS raster -> TSPL filter)
#   /usr/lib/cups/filter/gstoraster2tspl         (PDF -> raster -> TSPL wrapper)
#   /usr/share/cups/model/munbyn/ITPP130-Label-printer.ppd
#
# Then re-configures the queue <QUEUE> (default: ITPP130) to use the
# new PPD, keeping its existing device URI (e.g. usb://Printer/ITPP130?...).
#
# Source-install requirements: gcc, libcups2-dev, libcupsimage2-dev,
#               ghostscript, cups-client, cups-filters (pdftopdf +
#               gstoraster), and python3 for the regression suite.
#
# Usage: ./install.sh [queue-name]

set -e

QUEUE="${1:-ITPP130}"
DIR="$(cd "$(dirname "$0")" && pwd)"
if command -v cups-config >/dev/null 2>&1; then
    CUPS_SERVERBIN="$(cups-config --serverbin)"
elif [ -d /usr/lib/cups ]; then
    CUPS_SERVERBIN=/usr/lib/cups
else
    CUPS_SERVERBIN=/usr/libexec/cups
fi
FILTER_DIR="$CUPS_SERVERBIN/filter"

if [ -f "$DIR/rastertolabel-itpp130.c" ]; then
    echo "==> Compiling rastertolabel-itpp130"
    cc -O2 -Wall -Wextra -Wno-deprecated-declarations \
       -o "$DIR/rastertolabel-itpp130" \
       "$DIR/rastertolabel-itpp130.c" -lcups -lcupsimage
    SOURCE_FILTER="$DIR/rastertolabel-itpp130"
    SOURCE_WRAPPER="$DIR/gstoraster2tspl"
    SOURCE_PPD="$DIR/ITPP130-Label-printer.ppd"

    echo "==> Running regression checks"
    "$DIR/tests/run-tests.sh" "$SOURCE_FILTER"
elif [ -x "$DIR/usr/lib/cups/filter/rastertolabel-itpp130" ]; then
    SOURCE_FILTER="$DIR/usr/lib/cups/filter/rastertolabel-itpp130"
    SOURCE_WRAPPER="$DIR/usr/lib/cups/filter/gstoraster2tspl"
    SOURCE_PPD="$DIR/usr/share/cups/model/munbyn/ITPP130-Label-printer.ppd"
else
    echo "ERROR: no driver source or prebuilt filter found under '$DIR'." >&2
    exit 1
fi

echo "==> Running PPD conformance check"
cupstestppd -I filters -q "$SOURCE_PPD"

echo "==> Installing filter binaries"
install -d "$FILTER_DIR"
install -m 755 "$SOURCE_FILTER" "$FILTER_DIR/"
install -m 755 "$SOURCE_WRAPPER" "$FILTER_DIR/"

echo "==> Installing PPD"
mkdir -p /usr/share/cups/model/munbyn
install -m 644 "$SOURCE_PPD" \
        /usr/share/cups/model/munbyn/ITPP130-Label-printer.ppd

echo "==> Reconfiguring queue '$QUEUE' (device URI is preserved)"
DEVICE="$(lpstat -v "$QUEUE" 2>/dev/null | sed -n 's/.*: \(.*\)/\1/p')"
if [ -z "$DEVICE" ]; then
    echo "ERROR: queue '$QUEUE' not found; create it with:"
    echo "  lpadmin -p '$QUEUE' -E -v usb://Printer/ITPP130 -m munbyn/ITPP130-Label-printer.ppd"
    exit 1
fi
echo "    device: $DEVICE"
lpadmin -p "$QUEUE" -m munbyn/ITPP130-Label-printer.ppd

echo
echo "Done. Defaults: 4x6 label (100x150mm), gap tracking 3mm,"
echo "darkness 8, speed 4 ips."
echo
echo "Examples:"
echo "  lp -d $QUEUE label.pdf"
echo "  lp -d $QUEUE -o PageSize=w283h212 -o Darkness=10 label.pdf   # 4x3, darker"
echo "  lp -d $QUEUE -o zePrintRate=6 -o AdjustVertical=3 label.pdf  # faster, +3mm"
echo "  lp -d $QUEUE -o landscape label.pdf                          # rotated"
