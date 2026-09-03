#!/bin/bash
# bench.sh - run one suspend test with LIVE power output. Runs on the MONITOR.
#
# Wraps pm_run.sh run-detached and streams a power reading every few seconds
# while the DUT is asleep, so you can watch the rail drop and come back.
#
# Usage (from ~/sleep_test on the monitor):
#   ./tools/bench.sh [MODE] [DUR_S] [COUNT] [AWAKE_S]
#
#   MODE     deep | s2idle                (default deep)
#   DUR_S    sleep seconds per cycle      (default 60)
#   COUNT    number of cycles             (default 1)
#   AWAKE_S  awake gap between cycles     (default 15, only used when COUNT>1)
#
# Env:
#   PM_DUT       DUT ssh target   (default torizon@192.168.77.213)
#   PM_RUN_ID    run id           (default YYYYmmdd-HHMM)
#   PM_TICK      live readout interval in seconds (default 5)
#
# WARNING: while the systemd watchdog is enabled on the DUT, keep DUR_S well
# under ~100 s. imx2_wdt re-arms the watchdog to its 128 s maximum across
# suspend, so a 120 s sleep leaves only 8 s to resume before it resets.

set -uo pipefail
cd "$(dirname "$0")/.."
[ -f compose.yaml ] || { echo "ERROR: run from the sleep_test root"; exit 1; }

MODE="${1:-deep}"
DUR="${2:-60}"
COUNT="${3:-1}"
AWAKE="${4:-15}"
DUT="${PM_DUT:-torizon@192.168.77.213}"
TICK="${PM_TICK:-5}"
export PM_RUN_ID="${PM_RUN_ID:-$(date +%Y%m%d-%H%M)}"

LABEL="${MODE}-${DUR}"
[ "$COUNT" -gt 1 ] && LABEL="${LABEL}x${COUNT}"
# per cycle: sleep + resume + awake gap, plus slack for boot if it resets
TIMEOUT=$(( (DUR + AWAKE + 45) * COUNT + 90 ))

db() {
    docker compose exec -T postgres psql -tA -F' ' \
        -U "$(cat secrets/db_user.txt)" -d data "$@" 2>/dev/null
}

ssh_dut() { ssh -n -o BatchMode=yes -o ConnectTimeout=5 \
                -o ServerAliveInterval=5 -o ServerAliveCountMax=2 "$DUT" "$@"; }

wait_dut() {
    printf '  waiting for DUT '
    for _ in $(seq 1 72); do
        if ssh_dut true 2>/dev/null; then echo "up"; return 0; fi
        printf '.'; sleep 5
    done
    echo " TIMED OUT"; return 1
}

echo "=================================================================="
echo " run $PM_RUN_ID   phase '$LABEL'   mode=$MODE dur=${DUR}s x$COUNT"
echo " DUT $DUT   phase timeout ${TIMEOUT}s"
echo "=================================================================="

if [ "$DUR" -gt 100 ]; then
    echo "  !! WARNING: DUR=${DUR}s is close to the 128 s watchdog budget."
    echo "  !! A successful sleep may still be reset on the way back up."
fi

wait_dut || exit 1

# Match the known-good config: HDMI bridge unbound (its resume callback
# returns -6 and trips the dmesg gate otherwise).
ssh_dut 'echo 3-0048 | sudo tee /sys/bus/i2c/drivers/lt8912/unbind >/dev/null 2>&1; true'
echo "  DUT boot     : $(ssh_dut 'uptime -s' 2>/dev/null)"
echo "  lt8912 bound : $(ssh_dut 'ls /sys/bus/i2c/drivers/lt8912/ 2>/dev/null | grep -c 0048' 2>/dev/null) (want 0)"
echo "  watchdog     : $(ssh_dut 'cat /sys/class/watchdog/watchdog0/state 2>/dev/null' 2>/dev/null)"
echo "  usb attached : $(ssh_dut 'lsusb 2>/dev/null | grep -vc "root hub"' 2>/dev/null) non-root-hub devices"
echo

./tools/pm_run.sh run-detached "$DUT" "$LABEL" \
    "cd sleep_test/scripts && sudo ./02-suspend-cycle.sh -d $DUR -n $COUNT -m $MODE -k" \
    "$TIMEOUT" &
PMPID=$!

echo "  --- live power (avg over each ${TICK}s window) ---"
while kill -0 "$PMPID" 2>/dev/null; do
    sleep "$TICK"
    line=$(db -c "SELECT to_char(now(),'HH24:MI:SS'),
                         coalesce(round(avg(bus_voltage),2)::text,'-'),
                         coalesce(round(avg(current*1000),1)::text,'-'),
                         coalesce(round(avg(power*1000),0)::text,'-')
                  FROM ina228_data
                  WHERE timestamp > now() - interval '$TICK seconds';")
    [ -n "$line" ] && echo "  $line" | awk '{printf "  %s   %6s V   %7s mA   %7s mW\n",$1,$2,$3,$4}'
done
wait "$PMPID"; rc=$?

echo
echo "  --- DUT state after ---"
echo "  boot: $(ssh_dut 'uptime -s' 2>/dev/null || echo UNREACHABLE)"
echo
echo "=== report for $PM_RUN_ID ==="
./tools/pm_run.sh report
exit "$rc"
