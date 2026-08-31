# 007 — INA228 bus voltage read garbage: monitor and DUT had isolated grounds

**Status:** resolved (2026-08-31)
**Found and fixed:** 2026-08-31, on restarting the project.

## Symptom

The INA228's `bus_voltage` never matched reality. A multimeter showed a
steady **11.9 V** on the DUT's supply rail; the sensor reported values that
wandered randomly second-to-second and drifted downward over weeks:

| Period | reported bus_voltage | range | current (avg) |
|--------|---------------------|-------|---------------|
| 2026-08-21/22 | 3.9 V | 2.2 – 6.0 V | ~332 mA |
| 2026-08-27 | 1.41 V | 0.02 – 1.94 V | ~385 mA |
| 2026-08-31 (before fix) | 0.96 V | 0.67 – 1.20 V | ~342 mA |

The current channel was healthy and stable the whole time.

## Root cause

**The monitor (.212) and the DUT (.213) ran from separate 12 V supplies with
no bond between their grounds.**

The INA228 breakout straddles the two domains:

| Breakout side | Referenced to |
|---------------|---------------|
| `VIN`, `GND`, `SCL`, `SDA` (logic) | the **monitor's** ground |
| `VIN+`, `VIN−`, `VBUS` (measurement) | the **DUT supply's** ground |

Shunt current is a **differential** measurement (`VIN+` − `VIN−`), so it is
immune to what the chip calls ground — which is why current was always
correct. Bus voltage is **single-ended**, measured against the chip's `GND`
pin. With the two ground systems isolated, the entire 12 V domain floated
relative to the chip's reference and `VBUS` reported nothing but the
arbitrary leakage-set offset between them.

The giveaway: `VBUS` was jumpered to `VIN+` (the solder jumper on the back of
the Adafruit breakout was closed, correct for high-side), and `VIN+` is a
solid low-impedance node carrying ~340 mA. Such a node cannot wander ±0.2 V
sample-to-sample. The only floating thing in the loop was the *reference*.

Note the shunt wiring itself was correct high-side all along, per Adafruit's
own high-side guidance (`VIN+` and `VBUS` to the supply positive, `VIN−` to
the load's highest potential, grounds common). The missing piece was the last
clause: **grounds common**.

## Fix

Rewired so the monitor and DUT share one 12 V supply, bonding their grounds.
The monitor taps +12 V **upstream of the shunt** (same node as `VIN+`), so
its own consumption bypasses the shunt and only the DUT's current is
measured.

Verified immediately after (2026-08-31 19:34):

```
bus_v:  11.696 11.705 11.708 11.711 11.713 11.715 11.719 11.726   (+/-15 mV)
ma:     316-374, avg ~325                                          (unchanged)
power:  ~3.8 W awake idle
```

Two checks confirm it:

1. Bus voltage is steady to ±0.13% instead of wandering ±20%.
2. **Current is unchanged** by the rewire (~325 mA vs ~342 mA before), which
   proves the monitor is not drawing through the shunt. Had it been tapped
   downstream of the shunt, the reading would have roughly doubled and
   swamped the DUT's ~25 mA deep-sleep floor.

The INA reads 11.71 V where the multimeter read 11.9 V at the supply
terminals. That 0.19 V is IR drop in the supply leads under the now-higher
combined load — the INA228's own accuracy is ~0.05%, far tighter than the
1.6% gap. The INA's figure is the more useful one: it is the voltage actually
delivered at the sense point.

## Consequences for the historical data

Every voltage, power, and energy figure recorded before 2026-08-31 is
invalid, including `true_avg_mw` — the chip computes power as
`bus_voltage x current` and integrates that same product into its energy
accumulator, so both columns inherited the bad reference.

**The current column is sound throughout**, so past runs are recoverable:
multiply current by the real rail voltage. Corrected headline figures:

| State | Current | Recorded (bogus) | True |
|-------|---------|------------------|------|
| Awake idle | ~320 mA | ~1.5 W | **~3.8 W** |
| Deep suspend | ~25 mA | 74 mW | **~295 mW** |
| Hung suspend | ~205 mA | ~0.8 W | **~2.4 W** |
| Resume inrush peak | ~424 mA | — | **~5.0 W** |

The deep-sleep floor is ~295 mW, not the 74 mW recorded in todo/006 as a
breakthrough — about 4x higher, and much closer to the ~150 mW that
`scripts/03-poweroff-wake.sh` cites when arguing for wake-from-poweroff
instead of suspend-to-RAM.

The watchdog analysis in [todo/006](006-deep-suspend-blockers.md) rests
entirely on the current channel and is unaffected.

## Follow-up

Re-measure the deep-suspend floor directly now that the voltage channel
works, and restate todo/006's power figures from real data rather than from
`current x assumed voltage`.
