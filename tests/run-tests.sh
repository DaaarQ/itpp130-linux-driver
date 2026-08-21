#!/bin/bash
#
# SPDX-License-Identifier: GPL-2.0-or-later
#
# run-tests.sh - regression tests for rastertolabel-itpp130.
#
# Requires: the filter binary (built: cc -O2 ... -lcups -lcupsimage),
#           libcups/libcupsimage at runtime, and the shipped PPD.
#
# Usage: ./run-tests.sh [path-to-filter-binary]
#
# The golden files were generated from the reverse-engineered vendor
# behavior and lock in: command framing (SIZE/REFERENCE/DIRECTION/GAP/
# DENSITY/SPEED/SETC/CLS/BITMAP/PRINT), the 201 threshold and polarity,
# option handling, cancellation padding, input validation and error
# propagation.
#
# To regenerate goldens after an intentional behavior change:
#   ./run-tests.sh --regenerate

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
FILTER="${1:-$ROOT/rastertolabel-itpp130}"
export PPD="$ROOT/ITPP130-Label-printer.ppd"
GOLDEN="$HERE/golden"
TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/itpp130-tests.XXXXXX")"
FIX="$TEST_TMP/fixtures"
FIXTURE_BUILDER="$TEST_TMP/make_fixtures"
trap 'rm -rf "$TEST_TMP"' EXIT HUP INT TERM

mkdir -p "$FIX"
if ! "${CC:-cc}" -O2 -Wall -Wextra -Wno-deprecated-declarations \
     -o "$FIXTURE_BUILDER" "$HERE/make_fixtures.c" -lcupsimage; then
  echo "FAIL: could not build raster fixture generator" >&2
  exit 1
fi
if ! "$FIXTURE_BUILDER" "$FIX" >/dev/null; then
  echo "FAIL: could not generate raster fixtures" >&2
  exit 1
fi

if [ "${1:-}" = "--regenerate" ]; then
  shift
  FILTER="${1:-$ROOT/rastertolabel-itpp130}"
  echo "==> regenerating goldens"
  "$FILTER" 1 test-user t 1 "PageSize=w283h425" "$FIX/test.ras" 2>/dev/null \
    > "$GOLDEN/default.tspl"
  "$FILTER" 1 test-user t 1 "PageSize=w283h425 Darkness=12 zePrintRate=2 \
AdjustVertical=3 AdjustHoriaontal=-2 zeMediaTracking=Continuous Rotate=1" \
    "$FIX/test.ras" 2>/dev/null > "$GOLDEN/options.tspl"
  echo "done"
  exit 0
fi

pass=0
fail=0

check()
{
  local name="$1"
  if [ "$2" = "0" ]; then
    echo "PASS: $name"
    pass=$((pass + 1))
  else
    echo "FAIL: $name"
    fail=$((fail + 1))
  fi
}

# --- 1. default options vs golden -------------------------------------
diff <("$FILTER" 1 test-user t 1 "PageSize=w283h425" "$FIX/test.ras" 2>/dev/null) \
     "$GOLDEN/default.tspl" >/dev/null 2>&1
check "default output matches golden" $?

# --- 2. options vs golden ---------------------------------------------
diff <("$FILTER" 1 test-user t 1 "PageSize=w283h425 Darkness=12 zePrintRate=2 \
AdjustVertical=3 AdjustHoriaontal=-2 zeMediaTracking=Continuous Rotate=1" \
       "$FIX/test.ras" 2>/dev/null) "$GOLDEN/options.tspl" >/dev/null 2>&1
check "option output matches golden" $?

# --- 3. bitmap data polarity & threshold (rows of test.ras) -----------
"$FILTER" 1 test-user t 1 "PageSize=w283h425" "$FIX/test.ras" 2>/dev/null |
python3 -c '
import sys, re
d = sys.stdin.buffer.read()
m = re.search(rb"BITMAP ([0-9]+),([0-9]+),([0-9]+),([0-9]+),([0-9]+),", d)
assert m, "no BITMAP"
wb = int(m.group(3)); h = int(m.group(4))
start = m.end()
rows = d[start:start+wb*h]
assert len(rows) == wb*h, f"bitmap length {len(rows)} != {wb*h}"
def bits(r): return "".join(f"{b:08b}" for b in rows[r*wb:(r+1)*wb])[:100]
assert bits(5)  == "0"*100,  "row 5 (black) not black"
assert bits(15) == "1"*100,  "row 15 (white) not white"
assert bits(25) == "0"*100,  "row 25 (gray 190) should print black (< 201)"
assert bits(35) == "0"*100,  "row 35 (gray 200) should print black (< 201)"
assert bits(45) == "1"*100,  "row 45 (gray 201) should stay white (>= 201)"
assert bits(55) == "1"*100,  "row 55 (gray 210) should stay white (>= 201)"
assert bits(65) == "0"*100,  "row 65 (gray 128) should print black (< 201)"
assert bits(75) == "0000000011111111"*6 + "0000", "row 75 bars wrong"
# and the 4 remaining bits of the last byte must be white padding
full = "".join(f"{b:08b}" for b in rows[75*wb:(76)*wb])
assert full[100:] == "1111", f"row 75 padding bits wrong: {full[100:]}"
assert d[start+wb*h:start+wb*h+13] == b"\nPRINT 1,1\r\n", "bad trailer"
print("ok")
'
check "threshold/polarity/framing" $?

# --- 4. 1-bit path: verbatim bytes + tail padding ---------------------
"$FILTER" 1 test-user t 1 "PageSize=w283h425" "$FIX/onebit.ras" 2>/dev/null |
python3 -c '
import sys, re
d = sys.stdin.buffer.read()
m = re.search(rb"BITMAP ([0-9]+),([0-9]+),([0-9]+),([0-9]+),([0-9]+),", d)
assert m, "no BITMAP"
wb = int(m.group(3)); h = int(m.group(4))
start = m.end()
rows = d[start:start+wb*h]
assert len(rows) == wb*h, "1-bit bitmap length mismatch"
def bits(r): return "".join(f"{b:08b}" for b in rows[r*wb:(r+1)*wb])[:100]
assert bits(5) == "0"*100,  "1-bit row 5 (black) not black"
assert bits(35) == "1"*100, "1-bit row 35 (white) not white"
for r in (5, 35):
    full = "".join(f"{b:08b}" for b in rows[r*wb:(r+1)*wb])
    assert full[100:] == "1111", f"1-bit row {r} padding is not white: {full[100:]}"
print("ok")
'
check "1-bit polarity and framing" $?

# --- 5. header validation (each bad header must be rejected) ----------
for fx in badcolor.ras badspace.ras badbpl.ras badlargebpl.ras badres.ras; do
  case "$fx" in
    badcolor.ras|badspace.ras) expected="Unsupported raster colorspace" ;;
    # CUPS on Linux rejects this internally before returning the header;
    # libcupsimage on macOS returns it to the filter for our own check.
    badbpl.ras)                expected="cupsBytesPerLine|No pages were found" ;;
    badlargebpl.ras)           expected="safe row limit|No pages were found" ;;
    badres.ras)                expected="Unsupported resolution" ;;
  esac
  if [ ! -f "$FIX/$fx" ]; then
    check "fixture exists: $fx" 1
    continue
  fi
  err=$("$FILTER" 1 test-user t 1 "PageSize=w283h425" "$FIX/$fx" 2>&1 >/dev/null)
  rc=$?
  if [ $rc -ne 0 ] && echo "$err" | grep -Eq "$expected"; then
    check "reject $fx" 0
  else
    check "reject $fx (rc=$rc err=$err)" 1
  fi
done

# --- 6. bad second page must fail the whole job -----------------------
"$FILTER" 1 test-user t 1 "PageSize=w283h425" "$FIX/multipage_bad.ras" \
  > "$TEST_TMP/multipage.tspl" 2> "$TEST_TMP/multipage.err"
rc=$?
if [ $rc -ne 0 ] && grep -q "Unsupported raster colorspace" \
     "$TEST_TMP/multipage.err" && \
   [ "$(grep -a -c 'PRINT 1,1' "$TEST_TMP/multipage.tspl")" -eq 1 ]; then
  check "bad second page fails whole job" 0
else
  check "bad second page fails whole job (rc=$rc)" 1
fi

# --- 7. requested copies are sent to TSPL -----------------------------
"$FILTER" 1 test-user t 3 "PageSize=w283h425" "$FIX/test.ras" \
  > "$TEST_TMP/copies.tspl" 2>/dev/null
rc=$?
if [ $rc -eq 0 ] && \
   [ "$(grep -a -c 'PRINT 1,3' "$TEST_TMP/copies.tspl")" -eq 1 ]; then
  check "copy count is honored" 0
else
  check "copy count is honored (rc=$rc)" 1
fi

# Piped raster data has already had copies expanded by pdftopdf.  It must
# never apply argv[4] again or PDF jobs would print copies squared.
"$FILTER" 1 test-user t 3 "PageSize=w283h425" \
  < "$FIX/test.ras" > "$TEST_TMP/piped-copies.tspl" 2>/dev/null
rc=$?
if [ $rc -eq 0 ] && \
   [ "$(grep -a -c 'PRINT 1,1' "$TEST_TMP/piped-copies.tspl")" -eq 1 ]; then
  check "piped input does not duplicate upstream copies" 0
else
  check "piped input does not duplicate upstream copies (rc=$rc)" 1
fi

# --- 8. truncated input: padded + clean termination + rc=1 ------------
"$FILTER" 1 test-user t 1 "PageSize=w283h425" "$FIX/truncated.ras" \
  > "$TEST_TMP/truncated.tspl" 2>/dev/null
rc=$?
ok=1
TRUNCATED_TSPL="$TEST_TMP/truncated.tspl" python3 -c '
import os
import re
d = open(os.environ["TRUNCATED_TSPL"], "rb").read()
m = re.search(rb"BITMAP ([0-9]+),([0-9]+),([0-9]+),([0-9]+),([0-9]+),", d)
assert m, "no BITMAP"
wb = int(m.group(3)); h = int(m.group(4))
start = m.end()
payload = d[start:start+wb*h]
assert len(payload) == wb*h, f"payload {len(payload)} != {wb*h}"
assert d[start+wb*h:start+wb*h+13] == b"\nPRINT 1,1\r\n", "bad trailer"
print("ok")
' || ok=0
if [ $rc -ne 0 ] && [ $ok -eq 1 ]; then
  check "truncated input errors but stays in sync" 0
else
  check "truncated input errors but stays in sync (rc=$rc ok=$ok)" 1
fi

# --- 9. cancellation must pad the bitmap and stay in sync ------------
# Feed the raster through a fifo so the filter is guaranteed to be
# mid-read when SIGTERM arrives (a fast local file would finish before
# the kill).
CANCEL_FIFO="$TEST_TMP/cancel-fifo"
CANCEL_TSPL="$TEST_TMP/cancel.tspl"
mkfifo "$CANCEL_FIFO"
"$FILTER" 1 test-user t 1 "PageSize=w283h425" < "$CANCEL_FIFO" \
  > "$CANCEL_TSPL" 2> "$TEST_TMP/cancel.err" &
pid=$!
{
  # Keep one writer descriptor open throughout.  Closing and reopening the
  # FIFO between head and sleep creates a race where the reader observes
  # EOF and reports truncation before SIGTERM is delivered.
  exec 3> "$CANCEL_FIFO"
  head -c 40000 "$FIX/big.ras" >&3
  sleep 2
  exec 3>&-
} > /dev/null 2>&1 &
writer=$!
sleep 0.3
kill -TERM $pid 2>/dev/null
wait $pid 2>/dev/null
cancel_rc=$?
kill $writer 2>/dev/null
rm -f "$CANCEL_FIFO"
ok=1
ITPP130_CANCEL_TSPL="$CANCEL_TSPL" python3 -c '
import os
import re
d = open(os.environ["ITPP130_CANCEL_TSPL"], "rb").read()
ms = list(re.finditer(rb"BITMAP ([0-9]+),([0-9]+),([0-9]+),([0-9]+),([0-9]+),", d))
assert len(ms) == 1, f"{len(ms)} BITMAP commands"
m = ms[0]
wb = int(m.group(3)); h = int(m.group(4))
start = m.end()
payload = d[start:start+wb*h]
assert len(payload) == wb*h, f"payload {len(payload)} != {wb*h}"
assert d[start+wb*h:start+wb*h+13] == b"\nPRINT 1,1\r\n", "unterminated after cancel"
print("ok")
' || ok=0
if [ $cancel_rc -ne 0 ] && [ $ok -eq 1 ] && \
   grep -q "Job cancelled" "$TEST_TMP/cancel.err"; then
  check "cancel pads bitmap and terminates cleanly" 0
else
  check "cancel pads bitmap and terminates cleanly (rc=$cancel_rc)" 1
fi

echo
echo "$pass passed, $fail failed"
[ $fail -eq 0 ]
