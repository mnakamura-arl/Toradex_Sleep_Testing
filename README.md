# sleep_test

Minimal, self-contained power-monitoring stack for sleep/power-draw testing:
an INA228 service (high-precision shunt power/energy monitor) logging bus
voltage, shunt voltage, current, and power to a local Postgres. Scaffolding
(compose layout, config.env, secrets, tools) follows METOC_BUOY conventions,
but this directory is standalone — no gpsd-chrony, loki, or fluent-bit, so
the stack itself adds as little load as possible during a sleep test.

## Layout

```
compose.yaml        postgres + ina228 (METOC_BUOY-style, trimmed)
config.env          SYSTEM_ID, UPDATE_PERIOD_MS, LOGGING_LEVEL, DB vars
secrets/            db_user.txt, db_password.txt  <-- placeholders, change them
services/ina228/    INA228 service (copy of the ina228 repo, + energy column)
scripts/            Verdin iMX8M Plus power test suite (runs on the DUT)
tools/
  pull_deploy_images.sh   pull arm64 images on an internet machine, ship + load
  deploy_to_target.sh     rsync this directory onto the monitor stack
  pm_run.sh               test orchestrator (runs on the monitor stack)
```

## Two-stack test topology

Two Toradex stacks: the **DUT** (Verdin + peripherals) runs the `scripts/`
sleep tests; the **monitor** runs this compose stack and measures the DUT.
The INA228 shunt goes in series with the DUT's input supply (high side),
grounds common, I2C to the monitor's `/dev/i2c-3` at `0x41`.

All phase boundaries are stamped by the monitor's clock (`tools/pm_run.sh`
inserts markers into postgres around each ssh'd test command), because the
DUT's clock drifts or stops during suspend. Per-phase averages come from the
1 Hz samples AND from the INA228 energy accumulator (`true_avg_mw`), which
integrates at ADC rate and therefore catches resume inrush between samples.

## Running a campaign (from the monitor stack)

```bash
cd ~/sleep_test
DUT=torizon@<dut-ip>

./tools/pm_run.sh init          # create the pm_phases marker table (once)
./tools/pm_run.sh push $DUT     # copy scripts/ to the DUT

export PM_RUN_ID=$(date +%Y%m%d-%H%M)   # group this campaign's phases

# Baseline first: DUT idle, nothing running
./tools/pm_run.sh baseline idle-baseline 120

# Then the suggested script order, each wrapped in markers:
./tools/pm_run.sh run $DUT probe        'cd sleep_test/scripts && sudo ./01-probe.sh'
./tools/pm_run.sh run $DUT suspend-60   'cd sleep_test/scripts && sudo ./02-suspend-cycle.sh -d 60'
./tools/pm_run.sh run $DUT suspend-torn 'cd sleep_test/scripts && sudo ./02-suspend-cycle.sh -d 120 -n 3 -e -U'
./tools/pm_run.sh run $DUT tuned-apply  'cd sleep_test/scripts && sudo ./05-runtime-tune.sh apply'
./tools/pm_run.sh baseline tuned-idle 120
./tools/pm_run.sh run $DUT tuned-revert 'cd sleep_test/scripts && sudo ./05-runtime-tune.sh revert'
# poweroff-wake: the DUT drops off ssh — wrap the whole off window as a baseline
./tools/pm_run.sh run $DUT poweroff-arm 'cd sleep_test/scripts && sudo ./03-poweroff-wake.sh arm 300' || true
./tools/pm_run.sh baseline powered-off 300

./tools/pm_run.sh report        # per-phase avg/min/max + accumulator truth
```

For `04-ab-matrix.sh` (which prompts you to type meter readings in mW), run
`./tools/pm_run.sh watch` in a second terminal on the monitor and read the
rolling average off the screen.

The soak goes the same way overnight:

```bash
./tools/pm_run.sh run $DUT soak 'cd sleep_test/scripts && sudo ./06-soak.sh -n 300 -d 120 -a 15'
```

Notes:
- `report` shows `true_avg_mw` from the energy register; a negative
  `energy_j` means the ina228 service restarted mid-phase (accumulator
  reset) — trust `avg_mw` for that row.
- If the stack ran before the energy column existed, recreate the table:
  `docker compose exec postgres psql -U "$(cat secrets/db_user.txt)" -d data
  -c 'DROP TABLE ina228_data;'` then restart the ina228 service.

## Getting it onto the target

On a machine with internet + SSH access to the target:

```bash
# 1. Edit secrets/*.txt and config.env (SYSTEM_ID, UPDATE_PERIOD_MS)
# 2. Pull the external images (postgres, metoc base) and load them on the target
./tools/pull_deploy_images.sh torizon@<target-ip>
# 3. Transfer this directory
./tools/deploy_to_target.sh torizon@<target-ip>
```

Then on the target:

```bash
cd ~/sleep_test
docker compose build
docker compose up -d
```

## Hardware assumptions

- INA228 at address `0x41` (A0 strapped high) on `/dev/i2c-3`. Adjust the
  `devices:` mapping and `DEVICE_PORT`/`DEVICE_ADDRESS` in compose.yaml if
  the wiring changes.
- Calibration defaults in the service: 15 mOhm shunt, 10 A max
  (`set_calibration(0.015, 10.0)` in `services/ina228/src/ina228/ina228_module.py`).
  Change there if the sense resistor differs.

## Reading results

The service creates and writes `ina228_data` in database `data`:

```bash
docker compose exec postgres psql -U "$(cat secrets/db_user.txt)" -d data \
  -c "SELECT timestamp, bus_voltage, current, power FROM ina228_data ORDER BY timestamp DESC LIMIT 20;"
```

Postgres is also exposed on host port 5432 for querying from the GCS.
