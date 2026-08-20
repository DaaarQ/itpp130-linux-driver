# Contributing

Changes are welcome, especially reports backed by captured TSPL output or a
reproducible CUPS raster fixture.

Before submitting a change, install the CUPS development headers and run:

```sh
make check
make sanitize
```

Do not commit vendor installers, extracted vendor binaries, generated raster
fixtures, compiled filters, printer serial numbers, or captured documents
containing private data. Keep protocol claims traceable in
`REVERSE-ENGINEERING.md`, and add a regression whenever filter behavior
changes.
