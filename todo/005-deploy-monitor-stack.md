# 005 — Deploy the compose stack to the monitor (192.168.1.212)

**Status:** resolved (2026-08-20)
**Context:** all testing so far ran without the monitor stack deployed to the
box that actually has the INA228 (roles confirmed in todo/001). The next
phase needs the stack live on .212 and the campaign driven from there.

## Steps

From a machine on the device network with docker + internet (the dev laptop):

1. `./tools/pull_deploy_images.sh torizon@192.168.1.212` — arm64 postgres +
   metoc base image, shipped and loaded.
2. `./tools/deploy_to_target.sh torizon@192.168.1.212` — sync this directory.
3. Monitor→DUT ssh: .212 needs key-based ssh to torizon@192.168.1.213
   (pm_run runs on .212 and drives the DUT from there).
4. On .212: `cd sleep_test && docker compose build && docker compose up -d`,
   confirm postgres healthy and ina228 writing samples.
5. On .212: `./tools/pm_run.sh init && ./tools/pm_run.sh push torizon@192.168.1.213`,
   then `watch` shows live power.

## Done when

`watch` on .212 shows plausible V/mA and a run-detached suspend-60 against
.213 produces a report row (that also closes todo/003). Record results below.

## Results

2026-08-20: stack was already live on .212 (up 21 h, postgres healthy, INA228
answering at i2c-3/0x41, energy accumulating ~1.6 W avg). Deployed today's
tools/scripts/docs, verified monitor→DUT ssh, pushed scripts, probe phase 28
exit 0 with `ethernet0` correctly detected. Campaign run id `20260820-0725`.
Observation to watch: bus_voltage samples bounce 2.9-5.5 V — check the sense
point/rail with a scope if power numbers look noisy.
