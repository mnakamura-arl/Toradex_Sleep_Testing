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

## Next steps (bench work — needs physical access)

Tried 2026-08-20 and ruled out: s2idle `-w` (same xhci abort, phase 32);
deep `-w` with xhci-hcd.2.auto unbound (reboot, phase 33). Two hard reboots
is enough remote iteration — stop until there is a serial console.

1. Serial console on the DUT with `no_console_suspend` on the kernel cmdline,
   then repeat `-d 60 -w`: the console will show whether it dies going down,
   asleep (watchdog?), or on the resume path.
2. Watchdog check first — cheapest theory to kill: is a watchdog daemon
   holding /dev/watchdog (`sudo lsof /dev/watchdog*`, `wdctl`)? A 60 s wdog
   that isn't paused in suspend exactly matches "dies during a 60 s sleep".
   Yesterday's 61 s success with Wi-Fi loaded weakens this — but confirm.
3. Try deep WITHOUT `-w` but with the mic's controller unbound only
   (mwifiex stays loaded — its suspend succeeded once in 2036/24):
   `echo xhci-hcd.2.auto > .../unbind` then `-d 60` plain. If mwifiex
   suspends clean this run, deep may work with Wi-Fi left alone.
4. Scope CTRL_SLEEP_MOCI# (SODIMM 256) during entry — if carrier rails gate
   wrongly the module can brown out (scripts/README.md notes this signal).
5. Longer term: pstore/ramoops for crash evidence that survives reset.

## Done when

5 consecutive deep (or accepted-fallback s2idle) cycles pass with the chosen
device teardown, with power numbers in the report.
