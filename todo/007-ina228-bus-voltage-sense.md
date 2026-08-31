# 007 — INA228 bus-voltage channel is dead; all power numbers invalid

**Status:** pending (needs bench work — wiring)
**Found:** 2026-08-31, on restarting the project.

## Evidence

The DUT's real supply rail measured with a multimeter is a steady
**11.9 V**. The INA228 has never reported anything close to that, and its
reading has decayed steadily since the campaign:

| Period | reported bus_voltage (avg) | range | current (avg) |
|--------|---------------------------|-------|---------------|
| 2026-08-21/22 | 3.9 V | 2.2 – 6.0 V | ~332 mA |
| 2026-08-27 | 1.41 V | 0.02 – 1.94 V | ~385 mA |
| 2026-08-31 | 0.96 V | 0.67 – 1.20 V | ~342 mA |

Two things make this conclusive:

1. The reported voltage bounces randomly sample-to-sample (2.3 V then 5.8 V
   then 2.4 V, 1 s apart) on a rail a multimeter shows as rock-steady 11.9 V.
   That is a floating / high-impedance input picking up leakage, not a rail.
2. **The current channel is fine.** It is stable, physically sensible, and
   independent of the voltage decay — ~342 mA awake throughout all three
   periods above, and it resolves suspend transitions crisply (315 mA awake
   → 25 mA deep → 424 mA resume inrush). Shunt voltage 5.129 mV at 342 mA
   implies a 15 mΩ shunt, which is the expected value.

So the differential shunt input is healthy and the VBUS sense is not.

## Impact

`power` is computed by the INA228 as bus_voltage x current, so **every power
and energy figure this project has recorded is wrong**, including the
headline numbers in todo/006. Corrected via current x 11.9 V:

| State | Current | Recorded (bogus) | True |
|-------|---------|------------------|------|
| Awake idle | ~315 mA | ~1.5 W | **~3.75 W** |
| Deep suspend | ~25 mA | 74 mW | **~300 mW** |
| Hung suspend | ~205 mA | ~0.8 W | **~2.4 W** |

The deep-sleep floor is ~300 mW, not the 74 mW recorded as a breakthrough.
`true_avg_mw` from the energy accumulator is equally affected — it
integrates the same bad voltage.

## Steps

1. Inspect the VBUS sense connection at the INA228 breakout: is the VBUS pin
   actually landed on the 12 V DUT input node, and is the wire/solder joint
   intact? The steady decay across ten days points at a joint that was
   marginal on 2026-08-20 and has since opened up.
2. Confirm the INA228 is not being asked to read VBUS through a divider or
   from a node downstream of a regulator.
3. With it reconnected, `./tools/pm_run.sh watch` on the monitor should show
   ~11.9 V steady and awake power ~3.7 W.
4. If the VBUS input itself is damaged, the fallback is to stop trusting it
   and compute power as `current x V_nominal`, with the rail verified by
   multimeter per session — the current channel is trustworthy. This would
   mean adding a nominal-voltage setting and reworking `report_sql` /
   `true_avg_mw`, which currently lean on the INA's own power and energy
   registers.

## Done when

`watch` shows ~11.9 V steady, and a re-measured deep-suspend phase reports a
floor consistent with ~25 mA x 11.9 V. Then restate todo/006's power
figures from real data.
