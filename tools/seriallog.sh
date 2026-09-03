#!/bin/sh
# seriallog.sh - timestamped capture of the DUT's serial console.
#
# Runs on the MONITOR, with the FTDI TTL-232RG-VREG1V8-WE on the DUT's X11
# debug UART (Verdin UART3 / ttymxc2, 115200 8N1).
#
# Every line is stamped with the MONITOR's wall clock, which is the same clock
# that timestamps ina228_data rows - so serial events line up directly with
# the power trace. The DUT's own clock stops during suspend and cannot be
# used for this.
#
# Usage: ./seriallog.sh [PORT] [OUTFILE]
#   PORT     default /dev/ttyUSB0
#   OUTFILE  default <repo>/logs/serial-console.log   (appended, never truncated)

PORT="${1:-/dev/ttyUSB0}"
OUT="${2:-$(cd "$(dirname "$0")/.." && pwd)/logs/serial-console.log}"

mkdir -p "$(dirname "$OUT")"

[ -e "$PORT" ] || { echo "seriallog: $PORT not present" >&2; exit 1; }

stty -F "$PORT" 115200 cs8 -cstopb -parenb raw -echo 2>/dev/null || true

printf '\n===== serial capture started %s (port %s) =====\n' \
	"$(date '+%Y-%m-%dT%H:%M:%S%z')" "$PORT" >> "$OUT"

# Line-buffered so the log is useful while the run is still going. The DUT is
# silent for most of a soak, so the per-line `date` call costs nothing.
while IFS= read -r line; do
	printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$line" >> "$OUT"
done < "$PORT"

printf '===== serial capture ended %s (port closed) =====\n' \
	"$(date '+%Y-%m-%dT%H:%M:%S%z')" >> "$OUT"
