#!/bin/sh
# 07-pm-bisect.sh - find WHICH phase of suspend hangs, using /sys/power/pm_test.
#
# /sys/power/pm_test makes the kernel run the suspend sequence only as far as
# a chosen phase, then resume automatically after ~5 s. No RTC alarm is
# involved, so this also separates "fails going down" from "fails waking up".
#
# Levels, shallowest first (kernel Documentation/power/basic-pm-debugging.rst):
#   freezer     freeze userspace tasks only
#   devices     + suspend all device drivers
#   platform    + platform global control methods
#   processors  + disable non-boot CPUs
#   core        + suspend sysdevs / platform low-level, minus actually
#               entering the hardware sleep state
#
# The first level that hangs is where the bug lives. If every level passes,
# the hang is in the final hardware entry itself (SoC/PMIC/firmware), not in
# a driver callback.
#
# Output is written to $PM_LOGDIR (persistent) and synced after every step,
# so the record survives the watchdog reset that a hang will cause.
#
# Usage:
#   sudo ./07-pm-bisect.sh                 # all levels, shallowest first
#   sudo ./07-pm-bisect.sh devices         # just one level
#   sudo ./07-pm-bisect.sh "devices core"  # a chosen subset

. "$(dirname "$0")/pm-common.sh"

need_root

OUT="$PM_LOGDIR/bisect-$(date '+%Y%m%d-%H%M%S').log"
LEVELS="${1:-freezer devices platform processors core}"

AVAIL=$(cat /sys/power/pm_test 2>/dev/null) || die "no /sys/power/pm_test (needs CONFIG_PM_DEBUG)"

# Verbose PM logging: pm_print_times names every device and how long its
# callback took, which is what identifies the offender.
echo 1 > /sys/power/pm_debug_messages 2>/dev/null || true
echo 1 > /sys/power/pm_print_times 2>/dev/null || true

say() { printf '%s\n' "$*" | tee -a "$OUT"; sync; }

say "=== pm_test bisection $(_ts) ==="
say "kernel    : $(uname -r)"
say "available : $AVAIL"
say "mem_sleep : $(mem_sleep_current)"
say "levels    : $LEVELS"
say "log       : $OUT"

for lvl in $LEVELS; do
	say ""
	say "======================== LEVEL: $lvl ========================"
	if ! echo "$lvl" > /sys/power/pm_test 2>/dev/null; then
		say "  !! cannot select '$lvl', skipping"
		continue
	fi
	say "  pm_test now: $(cat /sys/power/pm_test)"

	mark=$(dmesg_mark)
	say "  writing 'mem' (auto-resume ~5 s) ..."
	sync

	t0=$(date +%s)
	if echo mem > /sys/power/state 2>>"$OUT"; then
		t1=$(date +%s)
		say "  ---> RETURNED after $((t1 - t0))s : level '$lvl' PASSED"
	else
		t1=$(date +%s)
		say "  ---> WRITE FAILED after $((t1 - t0))s : level '$lvl' aborted"
	fi

	say "  --- dmesg for this level ---"
	dmesg_since "$mark" | tail -n 80 | sed 's/^/    /' | tee -a "$OUT"
	sync
done

echo none > /sys/power/pm_test 2>/dev/null || true
say ""
say "=== bisection complete - all requested levels returned ==="
say "If every level passed, the hang is in the final hardware entry, not a"
say "driver callback. Re-run 02-suspend-cycle.sh to confirm it still hangs."
say "log: $OUT"
