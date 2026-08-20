/*
 * SPDX-License-Identifier: GPL-2.0-or-later
 *
 * rastertolabel-itpp130
 * ---------------------
 * CUPS raster -> TSPL filter for the Munbyn ITPP130 / ITPP130B 4x6" thermal
 * label printer (203 dpi, 100 mm wide).
 *
 * This filter is a clean-room Linux reimplementation of behavior observed
 * in the vendor macOS "rastertolabel" filter (ITPP130 Mac Driver v1.5.8.1).
 * The vendor filter selects its output language from *cupsModelNumber:
 *
 *     16 -> PCL, 17 -> ESC/POS-style, 18 -> ZPL, 19 -> CPCL, 20 -> TSPL
 *
 * The ITPP130 PPD ships with *cupsModelNumber: 20, so the printer speaks
 * TSPL (confirmed independently by the Windows driver's Munbyn_ITPP130.DDD
 * data file, which is labelled "TSPL").
 *
 * The job stream produced per page (exactly as reverse engineered from the
 * vendor binary):
 *
 *   <1024 x 0x00 wake burst>
 *   SIZE <w> mm,<h> mm        (media size in mm, 8 dots/mm @ 203 dpi)
 *   REFERENCE <x>,<y>         (AdjustHoriaontal / AdjustVertical x 8 dots/mm)
 *   DIRECTION <n>,0           (Rotate: 0,1,2,3)
 *   GAP/BLINE <h> mm,<o> mm   (zeMediaTracking: Continuous/Gap/BLine)
 *   DENSITY <n>               (Darkness 0-15, omitted when "Default")
 *   SPEED <n>                 (zePrintRate 1-8, 1 clamped to 2)
 *   SETC AUTODOTTED ON/OFF    (AutoDotted)
 *   SETC PAUSEKEY ON
 *   SETC WATERMARK OFF
 *   CLS
 *   BITMAP 0,0,<wb>,<h>,1,<raw 1-bit bitmap, wb = (width+7)/8 bytes/row>
 *   <single newline>
 *   PRINT 1,<copies>
 *
 * Raster conversion (replicating the vendor's per-row loop):
 *   The pipeline raster (CUPS_CSPACE_W declared, values written by
 *   cups-filters pdftoraster/imagetoraster) stores dark pixels with low
 *   byte values (text = 0x00, background = 0xFF).  The vendor filter
 *   keeps a bit set only when the source pixel >= 201, so pixels below
 *   ~79% brightness print black; bits are packed MSB-first and the final
 *   byte of each row is padded with white.  TSPL BITMAP data uses 0 for
 *   black dots (verified against cups-filters pdftotspl output).
 *
 * Build:
 *   cc -O2 -o rastertolabel-itpp130 rastertolabel-itpp130.c -lcups -lcupsimage
 *
 * Install:
 *   install -m 755 rastertolabel-itpp130 /usr/lib/cups/filter/
 *   (PPD: /usr/share/cups/model/munbyn/ITPP130-Label-printer.ppd)
 */

#include <cups/cups.h>
#include <cups/ppd.h>
#include <cups/raster.h>

#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define TSPL_MODEL 20          /* *cupsModelNumber of the ITPP130 PPD */

#define WAKE_BURST 1024        /* leading zero bytes sent at each page start */
#define THRESHOLD  201         /* 8bpp pixels >= this stay white */

static volatile sig_atomic_t Canceled = 0;

static int ModelNumber = 0;    /* from PPD *cupsModelNumber */

/* ------------------------------------------------------------------ */
/* Cancel handler (SIGTERM)                                            */
/* ------------------------------------------------------------------ */

static void
CancelJob(int sig)
{
  (void)sig;
  Canceled = 1;
}

/* ------------------------------------------------------------------ */
/* Output one raster scanline as TSPL BITMAP data (vendor _OutputLine  */
/* model-20 path).                                                     */
/*                                                                     */
/* buf: one row of cupsBytesPerLine bytes; cupsWidth pixels are valid. */
/*                                                                     */
/* Polarity (reverse engineered from the vendor binary and verified    */
/* against the known-good cups-filters pdftotspl output on this        */
/* printer): the raster pipeline writes dark pixels with LOW byte      */
/* values (text = 0x00, background = 0xFF), and TSPL BITMAP data uses  */
/* 0 = black.  The vendor emits output bit 1 when the source pixel is  */
/* >= THRESHOLD, i.e. only very bright pixels stay white:              */
/*                                                                     */
/*     out bit = (src >= THRESHOLD) ? 1 (white) : 0 (black)            */
/*                                                                     */
/* The 1-bit path uses the same polarity model: cups-filters renders   */
/* 1-bit rasters with bit 1 = white (onebitpixel: value > threshold    */
/* sets the bit, and background values are 0xFF), so bytes are         */
/* emitted verbatim.                                                   */
/* ------------------------------------------------------------------ */

static void
OutputLine(const unsigned char *buf, unsigned cupsWidth,
           unsigned bitsPerPixel)
{
  unsigned wb = (cupsWidth + 7) / 8;   /* bytes per bitmap row */
  unsigned j;

  /* main() validates width and allocates the row before calling us.  Keep
   * the helper defensive as well, both for future callers and analyzers. */
  if (buf == NULL || cupsWidth == 0)
    return;

  if (bitsPerPixel == 1)
  {
    /* 1-bit raster: bit 7 = leftmost pixel, 1 = white (same polarity
     * model as the 8-bit path below).  TSPL consumes whole bytes, so
     * force any unused low bits in the last byte to white rather than
     * allowing raster padding to create stray black dots. */
    if ((cupsWidth & 7) == 0)
    {
      fwrite(buf, 1, wb, stdout);
    }
    else
    {
      unsigned pad = 8 - (cupsWidth & 7);
      unsigned char last = (unsigned char)(buf[wb - 1] |
                                           ((1U << pad) - 1U));

      if (wb > 1)
        fwrite(buf, 1, wb - 1, stdout);
      putchar((int)last);
    }
    return;
  }

  for (j = 0; j < wb; j++)
  {
    unsigned acc = 0;
    int i;

    for (i = 0; i < 8; i++)
    {
      unsigned idx = j * 8 + (unsigned)i;

      if (idx >= cupsWidth)
      {
        acc |= (0x80U >> (unsigned)i); /* pad remainder with white */
        continue;
      }

      if (buf[idx] >= THRESHOLD)  /* bright pixel -> white bit (1) */
        acc |= (0x80U >> (unsigned)i);
    }
    putchar((int)acc);
  }
}

/* ------------------------------------------------------------------ */
/* Per-page prologue (vendor _StartPage model-20 path)                 */
/* ------------------------------------------------------------------ */

static void
StartPage(ppd_file_t *ppd, const cups_page_header2_t *h)
{
  static const unsigned char zeros[WAKE_BURST] = { 0 };
  ppd_choice_t *c;
  int adjH = 0, adjV = 0, dir = 0;

  /* Wake burst: the vendor emits 1024 NUL bytes before the first command */
  fwrite(zeros, 1, sizeof(zeros), stdout);

  /* SIZE <w> mm,<h> mm -- 203 dpi = 8 dots/mm, rounded up like the vendor.
   * Note: (n+7)/8 does double duty here and in the BITMAP width below
   * because 8 dots/mm (203 dpi) and 8 bits/byte coincide; the printer
   * measures the label with its gap sensor, so the integer-mm rounding
   * (<=0.5mm) does not affect registration. */
  printf("SIZE %u mm,%u mm\r\n",
         (h->cupsWidth + 7) / 8, (h->cupsHeight + 7) / 8);

  /* REFERENCE -- horizontal/vertical offset in dots (mm * 8) */
  if ((c = ppdFindMarkedChoice(ppd, "AdjustHoriaontal")) != NULL)
    adjH = atoi(c->choice) * 8;
  if ((c = ppdFindMarkedChoice(ppd, "AdjustVertical")) != NULL)
    adjV = atoi(c->choice) * 8;
  printf("REFERENCE %d,%d\r\n", adjH, adjV);

  /* DIRECTION -- rotate (0/180/90/270 -> 0..3, passed through) */
  if ((c = ppdFindMarkedChoice(ppd, "Rotate")) != NULL)
    dir = atoi(c->choice);
  printf("DIRECTION %d,0\r\n", dir);

  /* Media tracking: Continuous -> GAP 0, Gap -> GAP h,o, BLine -> BLINE h,o */
  if ((c = ppdFindMarkedChoice(ppd, "zeMediaTracking")) != NULL)
  {
    if (strcmp(c->choice, "Continuous") == 0)
    {
      fputs("GAP 0 mm,0 mm\r\n", stdout);
    }
    else
    {
      ppd_choice_t *gh = ppdFindMarkedChoice(ppd, "GapOrMarkHeight");
      ppd_choice_t *go = ppdFindMarkedChoice(ppd, "GapOrMarkOffset");
      int hmm = gh ? atoi(gh->choice) : 3;
      int off = go ? atoi(go->choice) : 0;

      if (strcmp(c->choice, "Gap") == 0)
        printf("GAP %d mm,%d mm\r\n", hmm, off);
      else
        printf("BLINE %d mm,%d mm\r\n", hmm, off);
    }
  }

  /* DENSITY -- darkness 0..15; "Default" sends nothing */
  if ((c = ppdFindMarkedChoice(ppd, "Darkness")) != NULL &&
      strcmp(c->choice, "Default") != 0)
    printf("DENSITY %d\r\n", atoi(c->choice));

  /* SPEED -- 1..8 ips; vendor clamps 1 -> 2 (printer minimum) */
  if ((c = ppdFindMarkedChoice(ppd, "zePrintRate")) != NULL &&
      strcmp(c->choice, "Default") != 0)
  {
    int sp = atoi(c->choice);

    if (sp == 1)
      sp = 2;
    printf("SPEED %d\r\n", sp);
  }

  /* AutoDotted (anti-blur line feature) */
  if ((c = ppdFindMarkedChoice(ppd, "AutoDotted")) != NULL && atoi(c->choice))
    fputs("SETC AUTODOTTED ON\r\n", stdout);
  else
    fputs("SETC AUTODOTTED OFF\r\n", stdout);

  fputs("SETC PAUSEKEY ON\r\n", stdout);
  fputs("SETC WATERMARK OFF\r\n", stdout);

  /* Clear the label buffer, then start the bitmap */
  fputs("CLS\r\n", stdout);
  printf("BITMAP 0,0,%u,%u,1,", (h->cupsWidth + 7) / 8, h->cupsHeight);
}

/* ------------------------------------------------------------------ */
/* Per-page epilogue (vendor _EndPage model-20 path, extended to honor */
/* the CUPS copy-count argument).                                      */
/* ------------------------------------------------------------------ */

static void
EndPage(unsigned copies)
{
  printf("PRINT 1,%u\r\n", copies);
  fflush(stdout);
}

/* ------------------------------------------------------------------ */
/* main                                                                */
/* ------------------------------------------------------------------ */

int
main(int argc, char *argv[])
{
  int fd = 0;
  cups_raster_t *ras = NULL;
  cups_page_header2_t h;
  ppd_file_t *ppd = NULL;
  cups_option_t *options = NULL;
  int num_options = 0;
  int pages = 0;
  int pages_error = 0;
  int ret = 1;
  unsigned copies = 1;
  int ppd_line = 0;
  unsigned char *rowbuf = NULL;
  size_t rowbuf_size = 0;

  setbuf(stderr, NULL);

  if (argc != 6 && argc != 7)
  {
    fputs("ERROR: rastertolabel-itpp130 job-id user title copies options "
          "[file]\n", stderr);
    return 1;
  }

  {
    char *end = NULL;
    unsigned long requested = strtoul(argv[4], &end, 10);

    if (argv[4][0] == '\0' || end == NULL || *end != '\0' ||
        requested == 0 || requested > 9999)
    {
      fprintf(stderr, "ERROR: Invalid copy count '%s' (expected 1..9999).\n",
              argv[4]);
      return 1;
    }
    /* The first file-reading filter is responsible for copies.  For piped
     * raster input, an earlier pdftopdf stage has already expanded them;
     * applying argv[4] again here would multiply the requested count. */
    if (argc == 7)
      copies = (unsigned)requested;
  }

  if (argc == 7)
  {
    fd = open(argv[6], O_RDONLY);
    if (fd < 0)
    {
      fputs("ERROR: Unable to open raster file\n", stderr);
      sleep(1);
      return 1;
    }
  }

  num_options = cupsParseOptions(argv[5], 0, &options);

  ppd = ppdOpenFile(getenv("PPD"));
  if (ppd == NULL)
  {
    fputs("ERROR: The PPD file could not be opened.\n", stderr);
    ppd_status_t status = ppdLastError(&ppd_line);
    fprintf(stderr, "DEBUG: %s on line %d.\n", ppdErrorString(status),
            ppd_line);
    goto done;
  }

  ppdMarkDefaults(ppd);
  cupsMarkOptions(ppd, num_options, options);

  ModelNumber = ppd->model_number;
  if (ModelNumber != TSPL_MODEL)
  {
    fprintf(stderr,
            "ERROR: rastertolabel-itpp130 supports cupsModelNumber %d only "
            "(PPD has %d).\n", TSPL_MODEL, ModelNumber);
    goto done;
  }

  Canceled = 0;
  {
    struct sigaction sa;

    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = CancelJob;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;              /* no SA_RESTART: interrupt blocked reads
                                   * so cancellation is prompt */
    sigaction(SIGTERM, &sa, NULL);
  }

  ras = cupsRasterOpen(fd, CUPS_RASTER_READ);
  if (ras == NULL)
  {
    fputs("ERROR: Unable to open raster stream\n", stderr);
    sleep(1);
    goto done;
  }

  while (cupsRasterReadHeader2(ras, &h))
  {
    unsigned row;
    unsigned emitted = 0;

    if (Canceled)
      break;

    /* Validate the raster format and row layout up front.  The raster
     * header is attacker-controllable for raw raster jobs, so every
     * inconsistency must fail loudly instead of misprinting or
     * overrunning the row buffer.  Supported: 203 dpi, CUPS_CSPACE_W,
     * chunky, one color, 1 or 8 bits per pixel, with a bytes-per-line
     * that actually covers the declared width. */
    if (h.cupsColorSpace != CUPS_CSPACE_W)
    {
      fprintf(stderr, "ERROR: Unsupported raster colorspace %d "
              "(this driver accepts CUPS_CSPACE_W only).\n",
              h.cupsColorSpace);
      pages_error = 1;
      break;
    }
    if (h.cupsBitsPerColor != 8 && h.cupsBitsPerColor != 1)
    {
      fprintf(stderr, "ERROR: Unsupported raster depth %u bits per color "
              "(expected 1 or 8).\n", h.cupsBitsPerColor);
      pages_error = 1;
      break;
    }
    if (h.cupsBitsPerPixel != h.cupsBitsPerColor)
    {
      fprintf(stderr, "ERROR: Inconsistent raster depth "
              "(cupsBitsPerColor=%u, cupsBitsPerPixel=%u).\n",
              h.cupsBitsPerColor, h.cupsBitsPerPixel);
      pages_error = 1;
      break;
    }
    if (h.cupsColorOrder != CUPS_ORDER_CHUNKED)
    {
      fprintf(stderr, "ERROR: Unsupported raster color order %d "
              "(expected CUPS_ORDER_CHUNKED).\n", h.cupsColorOrder);
      pages_error = 1;
      break;
    }
    if (h.cupsNumColors != 1)
    {
      fprintf(stderr, "ERROR: Unsupported color count %u (expected 1).\n",
              h.cupsNumColors);
      pages_error = 1;
      break;
    }
    if (h.HWResolution[0] != 203 || h.HWResolution[1] != 203)
    {
      fprintf(stderr, "ERROR: Unsupported resolution %u x %u dpi "
              "(expected 203 x 203).\n", h.HWResolution[0],
              h.HWResolution[1]);
      pages_error = 1;
      break;
    }
    /* Printer limits from the PPD: MaxMediaWidth 294pt / MaxMediaHeight
     * 5670pt at 203 dpi, with rounding slack. */
    if (h.cupsWidth == 0 || h.cupsWidth > 832 ||
        h.cupsHeight == 0 || h.cupsHeight > 16000)
    {
      fprintf(stderr, "ERROR: Raster dimensions %u x %u outside the "
              "supported range (1..832 x 1..16000 dots).\n",
              h.cupsWidth, h.cupsHeight);
      pages_error = 1;
      break;
    }
    {
      unsigned min_bpl = (h.cupsBitsPerColor == 1)
                           ? (h.cupsWidth + 7) / 8 : h.cupsWidth;

      if (h.cupsBytesPerLine < min_bpl)
      {
        fprintf(stderr, "ERROR: cupsBytesPerLine %u is smaller than the "
                "declared width requires (%u).\n",
                h.cupsBytesPerLine, min_bpl);
        pages_error = 1;
        break;
      }
      if (h.cupsBytesPerLine > 4096)
      {
        fprintf(stderr, "ERROR: cupsBytesPerLine %u exceeds the safe row "
                "limit (4096).\n", h.cupsBytesPerLine);
        pages_error = 1;
        break;
      }
    }

    pages++;
    fprintf(stderr, "PAGE: %d 1\n", pages);
    fprintf(stderr, "INFO: Starting page %d.\n", pages);

    StartPage(ppd, &h);

    int page_ok = 1;

    for (row = 0; row < h.cupsHeight; row++)
    {
      if (Canceled)
      {
        fprintf(stderr, "INFO: Job cancelled during page %d; the bitmap "
                "is being padded so the printer stays in sync.\n", pages);
        page_ok = 0;
        break;
      }

      if (h.cupsBytesPerLine > rowbuf_size)
      {
        unsigned char *nl = realloc(rowbuf, h.cupsBytesPerLine);

        if (nl == NULL)
        {
          fputs("ERROR: Out of memory.\n", stderr);
          page_ok = 0;
          break;
        }
        rowbuf = nl;
        rowbuf_size = h.cupsBytesPerLine;
      }

      /* cupsRasterReadPixels returns the number of bytes read; a short
       * row means the input was truncated (or the read was interrupted
       * by SIGTERM) and the tail of the buffer is stale.  Treat
       * anything but a full row as a page error. */
      if (cupsRasterReadPixels(ras, rowbuf, h.cupsBytesPerLine) !=
          h.cupsBytesPerLine)
      {
        if (Canceled)
          fprintf(stderr, "INFO: Job cancelled during page %d; the bitmap "
                  "is being padded so the printer stays in sync.\n", pages);
        else
          fprintf(stderr, "ERROR: Truncated raster input at row %u.\n", row);
        page_ok = 0;
        break;
      }

      if ((row & 15) == 0)
      {
        unsigned pct = row * 100 / h.cupsHeight;

        fprintf(stderr, "INFO: Printing page %d, %u%% complete.\n",
                pages, pct);
        fprintf(stderr, "ATTR: job-media-progress=%u\n", pct);
      }

      OutputLine(rowbuf, h.cupsWidth, h.cupsBitsPerPixel);
      emitted++;

      if (ferror(stdout))
      {
        fprintf(stderr, "ERROR: Output error (printer backend closed?); "
                "aborting job.\n");
        page_ok = 0;
        break;
      }
    }

    /* BITMAP declared wb*cupsHeight bytes of pixel data.  If the row
     * loop ended early (job cancelled, truncated input, output error),
     * the printer firmware is still counting bitmap bytes: it would
     * swallow the following newline/PRINT as bitmap data and then block
     * waiting for the rest, hanging the queue.  Pad the remainder with
     * 0xFF (white) so the byte count is satisfied and the page
     * terminates cleanly. */
    while (emitted < h.cupsHeight)
    {
      static unsigned char white[4096];
      static int white_inited = 0;
      unsigned wb = (h.cupsWidth + 7) / 8;

      if (!white_inited)
      {
        memset(white, 0xFF, sizeof(white));
        white_inited = 1;
      }
      while (wb > 0)
      {
        size_t n = wb > sizeof(white) ? sizeof(white) : wb;

        fwrite(white, 1, n, stdout);
        wb -= (unsigned)n;
      }
      emitted++;
    }

    putchar('\n');               /* vendor emits a newline after the bitmap */
    fprintf(stderr, "INFO: Finished page %d.\n", pages);
    EndPage(copies);

    if (!page_ok)
      pages_error = 1;
  }

  ret = (pages > 0 && !pages_error) ? 0 : 1;
  if (pages == 0)
    fputs("ERROR: No pages were found.\n", stderr);
  else if (pages_error)
    fputs("ERROR: One or more pages were incomplete.\n", stderr);

done:
  if (ras != NULL)
    cupsRasterClose(ras);
  if (fd > 0)
    close(fd);
  if (ppd != NULL)
    ppdClose(ppd);
  if (options != NULL)
    cupsFreeOptions(num_options, options);
  free(rowbuf);
  return ret;
}
