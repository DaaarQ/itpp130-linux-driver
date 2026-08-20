# Changelog

All notable changes to this project are documented here.

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
