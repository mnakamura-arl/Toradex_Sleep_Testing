# 004 — Script diagnostics: dmesg on abort, can0-as-ethernet, .swp push

**Status:** needs-retest (implemented 2026-08-19)
**Evidence:** run `20260819-2036`: every write-failure printed only the errno
(`Connection timed out`) with no kernel context — the LT8912B culprit was only
visible in the single cycle that resumed. Headers showed `ethernet : can0`
(first_eth picked the CAN interface). Vim `.swp` files were rsynced to the
target mid-debug.

## Fixes implemented

1. `scripts/02-suspend-cycle.sh`: on a failed `/sys/power/state` write, the
   last 40 dmesg lines from the attempt are dumped — the aborting device is
   usually named there.
2. `scripts/pm-common.sh first_eth`: now skips `can*`, `sit*`, `tun*`, `tap*`.
3. `scripts/pm-common.sh dmesg_check_suspend`: honors `PM_DMESG_IGNORE`
   (egrep pattern) so a known-benign PM error doesn't fail a cycle.
4. `tools/pm_run.sh push`: excludes `*.swp` / `*.swo`.

## Retest

`./tools/pm_run.sh push` to the DUT, run `01-probe.sh` (check the ethernet
line), and force one failing suspend if available — confirm the dmesg slice
prints. Record the RUN_ID here and mark resolved.
