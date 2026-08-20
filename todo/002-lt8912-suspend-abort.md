# 002 — LT8912B HDMI bridge aborts deep suspend (ETIMEDOUT)

**Status:** resolved (2026-08-20) — superseded by todo/006. With the new
dmesg diagnostics (run `20260820-0725`), the entry aborts turned out to be
mwifiex (EFAULT) and xhci (ETIMEDOUT), not the LT8912B. The bridge's
`lt8912_bridge_resume returns -6` is real but resume-only noise; tolerate it
with `PM_DMESG_IGNORE=lt8912` or unbind/disable it for headless runs.
Original notes kept below for the unbind/overlay procedures.

**Original status:** pending
**Evidence:** run `20260819-2036` (on 192.168.1.213 — the DUT, roles
confirmed 2026-08-20): ~20 suspend attempts
failed at the `/sys/power/state` write with `Connection timed out` (ETIMEDOUT,
a device suspend callback timing out) and once `Device or resource busy`.
Phase 24 — the one cycle that got through — slept 61 s cleanly and then logged:

```
lt8912 3-0048: PM: dpm_run_callback(): lt8912_bridge_resume+0x0/0x80 [lontium_lt8912b] returns -6
```

The Lontium LT8912B DSI-to-HDMI bridge (i2c `3-0048`) fails its resume
callback; the same device intermittently timing out on the way down is the
prime suspect for the ETIMEDOUT aborts. Phase 24 also proves the platform
itself suspends fine (61 s, 1 s drift).

## Step-by-step

On the board that showed the failures (do this on whichever board will be
the DUT; the bridge exists on any stack using the Verdin DSI-to-HDMI adapter).

1. Confirm the device and driver:

   ```bash
   dmesg | grep -i lt8912
   ls /sys/bus/i2c/drivers/lt8912/
   ```

   Expect a `3-0048` symlink (bus 3, addr 0x48).

2. **Quick test — unbind the bridge, then suspend** (reversible, survives
   until reboot):

   ```bash
   echo 3-0048 | sudo tee /sys/bus/i2c/drivers/lt8912/unbind
   cd sleep_test/scripts && sudo ./02-suspend-cycle.sh -d 60 -n 5
   ```

   With the new diagnostics, any remaining abort prints the dmesg slice
   naming the culprit. If 5/5 cycles pass -> the bridge is confirmed.

3. **Permanent fix for headless power testing — drop the DSI-HDMI overlay**:

   ```bash
   cat /boot/ostree/*/dtb/overlays.txt 2>/dev/null || cat /boot/overlays.txt
   # remove the verdin-imx8mp_dsi-to-hdmi (lt8912) overlay from fdt_overlays,
   # e.g. with: sudo vi /boot/overlays.txt   then reboot
   ```

   Reboot and re-run step 2's suspend cycles without the unbind.

4. **Alternative if HDMI must stay usable:** keep the bridge bound and
   tolerate its (cosmetic) resume error instead:

   ```bash
   sudo PM_DMESG_IGNORE='lt8912' ./02-suspend-cycle.sh -d 60 -n 5
   ```

   This only ignores the named lines in the pass/fail gate — it does NOT fix
   the ETIMEDOUT entry aborts, so expect some cycles to still fail to enter.
   Prefer steps 2-3.

5. Record results: RUN_ID, cycles passed, which option was chosen.

## Done when

5 consecutive `-d 60` cycles pass on the DUT with the chosen configuration,
and a run-detached campaign phase shows the suspend power number. Note the
RUN_ID and move to resolved.
