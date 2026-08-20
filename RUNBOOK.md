# Sleep-test runbook

Step-by-step for one measurement campaign.

Topology:

| Role    | Machine                     | IP            | Runs                                  |
|---------|-----------------------------|---------------|---------------------------------------|
| Monitor | Toradex stack with INA228   | 192.168.1.213 | this compose stack + `tools/pm_run.sh`|
| DUT     | Verdin stack w/ peripherals | 192.168.1.212 | `scripts/` sleep tests (via ssh)      |

The INA228 shunt is in series with the DUT's input supply (high side), grounds
common, I2C to the monitor's `/dev/i2c-3` at address `0x41`.

All commands below run **on the monitor (192.168.1.213)** from `~/sleep_test`
unless marked otherwise.

---

## 0. Pre-flight (once per setup)

```bash
cd ~/sleep_test
DUT=torizon@192.168.1.212
```

1. Secrets and config: edit `secrets/db_user.txt`, `secrets/db_password.txt`,
   and `config.env` (`SYSTEM_ID`, `UPDATE_PERIOD_MS`).
2. Stack up and healthy:

   ```bash
   docker compose up -d --build
   docker compose ps                  # postgres should be "healthy"
   docker compose logs ina228 | tail  # expect "Init complete" + "Database write successful"
   ```

3. Sanity-check the readings — with the DUT idle this should show a plausible
   voltage and a steady draw:

   ```bash
   ./tools/pm_run.sh watch
   ```

4. SSH: key-based login to the DUT must work non-interactively, and the
   `torizon` user needs **passwordless sudo** (the scripts arm RTC alarms and
   write to /sys). Test both:

   ```bash
   ssh $DUT 'sudo -n true && echo sudo-ok'
   ```

5. One-time table + script push:

   ```bash
   ./tools/pm_run.sh init
   ./tools/pm_run.sh push $DUT
   ```

If any step fails, stop here — nothing downstream will produce usable data.

## 1. Start a campaign

```bash
export PM_RUN_ID=$(date +%Y%m%d-%H%M)   # groups this campaign's phases
```

Every `run`/`baseline`/`report`/`collect` in the same shell uses this id.
(Without it, phases fall into a shared per-day bucket.)

## 2. The measurement sequence

```bash
# Idle baseline first - everything on, nothing sleeping
./tools/pm_run.sh baseline idle-baseline 120

# Inventory (also proves ssh+sudo works end to end)
./tools/pm_run.sh run $DUT probe 'cd sleep_test/scripts && sudo ./01-probe.sh'

# Single verified suspend. run-detached, NOT run: the DUT drops off the
# network while asleep, and a plain ssh session would die in TCP timeout and
# record a false failure (see todo/003). Last arg = timeout seconds.
./tools/pm_run.sh run-detached $DUT suspend-60 \
    'cd sleep_test/scripts && sudo ./02-suspend-cycle.sh -d 60' 600

# Suspend with peripherals torn down (minutes-mode candidate)
./tools/pm_run.sh run-detached $DUT suspend-torn \
    'cd sleep_test/scripts && sudo ./02-suspend-cycle.sh -d 120 -n 3 -e -U' 1200

# Runtime knobs A/B
./tools/pm_run.sh run $DUT tune-apply 'cd sleep_test/scripts && sudo ./05-runtime-tune.sh apply'
./tools/pm_run.sh baseline tuned-idle 120
./tools/pm_run.sh run $DUT tune-revert 'cd sleep_test/scripts && sudo ./05-runtime-tune.sh revert'

# Full poweroff + RTC wake. The DUT drops off ssh, so the arm command may
# come back with an error even on success - wrap the off-window as a baseline.
./tools/pm_run.sh run $DUT poweroff-install 'cd sleep_test/scripts && sudo ./03-poweroff-wake.sh install'
./tools/pm_run.sh run $DUT poweroff-arm 'cd sleep_test/scripts && sudo ./03-poweroff-wake.sh arm 300' || true
./tools/pm_run.sh baseline powered-off 300

# Overnight soak of the winning config (run under nohup/tmux)
./tools/pm_run.sh run-detached $DUT soak \
    'cd sleep_test/scripts && sudo ./06-soak.sh -n 300 -d 120 -a 15' 54000
```

For `04-ab-matrix.sh` (interactive; asks you to type mW readings): open a
second terminal on the monitor running `./tools/pm_run.sh watch`, then in the
first terminal `ssh -t $DUT 'cd sleep_test/scripts && sudo ./04-ab-matrix.sh both'`
and type the watch numbers in. Its CSV comes back with `collect`.

## 3. Results

```bash
./tools/pm_run.sh report
```

Columns: `dur_s` phase length, `n` sample count, `avg/min/max_mw` from the
1 Hz samples, `energy_j` and `true_avg_mw` from the INA228's hardware energy
accumulator. **`true_avg_mw` is the number to quote** — it integrates at ADC
rate and includes resume inrush that 1 Hz sampling misses.

## 4. Collect and transfer back

```bash
./tools/pm_run.sh collect $DUT
```

This bundles `results-$PM_RUN_ID.tgz` containing:

| File | What it is |
|------|------------|
| `report.csv` | the per-phase results table |
| `pm_phases.csv` | raw markers (start/end/exit codes) |
| `ina228_samples.csv` | every 1 Hz sample in the run window (+60 s margin) |
| `ina228-service.log` / `postgres-service.log` | monitor container logs |
| `dut-pmtest.tgz` | DUT `/var/log/pmtest` + `/var/lib/pmtest` (script CSVs, soak logs, poweroff-wake verdicts) |
| `orchestrator.log`, `phase-*.log`, `errors.log` | what ran, full remote output, failures |

Pull it back to your laptop/GCS:

```bash
scp torizon@192.168.1.213:sleep_test/results-<RUN_ID>.tgz .
```

## Tracking issues and results

- Open items live in `todo/` — one numbered file per issue with status
  (pending / in-progress / needs-retest / resolved) and a step-by-step plan;
  `todo/README.md` is the index.
- After reviewing a run, triage its `logs/<RUN_ID>/` dir into `logs/pending/`
  (issue still open, link the todo item in a FINDINGS.md) or `logs/resolved/`
  (confirmed result). See `logs/README.md`.
- Known-benign kernel PM errors can be tolerated per-run with
  `PM_DMESG_IGNORE='<egrep pattern>'` in the remote command, e.g.
  `sudo PM_DMESG_IGNORE=lt8912 ./02-suspend-cycle.sh -d 60` (see todo/002).

## Troubleshooting

Errors land in `logs/<RUN_ID>/errors.log` (with the tail of the failing
phase log); full remote output is in `logs/<RUN_ID>/phase-<id>-<label>.log`.

| Symptom | Likely cause / fix |
|---------|--------------------|
| ina228 service: `Device not found at address 0x41` | Wiring/address. `ls /dev/i2c-3` on the monitor, probe with `i2cdetect -y 3`. A0 strap must be high for 0x41. |
| ina228 service: `Failed to find INA228 ... Got ID` | Wrong chip answered (something else at 0x41 on bus 3). |
| `report` rows with `n=0` | No samples in the window: ina228 service down during the phase (check `ina228-service.log`), or phases created while the stack was down. |
| Negative `energy_j` | ina228 service restarted mid-phase (accumulator reset). Use `avg_mw` for that row; rerun the phase for an accumulator number. |
| `run` fails instantly, `sudo: a password is required` in phase log | Passwordless sudo not set for torizon on the DUT. |
| `02-suspend-cycle` aborts, `EBUSY` on wakealarm | Stale alarm from a previous run — scripts clear it, but check nothing else armed it; `echo 0 \| sudo tee /sys/class/rtc/rtc*/wakealarm`. |
| Suspend draw much higher than ~150 mW module floor | Carrier rails not gating: scope CTRL_SLEEP_MOCI# (SODIMM 256); tear peripherals down (`-e -U` flags); see scripts/README.md. |
| `collect`: "could not fetch DUT logs" | DUT unreachable (mid-poweroff-test?) or sudo prompt. Rerun `collect` when it's back — DUT logs persist in /var/log/pmtest. |
| `postgres` never becomes healthy | `docker compose logs postgres`; commonest cause is a stale volume with different credentials — `docker compose down -v` (destroys data) and re-up. |
