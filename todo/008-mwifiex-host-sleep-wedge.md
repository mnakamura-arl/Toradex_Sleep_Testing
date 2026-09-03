# 008 — mwifiex host-sleep handshake wedges, then blocks every suspend

**Status:** RESOLVED 2026-09-03 — **Wi-Fi does not ship in this product**
(confirmed by the user), so blacklisting mwifiex is the correct permanent
configuration, not a workaround hiding a fielded defect. The defect itself is
real and documented below in case Wi-Fi is ever added.
**Evidence:** soak run `20260901-010845` — 1890 cycles, 4 ok, 1886 FAIL.

## What happens

Deep suspend works normally for a few cycles. Then the mwifiex host-sleep
activation times out, the firmware enters a bad state, and **it never
recovers** — every subsequent suspend attempt aborts in ~11 s. The board stays
up and keeps retrying, so nothing crashes and nothing reboots; the soak simply
degenerates into a fast retry loop.

Caught on the serial console (2026-09-01 02:01, cycle 5 of the soak):

```
02:01:04 PM: suspend entry (deep)
02:01:04 tpm_tis_spi spi1.1: Ignoring error -5 while suspending
02:01:14 mwifiex_sdio mmc0:0001:1: mwifiex_cmd_timeout_func: Timeout cmd id = 0x6b, act = 0x1
02:01:14 mwifiex_sdio mmc0:0001:1: is_cmd_timedout = 1
02:01:14 mwifiex_sdio mmc0:0001:1: PREP_CMD: FW is in bad state
02:01:14 mwifiex_sdio mmc0:0001:1: IOCTL request HS enable failed
02:01:14 mwifiex_sdio mmc0:0001:1: cmd: failed to suspend
02:01:14 mwifiex_sdio mmc0:0001:1: PM: dpm_run_callback(): pm_generic_suspend+0x0/0x44 returns -14
02:01:14 PM: suspend of devices aborted after 10381.429 msecs
02:01:14 PM: Some devices failed to suspend, or early wake event detected
```

`-14` is EFAULT — the "Bad address" errno seen back in run `20260820-0725`
phase 29. **The 2026-08-20 notes were right about mwifiex being a blocker.**
It was wrongly retracted on 2026-08-31 as "downstream of the wrong device
tree": the DTB was the cause of the *hangs and watchdog resets*, and this is a
separate defect that survives the DTB fix. Both were real.

Note the failure is an **abort**, not a hang — the board stays alive. That is
why the 40 h soak produced zero resets while still failing 1886 times.

## Cost of not detecting it

The soak ran 39 hours at ~2.9 W instead of ~400 mW because nothing acted on
sustained failure. `06-soak.sh` now takes `-F N` to abort after N consecutive
failures (and latches `$PM_STATEDIR/STOP` so systemd will not relaunch it).
`-F 5` would have caught this in about 6 minutes.

## Workaround in place

Wi-Fi is unused on this unit — `mlan0`/`uap0` are DOWN with no addresses, and
everything runs over `ethernet0`. So mwifiex is blacklisted at boot via
`scripts/08-power-profile.sh install` (`WIFI=off` in `power-profile.conf`).

Blacklisting at boot rather than `rmmod` at runtime is deliberate: a driver
that has already initialised can leave firmware state behind, which is the
likely explanation for the 2026-08-20 `-w` reboots.

Bonus: it also cut the sleep floor from 262 mW to 222 mW.

## If Wi-Fi is ever added to the product, this must actually be fixed

Not applicable today — Wi-Fi does not ship. Kept because adding it later would
reintroduce a device that cannot suspend. Avenues, roughly in order of
cheapness:

1. **Firmware version.** Running `mwifiex 1.0 (16.92.21.p137)`. Check Toradex
   / NXP for a newer NXP 8997 SDIO firmware — host-sleep handshake bugs are a
   known class here.
2. **Disable host-sleep entirely** and let the interface go down before
   suspend instead: `ip link set mlan0 down` did NOT help (phase 36), but
   fully unloading only the `_sdio` half, or `disconnect + rfkill block`
   before entry, is untried.
3. **Power-save / host_mlme module parameters** — check
   `/sys/module/mwifiex/parameters` for options affecting the HS path.
4. **Recovery rather than prevention:** detect `FW is in bad state` in dmesg
   and `modprobe -r mwifiex_sdio; modprobe mwifiex_sdio` to reset the
   firmware, then retry. Ugly, but it would keep a fielded device suspending.
5. Toradex support — the module is a Verdin iMX8MP WB, this is their Wi-Fi
   stack, and the failure is reproducible within ~an hour of cycling.

## Done when

Done: the product is confirmed not to use Wi-Fi (2026-09-03). Reopen only if
Wi-Fi is added, in which case the bar is a soak of 100+ cycles with mwifiex
loaded.
