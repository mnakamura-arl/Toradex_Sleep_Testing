# 001 — Passwordless sudo on the DUT + confirm box roles

**Status:** resolved (2026-08-20)
**Evidence:** run `20260819-1950` phase 2 failed with `sudo: a terminal is
required to read the password` against 192.168.1.212.

## Resolution

The box roles were recorded swapped in the early docs. Corrected 2026-08-20:

- **192.168.1.212 = monitor** (INA228 + compose stack). It has no passwordless
  sudo, and doesn't need it — pm_run.sh only needs docker, and
  `torizon` on .212 runs docker without sudo (verified).
- **192.168.1.213 = DUT**. Passwordless sudo verified working
  (`ssh torizon@192.168.1.213 'sudo -n true'` → ok), which is also why all of
  the 2026-08-19 suspend testing on .213 ran — it was aimed at the right box
  all along.

The 1950 failure was simply the campaign briefly pointed at the monitor.
No sudoers change was needed anywhere. Docs and RUNBOOK now carry the correct
roles. Follow-on work (deploying the monitor stack to .212) is todo/005.
