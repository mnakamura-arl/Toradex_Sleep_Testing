# 003 — ssh dies when the DUT suspends: detached phase orchestration

**Status:** resolved (2026-08-20, run `20260820-0725`): phases 29/30/32
handled fail-fast aborts correctly with full logs; the crash phases (31/33)
exposed a hung-poll bug (an ssh poll in flight when the DUT dies blocks
forever without keepalives) — fixed same day with ServerAliveInterval on the
poll/fetch calls, plus persistent staging under $HOME (out_33.log survived
the reboot and was the key crash evidence). Deployed to .212.
**Evidence:** run `20260819-2004` phase 3: the board entered deep sleep, the
ssh session died in TCP timeout, and the phase was recorded as FAILED
(exit 255) with a duration of 7.5 min for a 60 s suspend.

## Fix implemented

`tools/pm_run.sh run-detached` stages the command as a script on the DUT,
launches it with nohup (the ssh session ends immediately), then polls every
10 s — treating unreachable-while-asleep as "keep waiting" — and closes the
phase when the DUT writes its exit code file. Phase-end accuracy is ~15 s;
the exact suspend window can still be cut from the 1 Hz samples if needed.

## Retest

```bash
export PM_RUN_ID=$(date +%Y%m%d-%H%M)
./tools/pm_run.sh run-detached torizon@192.168.1.213 suspend-60 \
    'cd sleep_test/scripts && sudo ./02-suspend-cycle.sh -d 60' 600
./tools/pm_run.sh report
```

Pass criteria: phase exit 0, `dur_s` ~60-90 s (not a TCP timeout), full
script output captured in `logs/<RUN_ID>/phase-*-suspend-60.log`, plausible
`true_avg_mw`. Then update RUNBOOK examples were already switched to
run-detached — just record the RUN_ID here and mark resolved.
