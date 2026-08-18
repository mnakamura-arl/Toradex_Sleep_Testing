# sleep_test

Minimal, self-contained power-monitoring stack for sleep/power-draw testing:
an INA228 service (high-precision shunt power/energy monitor) logging bus
voltage, shunt voltage, current, and power to a local Postgres. Scaffolding
(compose layout, config.env, secrets, tools) follows METOC_BUOY conventions,
but this directory is standalone — no gpsd-chrony, loki, or fluent-bit, so
the stack itself adds as little load as possible during a sleep test.

## Layout

```
RUNBOOK.md          step-by-step campaign guide - START HERE for a test
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

Two Toradex stacks: the **DUT** (Verdin + peripherals, `192.168.1.212`) runs
the `scripts/` sleep tests; the **monitor** (`192.168.1.213`) runs this
compose stack and measures the DUT. The INA228 shunt goes in series with the
DUT's input supply (high side), grounds common, I2C to the monitor's
`/dev/i2c-3` at `0x41`.

All phase boundaries are stamped by the monitor's clock (`tools/pm_run.sh`
inserts markers into postgres around each ssh'd test command), because the
DUT's clock drifts or stops during suspend. Per-phase averages come from the
1 Hz samples AND from the INA228 energy accumulator (`true_avg_mw`), which
integrates at ADC rate and therefore catches resume inrush between samples.

## Running a campaign

**See RUNBOOK.md** — pre-flight checks, the full measurement sequence, and
troubleshooting. Short version, on the monitor:

```bash
cd ~/sleep_test
export PM_RUN_ID=$(date +%Y%m%d-%H%M)
./tools/pm_run.sh init && ./tools/pm_run.sh push torizon@192.168.1.212
./tools/pm_run.sh run torizon@192.168.1.212 suspend-60 \
    'cd sleep_test/scripts && sudo ./02-suspend-cycle.sh -d 60'
./tools/pm_run.sh report
./tools/pm_run.sh collect torizon@192.168.1.212   # -> results-<RUN_ID>.tgz
```

Everything is logged under `logs/<RUN_ID>/` (orchestrator log, full remote
output per phase, `errors.log` on failures); `collect` bundles those plus the
DB exports and the DUT's `/var/log/pmtest` into `results-<RUN_ID>.tgz` to
transfer back.

Note: if the stack ran before the energy column existed, recreate the table:
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
