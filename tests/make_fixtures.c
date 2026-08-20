/*
 * SPDX-License-Identifier: GPL-2.0-or-later
 *
 * make_fixtures.c - generate CUPS raster fixtures for the test suite.
 *
 * Build:  cc -o make_fixtures make_fixtures.c -lcupsimage
 * Run:    ./make_fixtures <outdir>
 *
 * Produces:
 *   test.ras      100x100 px, CUPS_CSPACE_W, 8bpp - deterministic pattern
 *                that locks in the threshold/polarity behavior:
 *                rows 0-9:   solid black (0x00)
 *                rows 10-19: solid white (0xFF)
 *                rows 20-29: gray 190 (must print black, < 201)
 *                rows 30-39: gray 200 (must print black, < 201)
 *                rows 40-49: gray 201 (must stay white, >= 201)
 *                rows 50-59: gray 210 (must stay white)
 *                rows 60-69: gray 128 (must print black, < 201)
 *                rows 70-99: vertical bars 8px black / 8px white
 *   big.ras      100 x 2000 px, same space (used by the cancel test)
 *   onebit.ras   100x50 px, CUPS_CSPACE_W, 1bpp: rows 0-24 all black
 *                (0x00), rows 25-49 all white (0xFF) - locks in the
 *                1-bit path (bit 1 = white, emitted verbatim) and the
 *                tail-padding of the final byte.
 *   badcolor.ras test.ras with cupsColorSpace = CUPS_CSPACE_RGB
 *   badspace.ras test.ras with cupsColorSpace = CUPS_CSPACE_K
 *   badbpl.ras   test.ras with cupsBytesPerLine shrunk to 1 (row layout
 *                must be rejected: 1 byte cannot cover 100 pixels)
 *   badlargebpl.ras  test.ras with a 4097-byte row declaration
 *   badres.ras   test.ras with HWResolution = 300 dpi
 *   truncated.ras  test.ras cut off after 50 of 100 rows
 *   multipage_bad.ras  valid first page followed by an RGB page
 */

#include <cups/raster.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void
write_ras(const char *path, unsigned w, unsigned h, int color_space,
          unsigned bits, unsigned res, unsigned bpl_override,
          unsigned char (*pattern)(unsigned x, unsigned y))
{
  cups_raster_t *ras;
  cups_page_header2_t hdr;
  FILE *fp;
  unsigned y, x, bpl;
  unsigned char *row;

  memset(&hdr, 0, sizeof(hdr));
  hdr.cupsWidth = w;
  hdr.cupsHeight = h;
  hdr.cupsBitsPerColor = bits;
  hdr.cupsBitsPerPixel = bits;
  bpl = (bits == 1) ? (w + 7) / 8 : w;
  hdr.cupsBytesPerLine = bpl_override ? bpl_override : bpl;
  hdr.cupsColorOrder = CUPS_ORDER_CHUNKED;
  hdr.cupsColorSpace = color_space;
  hdr.cupsNumColors = 1;
  hdr.HWResolution[0] = res;
  hdr.HWResolution[1] = res;
  row = malloc(bpl ? bpl : 1);

  fp = fopen(path, "wb");
  if (!fp)
  {
    perror(path);
    exit(1);
  }
  ras = cupsRasterOpen(fileno(fp), CUPS_RASTER_WRITE);
  if (!ras || !cupsRasterWriteHeader2(ras, &hdr))
  {
    fprintf(stderr, "cannot write header: %s\n", path);
    exit(1);
  }
  for (y = 0; y < h; y++)
  {
    if (bits == 1)
    {
      memset(row, 0, bpl);
      for (x = 0; x < w; x++)
        if (pattern(x, y))
          row[x / 8] |= (0x80 >> (x % 8));
    }
    else
    {
      for (x = 0; x < bpl; x++)
        row[x] = pattern(x, y);
    }
    if (!cupsRasterWritePixels(ras, row, bpl))
    {
      fprintf(stderr, "cannot write pixels: %s\n", path);
      exit(1);
    }
  }
  cupsRasterClose(ras);
  fclose(fp);
  free(row);
}

static unsigned char
test_pattern(unsigned x, unsigned y)
{
  if (y < 10)       return 0x00;              /* black   */
  if (y < 20)       return 0xFF;              /* white   */
  if (y < 30)       return 190;               /* < 201 -> black */
  if (y < 40)       return 200;               /* < 201 -> black */
  if (y < 50)       return 201;               /* >= 201 -> white */
  if (y < 60)       return 210;               /* >= 201 -> white */
  if (y < 70)       return 128;               /* < 201 -> black */
  return ((x / 8) % 2) ? 0xFF : 0x00;         /* bars    */
}

static unsigned char
big_pattern(unsigned x, unsigned y)
{
  return test_pattern(x, y % 100);
}

static unsigned char
onebit_pattern(unsigned x, unsigned y)
{
  /* pipeline convention: 1 = white (bright), 0 = black (dark) */
  (void)x;
  return y >= 25 ? 1 : 0;
}

/* Copy src to dst and patch the cupsBytesPerLine header field.  RaS3 uses
 * a four-byte stream magic followed by the serialized CUPS page header;
 * derive the field position from the build host's CUPS headers instead of
 * assuming one platform-specific structure offset. */
static void
copy_patch_bpl(const char *dir, const char *srcname, const char *dstname,
               unsigned bpl)
{
  char src[512], dst[512];
  FILE *f;
  long size;
  unsigned char *buf;

  snprintf(src, sizeof(src), "%s/%s", dir, srcname);
  snprintf(dst, sizeof(dst), "%s/%s", dir, dstname);
  f = fopen(src, "rb");
  if (!f)
  {
    perror(src);
    exit(1);
  }
  fseek(f, 0, SEEK_END);
  size = ftell(f);
  rewind(f);
  buf = malloc(size);
  if (fread(buf, 1, size, f) != (size_t)size)
    exit(1);
  fclose(f);

  size_t field_offset = 4 + offsetof(cups_page_header2_t, cupsBytesPerLine);

  if (size < (long)(field_offset + sizeof(bpl)))
  {
    fprintf(stderr, "fixture too small to patch: %s\n", src);
    exit(1);
  }
  buf[field_offset + 0] = (unsigned char)(bpl & 0xFF);
  buf[field_offset + 1] = (unsigned char)((bpl >> 8) & 0xFF);
  buf[field_offset + 2] = (unsigned char)((bpl >> 16) & 0xFF);
  buf[field_offset + 3] = (unsigned char)((bpl >> 24) & 0xFF);

  f = fopen(dst, "wb");
  if (!f || fwrite(buf, 1, size, f) != (size_t)size)
    exit(1);
  fclose(f);
  free(buf);
}

/* Build a two-page stream by copying a complete first raster and appending
 * the second raster without its four-byte stream magic.  Each source has
 * one page, so the resulting stream has one magic followed by two page
 * headers and their pixel data. */
static void
concat_pages(const char *dir, const char *first_name, const char *second_name,
             const char *dst_name)
{
  char first[512], second[512], dst[512];
  FILE *in, *out;
  unsigned char buf[4096];
  size_t n;

  snprintf(first, sizeof(first), "%s/%s", dir, first_name);
  snprintf(second, sizeof(second), "%s/%s", dir, second_name);
  snprintf(dst, sizeof(dst), "%s/%s", dir, dst_name);

  out = fopen(dst, "wb");
  if (!out)
  {
    perror(dst);
    exit(1);
  }

  in = fopen(first, "rb");
  if (!in)
  {
    perror(first);
    exit(1);
  }
  while ((n = fread(buf, 1, sizeof(buf), in)) > 0)
    if (fwrite(buf, 1, n, out) != n)
      exit(1);
  fclose(in);

  in = fopen(second, "rb");
  if (!in)
  {
    perror(second);
    exit(1);
  }
  if (fread(buf, 1, 4, in) != 4)
  {
    fprintf(stderr, "fixture has no raster magic: %s\n", second);
    exit(1);
  }
  while ((n = fread(buf, 1, sizeof(buf), in)) > 0)
    if (fwrite(buf, 1, n, out) != n)
      exit(1);
  fclose(in);
  fclose(out);
}

int
main(int argc, char **argv)
{
  const char *dir = argc > 1 ? argv[1] : ".";
  char path[512];
  FILE *f;
  long size;
  unsigned char *buf;

  snprintf(path, sizeof(path), "%s/test.ras", dir);
  write_ras(path, 100, 100, CUPS_CSPACE_W, 8, 203, 0, test_pattern);

  snprintf(path, sizeof(path), "%s/big.ras", dir);
  write_ras(path, 100, 2000, CUPS_CSPACE_W, 8, 203, 0, big_pattern);

  snprintf(path, sizeof(path), "%s/onebit.ras", dir);
  write_ras(path, 100, 50, CUPS_CSPACE_W, 1, 203, 0, onebit_pattern);

  snprintf(path, sizeof(path), "%s/badcolor.ras", dir);
  write_ras(path, 100, 100, CUPS_CSPACE_RGB, 8, 203, 0, test_pattern);

  snprintf(path, sizeof(path), "%s/badspace.ras", dir);
  write_ras(path, 100, 100, CUPS_CSPACE_K, 8, 203, 0, test_pattern);

  /* badbpl.ras = test.ras with cupsBytesPerLine patched to 1 (1 byte
   * cannot cover 100 pixels; the filter must reject the row layout). */
  copy_patch_bpl(dir, "test.ras", "badbpl.ras", 1);
  copy_patch_bpl(dir, "test.ras", "badlargebpl.ras", 4097);

  snprintf(path, sizeof(path), "%s/badres.ras", dir);
  write_ras(path, 100, 100, CUPS_CSPACE_W, 8, 300, 0, test_pattern);

  concat_pages(dir, "test.ras", "badcolor.ras", "multipage_bad.ras");

  /* truncated.ras = test.ras cut to 50 rows */
  snprintf(path, sizeof(path), "%s/test.ras", dir);
  f = fopen(path, "rb");
  if (!f)
  {
    perror("test.ras");
    exit(1);
  }
  fseek(f, 0, SEEK_END);
  size = ftell(f);
  rewind(f);
  buf = malloc(size);
  if (fread(buf, 1, size, f) != (size_t)size)
    exit(1);
  fclose(f);
  snprintf(path, sizeof(path), "%s/truncated.ras", dir);
  f = fopen(path, "wb");
  if (!f || fwrite(buf, 1, size / 2, f) != (size_t)(size / 2))
    exit(1);
  fclose(f);
  free(buf);

  printf("fixtures written to %s\n", dir);
  return 0;
}
