# Changelog

All notable changes to this project are documented here.

## 1.0.3 - 2026-08-21

- Change the default `AdjustVertical` from 5 mm to 0 mm (no vertical origin
  shift).  Well-formed 4x6" label PDFs now print at their designed position
  out of the box; per-printer sensor offsets are corrected with the
  `AdjustVertical` option as needed.

## 1.0.2 - 2026-08-21

- Remove the inert `MediaMethod` PPD option from this direct-thermal-only
  printer so every exposed setting has an observable effect.
- Name and document raster dimension and row-allocation safety limits.

## 1.0.1 - 2026-08-20

- Reject malformed raster formats, unsafe row layouts, unsupported
  resolutions, and printer-exceeding dimensions.
- Treat truncated, cancelled, output-failed, and malformed later pages as
  failed jobs while preserving TSPL bitmap framing.
- Correct non-byte-aligned 1-bit row padding.
- Honor copies for file-backed raster jobs without duplicating copies already
  expanded by `pdftopdf`.
- Make raster fixtures reproducible and add 14 regression tests.
- Normalize PPD media keys and remove conformance errors.
- Correct Debian, Fedora, Arch, Alpine, and source packaging metadata.

## 1.0.0 - 2026-08-20

- Initial clean-room Linux CUPS implementation of the reverse-engineered
  ITPP130 TSPL output path.
