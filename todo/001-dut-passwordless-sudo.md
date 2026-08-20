# 001 — Passwordless sudo on the DUT, re-aim campaign at 192.168.1.212

**Status:** pending
**Evidence:** run `20260819-1950` phase 2: `sudo: a terminal is required to
read the password` from torizon@192.168.1.212. All subsequent testing that
night targeted 192.168.1.213 (the monitor/INA box) instead — so no run so far
has measured the actual DUT, and suspending the monitor freezes the INA
sampling and the orchestrator.

## Step-by-step

All from the monitor (192.168.1.213) unless noted.

1. Key-based ssh to the DUT (skip if `ssh torizon@192.168.1.212 true` already
   works without a password prompt):

   ```bash
   ssh-keygen -t ed25519 -N '' -f ~/.ssh/id_ed25519   # if no key yet
   ssh-copy-id torizon@192.168.1.212
   ```

2. On the DUT (one interactive session, password needed this one time):

   ```bash
   ssh -t torizon@192.168.1.212 \
     "echo 'torizon ALL=(ALL) NOPASSWD: ALL' | sudo tee /etc/sudoers.d/010-torizon-nopasswd \
      && sudo chmod 0440 /etc/sudoers.d/010-torizon-nopasswd"
   ```

   (Torizon OS: /etc is writable and persists via the overlay. If the image
   is locked down differently, `sudo visudo -f /etc/sudoers.d/010-torizon-nopasswd`
   interactively instead.)

3. Verify non-interactively — this is the runbook pre-flight gate:

   ```bash
   ssh torizon@192.168.1.212 'sudo -n true && echo sudo-ok'
   ```

4. Re-aim the campaign at the DUT:

   ```bash
   cd ~/sleep_test
   DUT=torizon@192.168.1.212
   ./tools/pm_run.sh push $DUT
   export PM_RUN_ID=$(date +%Y%m%d-%H%M)
   ./tools/pm_run.sh run $DUT probe 'cd sleep_test/scripts && sudo ./01-probe.sh'
   ```

5. Check the probe log: confirm the RTC list, sleep states, and that
   `ethernet :` now names a real NIC (not can0). Then proceed with the
   RUNBOOK sequence using `run-detached` for the suspend phases.

## Done when

`probe` exits 0 against 192.168.1.212 and a `suspend-60` run-detached phase
completes there with power data in the report. Note the RUN_ID here and move
this to resolved.
