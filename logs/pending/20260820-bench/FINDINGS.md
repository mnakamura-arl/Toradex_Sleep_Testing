# Findings — run `20260820-bench` (2026-08-20 bench session)

Re-analysed 2026-08-31 after the phase-39 result was recovered and the
INA228 bus-voltage channel was found dead. Relates to
[todo/006](../../../todo/006-deep-suspend-blockers.md) and
[todo/007](../../../todo/007-ina228-bus-voltage-sense.md).

## What ran

| Phase | Label | Config | Result |
|-------|-------|--------|--------|
| 34 | deep-60-plain | mic plugged, mwifiex loaded | exit 1 — mwifiex `hs_activate` abort at entry |
| 35 | deep-60-nomic | mic unplugged | exit 1 — same mwifiex abort |
| 36 | deep-60-ifdown | `ip link set down` mlan0/uap0 | exit 1 — same; ifdown does not help |
| 37 | deep-60-nomic-rmmod | `-w` (rmmod mwifiex_sdio) | **hang → watchdog reset** |
| 38 | deep-60-freshfw | fresh post-boot, mwifiex loaded, mic out | **exit 0 — clean 60 s deep, 0 s drift** |
| 39 | deep-60x5 | same as 38, `-n 5` | **hang → watchdog reset on cycle 1** |

Phase 39 was left open in the DB when the orchestrator session dropped;
`recover` correctly refused to close it (no `rc_39` on the DUT = it crashed).
Closed by hand 2026-08-31 with `ended_at` = the watchdog reset instant and
exit 125, matching the convention used for phase 37.

## The reboots are watchdog resets

The i.MX2 hardware watchdog is active on the DUT and held open by systemd
(`RuntimeWatchdogUSec=30s`, pinged every ~15 s). The `imx2_wdt` driver's
suspend hook re-arms it to its maximum, `IMX2_WDT_MAX_TIME` = **128 s**,
before the system goes down. So:

- A **successful** suspend resumes well inside 128 s and the watchdog never
  fires — which is why phases 24 and 38 passed cleanly.
- A **hung** suspend is never pinged again, and at ~128 s the watchdog
  resets the board — silently, with no panic and no crash log, which is
  exactly why four reboots left no evidence.

The INA current trace proves it. Both crash phases enter a dead-flat
plateau and then reset almost exactly 128 s later:

| Phase | Enters hung state | Reset / boot rise | Interval |
|-------|-------------------|-------------------|----------|
| 37 | 18:40:30 @ ~195 mA | 18:42:39 | ~129 s |
| 39 | 19:01:14 @ ~207 mA | 19:03:20 | ~126 s |

(1 Hz sampling, so the true entry instant is within a sample of the drop.)

**The watchdog is not the root cause — it is the reason the root cause was
invisible.** The real bug is whatever hangs the suspend path. Note the hung
state draws ~200 mA (~2.4 W): partway down, peripherals gated, but the SoC
never reached deep. A real deep suspend draws ~25 mA.

## Phase 38's "working recipe" is not reliable

Phase 39 ran the identical configuration and command (only `-n 5` added)
eleven minutes later and hung on cycle 1. So the fresh-post-boot pass was
one sample, not a repeatable recipe. The distinguishing factor is that 38
was the *first* deep entry after boot and 39 followed 38's resume —
consistent with the resume path leaving state that wedges the next entry
(cf. the `_regulator_put` refcount WARNs).

## Power numbers here are wrong — see todo/007

The INA228 bus-voltage channel is dead; the real DUT rail is a steady
**11.9 V** (multimeter, 2026-08-31), not the 2.3–5.8 V the sensor logged.
The current channel is healthy. Corrected figures, current x 11.9 V:

| State | Current | True power |
|-------|---------|-----------|
| Awake idle | ~315 mA | **~3.75 W** |
| Deep suspend (phase 38) | ~25 mA | **~300 mW** |
| Hung suspend (37/39) | ~200-207 mA | **~2.4 W** |
| Resume inrush peak | ~424 mA | ~5.0 W |

The "74 mW deep floor" recorded in todo/006 was `25 mA x 2.9 V` of garbage
bus voltage. **The real deep-sleep floor is ~300 mW**, 4x higher.

## Status

Stays in `pending/` — todo/006 is still open (the suspend hang is
unexplained) and todo/007 is new. Phase 21 of run `20260819-2036` is also
still open in `pm_phases`; it was a plain `run` with no recoverable end
time, left as-is.
