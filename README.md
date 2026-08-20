# Munbyn ITPP130 - Linux CUPS Driver

[![CI](https://github.com/DaaarQ/itpp130-linux-driver/actions/workflows/ci.yml/badge.svg)](https://github.com/DaaarQ/itpp130-linux-driver/actions/workflows/ci.yml)

A complete Linux CUPS driver for the Munbyn ITPP130 / ITPP130B 4x6" thermal
label printer (203 dpi, 100 mm wide), reverse engineered from the vendor's
official macOS driver (`rastertolabel` filter, ITPP130 Mac Driver v1.5.8.1)
and the Windows driver's `Munbyn_ITPP130.DDD` data file.

## What was reverse engineered

The vendor filter selects its output language from the PPD `*cupsModelNumber`:

| Model | Output language | Used by |
|-------|-----------------|---------|
| 16    | PCL             | -       |
| 17    | ESC/POS-style   | -       |
| 18    | ZPL             | -       |
| 19    | CPCL            | -       |
| **20**| **TSPL**        | **ITPP130** |

The ITPP130 PPD ships with `*cupsModelNumber: 20`, so the printer speaks
**TSPL** (TSPL2 dialect; confirmed independently by the Windows driver's
`.DDD` file, which is labelled "TSPL", and by the TSPL the old generic
`pdftotspl` setup was already sending to this printer).

### Job stream produced per label (exact vendor sequence)

```
<1024 x 0x00 wake burst>
SIZE <w> mm,<h> mm        (media size in mm; 8 dots/mm @ 203 dpi)
REFERENCE <x>,<y>         (AdjustHoriaontal / AdjustVertical x 8 dots/mm)
DIRECTION <n>,0           (Rotate: 0,1,2,3)
GAP <h> mm,<o> mm         (zeMediaTracking Gap, or GAP 0 for Continuous,
                           or BLINE h mm,o mm for Black Line)
DENSITY <n>               (Darkness 0-15; omitted when "Default")
SPEED <n>                 (zePrintRate 1-8; 1 is clamped to 2)
SETC AUTODOTTED ON/OFF    (AutoDotted)
SETC PAUSEKEY ON
SETC WATERMARK OFF
CLS
BITMAP 0,0,<wb>,<h>,1,<raw 1-bit bitmap, MSB-first, wb = (width+7)/8>
<newline>
PRINT 1,<copies>
```

Raster conversion (vendor `_OutputLine` model-20 path): the CUPS raster
pipeline on this server writes dark pixels with low byte values
(text = 0x00, background = 0xFF) and TSPL bitmap data uses 0 for black
(verified against the known-good `pdftotspl` output).  A source pixel
>= 201 stays white; anything darker prints black.  The final byte of each
row is padded with white.

## Files

| File | Purpose |
|------|---------|
| `rastertolabel-itpp130.c` | CUPS filter: CUPS raster -> TSPL (libcups + libcupsimage, same API as the vendor binary) |
| `ITPP130-Label-printer.ppd` | Original Linux PPD: 46 label sizes + custom sizes, darkness, speed, media tracking, gap/mark height+offset, rotation, horizontal/vertical offset, auto-dotted |
| `gstoraster2tspl` | PDF -> TSPL wrapper: `pdftopdf | gstoraster | rastertolabel-itpp130` |
| `install.sh` | Build + install + queue reconfiguration |

### Why pdftopdf + gstoraster (and not the default pdftoraster)

- `pdftopdf` applies the requested page size (including `Custom.WxH`),
  copy count and orientation to the PDF.
- `gstoraster` (Ghostscript) renders PDF -> CUPS raster and applies page
  rotation (landscape) correctly.  The poppler-based `pdftoraster` shipped
  with cups-filters 1.28.17 on this server renders landscape jobs
  non-uniformly scaled (broken geometry); ghostscript does not.
  Ghostscript-based rasterization is also what the vendor macOS driver
  effectively uses, so output matches the vendor driver.

## Install (Debian/Proxmox, CUPS 2.4)

```
apt-get install gcc libcups2-dev libcupsimage2-dev ghostscript cups-client \
  cups-filters python3
./install.sh [queue-name]        # default queue: Munbyn-ITPP130B
```

The queue's device URI (e.g. `usb://Printer/ITPP130?serial=0000000`) is
preserved. The installer runs the regression suite before replacing files.
For packaged installs, prefer `apt install ./itpp130-linux-driver_*.deb` or
`dnf install ./itpp130-linux-driver-*.rpm`.

## Packages / prebuilt binaries

`packaging/build-all.sh` builds natively per distro (run it inside the
target distro's build host/LXC): tar.gz (source + binary), .deb, .rpm and
Arch .pkg.tar.zst, with the architecture detected from the build host
(x86_64, aarch64/arm64, armhf/armv7h, ...) — Raspberry Pi print servers
included.  The source build emits checksum-pinned Arch (`PKGBUILD`) and
Alpine (`APKBUILD`) recipes beside the tarball; a Gentoo ebuild is also
provided.  All three fetch the matching GitHub release source archive.

Prebuilt binaries are dynamically linked against the build host's
libcups/libcupsimage/glibc; each package declares its real requirements
(e.g. `libc6 >= 2.34`, auto-generated `GLIBC_x.y` requires in the rpm),
so a mismatched host is rejected at install time rather than crashing at
runtime.  For anything else, rebuild from the source tarball — the driver
is a single small C file.

## Licensing / provenance

The filter, wrapper, docs, packaging and the PPD are original work
licensed GPL-2.0-or-later.  The PPD's factual content (media sizes,
option choices and TSPL behaviour) was determined by reverse engineering
the vendor drivers.  Media keywords use their actual PostScript page
dimensions; for example, the 4x6-inch choice is `w283h425`.  The file does
not reproduce the vendor PPD's expression.  See `NOTICE` for the full
provenance statement.

## Usage

```
lp -d Munbyn-ITPP130B label.pdf
lp -d Munbyn-ITPP130B -o PageSize=w283h212 label.pdf       # 4x3" label
lp -d Munbyn-ITPP130B -o PageSize=Custom.283x850 label.pdf # 100x300mm
lp -d Munbyn-ITPP130B -o Darkness=12 -o zePrintRate=6 a.pdf
lp -d Munbyn-ITPP130B -o AdjustVertical=5 -o AdjustHoriaontal=-2 a.pdf
lp -d Munbyn-ITPP130B -o zeMediaTracking=Continuous a.pdf # continuous media
lp -d Munbyn-ITPP130B -o zeMediaTracking=BLine -o GapOrMarkHeight=5 a.pdf
lp -d Munbyn-ITPP130B -o Rotate=1 a.pdf                    # 180 deg (DIRECTION)
lp -d Munbyn-ITPP130B -o landscape a.pdf                   # rotated content
```

### PPD options

| Option | Choices (default) | Effect |
|--------|-------------------|--------|
| `PageSize` | 46 sizes + `Custom.WxH` (`w283h425` = 4x6") | Label size |
| `Darkness` | Default..15 (8) | Print head energy (TSPL `DENSITY`) |
| `zePrintRate` | Default..8 ips (4) | Print speed (TSPL `SPEED`) |
| `zeMediaTracking` | Continuous / Gap / BLine (Gap) | Gap/mark/continuous detection |
| `GapOrMarkHeight` | 0-10 mm (3) | Gap or black-mark height |
| `GapOrMarkOffset` | 0-10 mm (0) | Gap or mark offset |
| `Rotate` | 0/180/90/270 (0) | Printer-side rotation (TSPL `DIRECTION`) |
| `AdjustHoriaontal` | -20..20 mm (0) | Horizontal origin shift |
| `AdjustVertical` | -20..20 mm (5) | Vertical origin shift (see above) |
| `AutoDotted` | 0/1 (0) | Blur-compensation line mode |
| `MediaMethod` | Normal / Direct | **Inert** - the ITPP130 is direct-thermal-only; kept for job compatibility |
| `landscape` | - | 90-degree rotated content |

Note: `AdjustHoriaontal` (sic, missing 'z') and `AutoDotted`'s choice label
`Ture` (sic) are the vendor's original spellings and are load-bearing —
the filter looks them up verbatim.  Use them exactly as spelled above.

## Input validation

The filter validates every raster header before printing and rejects
malformed input with a clear error instead of misprinting: colorspace
must be CUPS_CSPACE_W (K is rejected - its polarity differs per
producer), 1 or 8 bits per pixel with a bytes-per-line that covers the
declared width, chunky order, one color, 203 dpi and printer-bounded
dimensions.  Truncated input or a cancelled job pads the remaining
bitmap with white so the printer always receives the declared byte count
and a terminating `PRINT` command, and the job exits non-zero so CUPS marks
it failed.

## Tests

`tests/run-tests.sh` locks in the reverse-engineered behavior:

- golden-file comparison of the full TSPL stream (default and option sets)
- threshold/polarity checks (201 threshold, white padding, framing)
- raster header validation (bad colorspace must be rejected)
- copy handling for both file-backed and piped raster input
- cancellation: SIGTERM mid-job must pad the BITMAP payload to its declared
  length and terminate with `PRINT 1,1` so the printer stays in sync

Regenerate goldens after an intentional behavior change with
`./run-tests.sh --regenerate`.

## Print position (top margin)

The ITPP130's gap-mode print origin sits ~3.7 mm *above* the physical top
of the label (sensor-to-printhead offset), so content prints several mm
higher than designed: a label whose bitmap starts with 4-5 mm of white
prints with ~0 top margin and an oversized bottom margin.

The PPD ships with `DefaultAdjustVertical: 5` (5 mm), which compensates
this offset and restores the design's margins (~5 mm top and bottom on a
true 4x6" label).  Fine-tune per job or per queue with:

```
lp -o AdjustVertical=4 file.pdf     # 1 mm less compensation
lpoptions -p Munbyn-ITPP130B -o AdjustVertical=6
```

To measure the exact offset on your printer, print the calibration ruler
(`calib.pdf` in the source tree) with `-o AdjustVertical=0`: the topmost
ruler mark that is visible at the very top edge of the label is the raw
offset; the compensated ruler (default 5 mm) should show the 0 mm mark
just above the label edge with ~5 mm of white above it.

Horizontal positioning (`AdjustHoriaontal`) is available for centering if
the media is wider than 100 mm.

## Notes / verification

- Verified bit-exact against the previously-working `pdftotspl` queue for
  the same input (text rows, polarity, page framing).
- Tested through the real CUPS pipeline: text, PNG, multi-page PDF,
  landscape (correct rotated geometry, measured line positions),
  custom sizes up to 100x300mm, copies, and every PPD option.
- For a single copy, the 1024-byte zero wake burst, `SETC` lines, `BITMAP`
  mode `1` and trailing newline before `PRINT 1,1` replicate the vendor
  binary exactly. Higher copy counts use TSPL's `PRINT 1,n` argument.

## Rollback

Back up an existing queue PPD before installation if you may need it later:

```sh
sudo cp /etc/cups/ppd/Munbyn-ITPP130B.ppd ./Munbyn-ITPP130B.ppd.backup
```

Restore it with your distribution's CUPS administration tools or reinstall
the previous driver package.
