# 006 — Deep suspend blockers: root cause was the wrong carrier device tree

**Status:** RESOLVED 2026-08-31 — the DUT was booting the Verdin Development
Board device tree on Mallow hardware. With the correct
`imx8mp-verdin-wifi-mallow.dtb`, deep suspend went from ~25% reliable to
**5/5 clean cycles** (run `20260831-mallow` phase 47, exit 0, no reset), and
the sleep floor dropped from 995 mW to **262 mW**. See the 2026-08-31 section
below. Everything above it is the investigation that led there, kept for the
record — several of its conclusions are retracted.

**Original status:** pending
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

## 2026-08-31 — ROOT CAUSE FOUND: wrong carrier device tree

The DUT is a Verdin iMX8M Plus on a **Mallow** carrier, but it was booting the
**Verdin Development Board** device tree. U-Boot could not identify the
carrier from its EEPROM —

```
Carrier: Toradex UNKNOWN CARRIER BOARD V1.1C, Serial# 12938720
```

— so it fell back to `fdt_board=dev` / `fdtfile=imx8mp-verdin-wifi-dev.dtb`,
and nobody ever corrected it. On top of that, `overlays.txt` was loading
`verdin-imx8mp_hdmi_overlay.dtbo` and `verdin-imx8mp_dsi-to-hdmi_overlay.dtbo`
for display hardware Mallow does not have — that is where the `lt8912` bridge
kept coming from, and why unbinding it never stuck across a reboot.

The result was four drivers bound to absent hardware, each carrying
suspend/resume callbacks:

```
pca953x 3-0021: failed writing register            <- GPIO expander, dev board only
ina2xx 3-0040: error configuring the device: -6    <- ENXIO, no such device
nau8822 3-001a: Failed to issue reset: -6          <- audio codec, absent
imx_sec_dsim_drv: Failed to attach bridge: -517    <- DSI bridge, absent
```

### The fix

```bash
sudo fw_setenv fdt_board mallow
sudo fw_setenv fdtfile imx8mp-verdin-wifi-mallow.dtb
# and in <ostree deploy>/dtb/overlays.txt, drop the hdmi + dsi-to-hdmi overlays:
fdt_overlays=verdin-imx8mp_spidev_overlay.dtbo verdin-imx8mp_gnss-pps-gpio.dtbo
```

`imx8mp-verdin-wifi-mallow.dtb` was already present on the device — it simply
was not being selected. After reboot the model reads
`Toradex Verdin iMX8M Plus WB on Mallow Board`, compatible
`toradex,verdin-imx8mp-wifi-mallow`, and all four phantom-device errors are
gone.

### Results

Phase 46, `deep -d 60`, first attempt after the DTB change: **exit 0**, and
the sleep floor collapsed:

| | Current | Power | |
|---|---------|-------|---|
| Deep sleep, wrong DTB (phase 42) | 84.5 mA | 995 mW | |
| Deep sleep, **Mallow DTB** (phase 46) | **22.7 mA** | **266 mW** | **3.7x better** |

That also explains the long-standing 84 mA vs 25.8 mA puzzle between
2026-08-31 and 2026-08-20 — it was never a measurement artifact, it was how
many phantom devices happened to be powered.

Awake draw dropped too, ~325 mA -> ~222 mA.

### Confirmed: 5 consecutive cycles (phase 47, `deep -d 60 -n 5`)

`exit 0`, DUT never rebooted, every cycle clean:

```
cycle,mode,requested_s,measured_s,drift_s,resume_ok,notes
1,deep,60,61,1,yes,
2,deep,60,61,1,yes,
3,deep,60,61,1,yes,
4,deep,60,61,1,yes,
5,deep,60,61,1,yes,
```

Measured over the whole run (280 sleep samples / 426 awake samples):

| State | Current | Voltage | **Power** |
|-------|---------|---------|-----------|
| Deep sleep | 22.31 mA | 11.750 V | **262 mW** (225–295) |
| Awake idle | 222.15 mA | 11.75 V | **2.59 W** |

**~9.9x saving asleep.** This closes the "Done when" criterion below.

Before/after the DTB fix, same board, same script:

| | Reliability | Sleep floor | Awake |
|---|---|---|---|
| Dev-board DTB | 1 of 4 attempts | 995 mW | 3.9 W |
| **Mallow DTB** | **6 of 6** | **262 mW** | **2.59 W** |

**Retired hypotheses.** The mwifiex `hs_activate` aborts, the xhci
ETIMEDOUTs, and the `lt8912` resume error were all downstream of the wrong
device tree, not independent bugs. The "never rmmod mwifiex" rule and the
"fresh post-boot firmware" recipe were both noise fitted to a flaky system.

## Serial console (for future debugging)

Mallow has no onboard USB-serial. The debug UART is on **X11** (0.1" header,
right of the ethernet jack, needs a header soldered) at **1.8 V** levels —
use the FTDI **TTL-232RG-VREG1V8-WE**; a 3.3 V adapter is over-voltage.

Wiring: cable black->GND, orange (TXD)->X11 UART3_RX, yellow (RXD)->X11
UART3_TX. Leave red/brown/green unconnected.

U-Boot's console is already `serial@30880000` = i.MX UART3 = `ttymxc2` =
`verdin-uart3` at 115200, and the kernel console follows the device tree's
`stdout-path` to the same port — so **no `console=` kernel argument is
needed**; a login prompt appears on it out of the box.

Loose end: `no_console_suspend` was added to
`/boot/loader/entries/ostree-1.conf` but does **not** reach `/proc/cmdline`
after reboot — Torizon appears to source kernel args from the `aboot.cfg`
referenced in that entry instead. Needs solving before the console can log
the inside of a suspend.

## Older next steps (mostly superseded by the DTB fix)

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
