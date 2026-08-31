# 006 — Deep suspend blockers: mwifiex, xhci; hard reboot with -w -U

**Status:** pending
**Evidence:** run `20260820-0725` phases 29-31 (first run with the dmesg-dump
diagnostics; lt8912 unbound throughout):

- Phase 29 (`-d 60`): abort at entry — `mwifiex_sdio ... cmd: failed to
  suspend ... returns -14` (EFAULT = the "Bad address" writes). The Wi-Fi
  host-sleep handshake is the first blocker, as the scripts README warned.
- Phase 30 (`-d 60 -w`, Wi-Fi unloaded): next blocker surfaces —
  `xhci-hcd xhci-hcd.2.auto: WARN: xHC CMD_RUN timeout ...
  platform_pm_suspend returns -110` (= the historical ETIMEDOUT aborts).
- Phase 31 (`-d 60 -w -U`, USB torn down too): the DUT **hard-rebooted**
  (uptime reset; no crash log — journal is volatile). /tmp and /var/log are
  tmpfs on this image, which also destroyed the in-flight phase output;
  pm_run now stages under $HOME and scripts log to /var/lib/pmtest/log so
  this can't hide evidence again.
- Phase 33 (`-d 60 -w`, xhci-hcd.2.auto unbound — it hosts the USB audio
  mic): **second hard reboot**. The recovered out_33.log (persistent staging
  worked) shows wifi unloaded, RTC armed, "mem" written — then reset. So with
  Wi-Fi unloaded the board ENTERS deep and dies asleep or at RTC wake.
  Contrast 20260819-2036 phase 24: deep worked for 61 s WITH Wi-Fi loaded.
  Working hypothesis: rmmod mwifiex_sdio leaves SDIO/PMIC state that kills
  deep, or a watchdog fires while asleep. The report's min_mw ~25 for the
  crash phases shows the rail does drop to a deep floor before/during reset.

The LT8912B (todo/002) turned out to be resume-noise, not the entry abort.

## Bench session 2026-08-20 (run `20260820-bench`) — BREAKTHROUGH

- Phase 34/35: mic unplugged; xhci gone from the picture, mwifiex still
  aborts entry (hs_activate). Its pass in 2036/24 was luck, not config.
- Phase 36: `ip link set down` on mlan0/uap0 does NOT fix hs_activate.
- Phase 37: `-w` with mic unplugged → **reboot #3**. Confirms
  `rmmod mwifiex_sdio` + deep entry = instant reset, independent of USB.
  INA data shows ≲1 s at the deep floor before reset (phases 31: 25 mW for
  ~1 s; 37: reset too fast for 1 Hz). Likely regulator/PMIC mis-sequencing —
  note the `_regulator_put` refcount WARNs from the suspend process.
- **Phase 38 (fresh post-boot mwifiex firmware, driver LOADED, mic
  unplugged, lt8912 unbound, plain `-d 60`): PASS.** `resumed after 60s
  (drift 0s)`, kernel-confirmed entry, exit 0. Deep floor ≈ **74 mW** at the
  DUT input rail (min_mw 73.7; true_avg 504.5 mW over the 83 s marker window
  including awake overhead).

**Working recipe (RETRACTED — see below):** leave mwifiex loaded (fresh
firmware state), mic unplugged/gated, lt8912 unbound, `echo mem` plain deep.
NEVER rmmod mwifiex before deep. 5-cycle reliability test in flight
(phase 39).

## 2026-08-31 — phase 39 recovered; the reboots are WATCHDOG resets

Phase 39 never completed: the orchestrator session dropped, and `recover`
correctly left it open because the DUT wrote no exit code. Its staged
`out_39.log` ends mid-cycle-1 at `entering deep ... mem`, and its results CSV
has only a header. **Phase 39 was reboot #4.**

Two things follow.

### 1. Phase 38's recipe is not reliable

Phase 39 ran the identical config and command (only `-n 5` added) 11 minutes
later and died on cycle 1. The phase-38 pass was one sample, not a recipe.
What distinguishes them is that 38 was the *first* deep entry after boot and
39 followed 38's resume — i.e. the resume path plausibly leaves state that
wedges the next entry (cf. the `_regulator_put` refcount WARNs). Consistent
with 20260819-2036/24, which was also a first successful entry.

### 2. The hard reboots are the i.MX watchdog firing on a hung suspend

Confirmed on the DUT 2026-08-31:

```
/sys/class/watchdog/watchdog0:  identity=imx2+ watchdog  state=active  timeout=30
PID 1 (systemd) holds /dev/watchdog0;  RuntimeWatchdogUSec=30s
```

`imx2_wdt`'s suspend hook re-arms the watchdog to `IMX2_WDT_MAX_TIME` = 128 s
before going down. A successful suspend resumes inside that budget and the
watchdog never fires — which is why 24 and 38 passed. A **hung** suspend is
never pinged again and gets reset at ~128 s, silently, with no panic and no
log. That is precisely why four reboots left zero evidence.

The INA current trace proves it — both crash phases plateau dead-flat and
then reset ~128 s later:

| Phase | Enters hung state | Reset / boot rise | Interval |
|-------|-------------------|-------------------|----------|
| 37 (`-w`) | 18:40:30 @ ~195 mA | 18:42:39 | ~129 s |
| 39 (`-n 5`) | 19:01:14 @ ~207 mA | 19:03:20 | ~126 s |

**The watchdog is not the root cause — it is why the root cause is
invisible.** The real bug is whatever hangs the suspend path. The hung state
draws ~205 mA (~2.4 W): partway down, peripherals gated, SoC never reached
deep. A real deep suspend draws ~25 mA.

### 3. All power figures above are wrong — see todo/007

The INA228 bus-voltage channel is dead (real rail is 11.9 V by multimeter;
the sensor logged 2.3–5.8 V and now ~0.96 V). The current channel is healthy.
Corrected: awake idle **~3.75 W**, **deep floor ~300 mW** (not 74 mW),
hung-suspend ~2.4 W, resume inrush ~5.0 W.

## Next steps

1. **Disable the watchdog before any further suspend testing** — it is an
   active confound that destroys evidence and costs a reboot per failure:

   ```bash
   sudo mkdir -p /etc/systemd/system.conf.d
   printf '[Manager]\nRuntimeWatchdogSec=0\n' | \
       sudo tee /etc/systemd/system.conf.d/no-watchdog.conf
   sudo systemctl daemon-reexec
   cat /sys/class/watchdog/watchdog0/state    # expect: inactive
   ```

   A hung suspend then stays hung at ~2.4 W instead of resetting, which is
   both cheaper to observe and far more informative. Revert by deleting the
   drop-in. (Reboots are self-recovering either way — the board has come
   back on its own all four times.)
2. Then re-run the phase-38/39 pair back-to-back with the watchdog off:
   first deep entry after boot, then a second. If #1's hypothesis holds, the
   second hangs — and now it hangs *visibly*.
3. Serial console with `no_console_suspend` to see where it wedges. Now that
   the failure is a known hang rather than a mystery reset, this is the step
   that identifies the offending device callback.
4. Fix todo/007 (VBUS sense) so the phase power numbers mean something.
5. Still untried: scope CTRL_SLEEP_MOCI# (SODIMM 256) during entry;
   pstore/ramoops (less urgent now — a watchdog reset would not have written
   a pstore record anyway, which is consistent with finding none).

Ruled out 2026-08-20: s2idle `-w` (xhci abort, phase 32); deep `-w` with
xhci-hcd.2.auto unbound (phase 33); `ip link set down` on mlan0/uap0 (36).

## Done when

5 consecutive deep (or accepted-fallback s2idle) cycles pass with the chosen
device teardown, with power numbers in the report that come from a working
voltage channel.
