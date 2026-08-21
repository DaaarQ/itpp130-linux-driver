# Reverse engineering notes - Munbyn ITPP130 driver

Sources analysed:

* `ITPP130-Mac-Driver-Latest-v1.5.8.1.dmg` - vendor macOS driver package
  (`pkgutil --expand`, payload extracted with bsdtar):
  - `Library/Printers/ITPP130/Filter/rastertolabel` - CUPS filter,
    Mach-O x86_64, **not stripped** (full symbol table)
  - `Library/Printers/ITPP130/PPDs/ITPP130 Label printer.ppd`
  - `Library/Printers/ITPP130/launch/LaunchITPP130` - BT/USB companion daemon
  - `Library/LaunchDaemons/com.launch.ITPP130.plist`
* `Munbyn-Win-Driver-Latest-v1.2.7 (1).exe` - Windows driver (Inno Setup,
  extracted with innoextract):
  - `Munbyn_ITPP130.DDD` - printer config data file ("Munbyn ITPP130" +
    "TSPL" strings, 203 dpi at offset 0x84)
  - `MunbynWinLatestRender_64.dll` - XPS render DLL

## Filter dispatch (from `rastertolabel` disassembly)

The vendor filter selects its output language from the PPD `*cupsModelNumber`
(jump tables at 0x100001e78 / 0x1000023c0 / 0x1000028c4):

| Model | Output language | Key commands |
|-------|-----------------|--------------|
| 16    | PCL             | ESC&l6D, ESC*r1A, ESC*b3M, ESC*b<len>W |
| 17    | ESC/POS-style   | ESC L, ESC D, N, OD, S, D, q |
| 18    | ZPL             | ^XA, ^PR, ^LL, ^MN, ^FO0,0^XGR, ^IDR, ^XZ |
| 19    | CPCL            | ! 0 w h, PAGE-WIDTH/HEIGHT |
| **20**| **TSPL**        | SIZE, REFERENCE, DIRECTION, GAP, BLINE, DENSITY, SPEED, SETC, CLS, BITMAP, PRINT |

ITPP130 = model 20 = TSPL.

## TSPL job stream (model 20, `_StartPage` @0x14a6, `_EndPage` @0x1f83)

```
1024 x 0x00                      (wake burst)
SIZE <w> mm,<h> mm               ((cupsWidth+7)/8, (cupsHeight+7)/8; 8 dots/mm)
REFERENCE <x>,<y>                (AdjustHoriaontal/AdjustVertical * 8)
DIRECTION <n>,0                  (Rotate 0..3, passed through)
GAP <h> mm,<o> mm                (zeMediaTracking=Gap; GAP 0 mm,0 mm for
                                  Continuous; BLINE <h> mm,<o> mm for BLine)
DENSITY <n>                      (Darkness; omitted for "Default")
SPEED <n>                        (zePrintRate; 1 clamped to 2)
SETC AUTODOTTED ON/OFF           (AutoDotted)
SETC PAUSEKEY ON
SETC WATERMARK OFF
CLS
BITMAP 0,0,<wb>,<h>,1,<raw 1-bit data, wb=(cupsWidth+7)/8>
\n                               (single newline)
PRINT 1,1
```

The Linux filter retains `PRINT 1,1` for piped raster data because
`pdftopdf` has already expanded copies.  When it is the first filter and
reads a raster file directly, it uses `PRINT 1,n` to honor CUPS argument 4.

## Raster conversion (`_OutputLine` @0x256d)

Per output byte, 8 source pixels are packed MSB-first.  The vendor keeps the
bit set only while the source byte is `< 0xC9` (201) and then emits `~acc`,
i.e.:

```
out bit = (src >= 201) ? 1 : 0
```

The CUPS raster produced by cups-filters on Linux (and effectively by the
macOS pipeline too) stores dark pixels with LOW byte values
(text = 0x00, background = 0xFF), and TSPL BITMAP data uses 0 = black
(verified bit-for-bit against an independent cups-filters `pdftotspl`
reference stream). Pixels below ~79% brightness therefore print black; the final
byte of each row is padded with white (the vendor pads bits beyond
cupsWidth the same way).

Bits beyond `cupsWidth` are skipped (not read); padding white.

## Linux pipeline

The PPD uses `*cupsFilter: "application/pdf 0 gstoraster2tspl"` where
`gstoraster2tspl` is `pdftopdf | gstoraster | rastertolabel-itpp130`:

* `pdftopdf` applies requested page size (incl. `PageSize=Custom.WxH`),
  copies and orientation.
* `gstoraster` (Ghostscript) renders PDF -> CUPS raster with correct page
  rotation. Testing found non-uniform landscape scaling in the poppler-based
  `pdftoraster` path; Ghostscript preserved the measured geometry and matched
  the vendor macOS rendering path.

`application/vnd.cups-raster` jobs (e.g. from `imagetoraster`) go directly
through `rastertolabel-itpp130`.
