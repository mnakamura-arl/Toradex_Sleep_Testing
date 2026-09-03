# Soak run — restarted 2026-09-02

Deep-suspend reliability soak. Supersedes the 2026-09-01 run, which failed
after 4 cycles ([todo/008](todo/008-mwifiex-host-sleep-wedge.md)).

## What is running

| Where | What | Unit |
|-------|------|------|
| DUT `.213` | `06-soak.sh -n 0 -A 900 -a 60 -F 5 -C 1-1.1` | `pmtest-soak.service` (enabled) |
| DUT `.213` | power profile applied at boot | `power-profile.service` (enabled) |
| Monitor `.212` | serial console capture | `pmtest-seriallog.service` (enabled) |
| Monitor `.212` | INA228 + postgres, 1 Hz | `docker compose` |

### Hardware state (declared in `scripts/power-profile.conf`)

Blacklisted at boot via `08-power-profile.sh install`:
`mwifiex_sdio`, `mwifiex`, `hci_uart`, `btintel`, `flexcan`, `galcore`.

Wi-Fi is off because it is **unused on this unit and was the blocker that
killed the previous run** — see todo/008. `ethernet0` carries everything.
The GNSS receiver (`/dev/ttyACM1`, `/dev/pps0`) is attached and left alone.

## Power baseline

| State | Current | Power |
|-------|---------|-------|
| Deep sleep, no GNSS attached | 18.9 mA @ 11.73 V | **222 mW** |
| Deep sleep, GNSS attached and bound (this run) | 20.5 mA | **241 mW** |
| Awake idle (with GNSS) | ~250 mA | ~2.9 W |

How the floor got here:

| Config | Current | Floor |
|--------|---------|-------|
| Dev-board DTB, wifi loaded | 84.5 mA | 995 mW |
| Mallow DTB, wifi loaded | 22.3 mA | 262 mW |
| **Mallow DTB, wifi/BT/CAN/GPU off** | **18.9 mA** | **222 mW** |

Reliability going in: 6 consecutive clean cycles after the blacklist
(one `deep 60`, then 5×`deep 60`, all exit 0, 61 s measured, +1 s drift).

## Timing

`-A 900` wakes on wall-clock quarter hours (**:00 :15 :30 :45**), computing
the time to the next boundary each cycle so alignment self-corrects and never
accumulates drift. 60 s awake, so the sleep is ~835 s.

Drift is a **fixed +1 s per transition, not proportional** — measured
identical on 60 s, 376 s and 837 s sleeps. Long sleeps do not accumulate
error.

## The failure guard (new)

`-F 5` aborts after 5 consecutive failures and latches
`/var/lib/pmtest/STOP` so systemd will not relaunch into the same wedge.

This exists because the previous run had no such guard: a wedged mwifiex made
every suspend abort in ~11 s and the soak burned **39 hours at 2.9 W** instead
of 400 mW before anyone looked. `-F 5` catches that in about 6 minutes.

## Where the data lands

| File | Host |
|------|------|
| `/var/lib/pmtest/log/soak-*.csv` | DUT — one row per cycle, persistent |
| `/var/lib/pmtest/log/soak-*.log` | DUT — dmesg for failed cycles |
| `/var/lib/pmtest/log/soak-service.log` | DUT — systemd stdout |
| `~/sleep_test/logs/serial-console.log` | Monitor — timestamped console |
| `ina228_data` table | Monitor — 1 Hz power |

CSV: `cycle,woke_at,requested_s,slept_s,drift_s,eth,usb,ssd,dmesg,verdict`

Serial lines carry the **monitor's** clock — the same clock as the
`ina228_data` rows — so console events and the power trace line up directly.
`no_console_suspend` is set via U-Boot `tdxargs`, so the console stays alive
through the suspend path; a hang leaves its last callback in the log.

## Checking on it

```bash
ssh torizon@192.168.77.212 'cd sleep_test && ./tools/pm_run.sh watch'
ssh torizon@192.168.77.213 'cat $(ls -t /var/lib/pmtest/log/soak-*.csv | head -1)'
ssh torizon@192.168.77.213 'grep -c FAIL $(ls -t /var/lib/pmtest/log/soak-*.csv | head -1)'
ssh torizon@192.168.77.212 'tail -50 ~/sleep_test/logs/serial-console.log'
ssh torizon@192.168.77.213 'uptime -s; uptime -p'   # much less than elapsed = it reset
```

The DUT is reachable ~60 s per quarter hour. The monitor is always reachable.

## Stopping it

```bash
ssh torizon@192.168.77.213 'sudo touch /var/lib/pmtest/STOP'
```

Clean exit at the next cycle boundary; survives reboots. To resume, delete the
file and `sudo systemctl start --no-block pmtest-soak`.

## Gotchas learned the hard way

**Use `--no-block` when starting the soak by hand.** The service suspends the
board within a second, which kills the ssh session that issued the command,
and a blocking `systemctl start` then appears to hang.

**Do not order the unit `After=multi-user.target`.** This board has no
internet, so `systemd-timesyncd` never syncs and `systemd-time-wait-sync`
stays `activating` forever, leaving `multi-user.target` permanently inactive.
Anything ordered after it waits in the job queue indefinitely — which silently
cost an hour of debugging. `WantedBy=multi-user.target` is fine; the *ordering*
was the problem.

**Time sync is still not working**, even with the GNSS attached — the stack
that feeds time from GPS (`mic-compose.service`) fails to start. The DUT's RTC
keeps correct time regardless, and `-A` alignment reads the system clock, so
this does not affect the soak. Worth fixing separately.

## The `-u` false-failure (2026-09-02 21:00-22:00)

The first attempt used `-u 1-1.1` to verify the GNSS. Every cycle slept the
full 15 minutes and both ethernet and USB came back `ok`, yet all five were
marked FAIL on the `dmesg` column, and `-F 5` correctly aborted the run.

The matched line was:

```
usb 1-1.1: PM: dpm_run_callback(): usb_dev_resume+0x0/0x20 returns -107
```

`-107` is ENOTCONN: `-u` unbinds the device *before* suspend, so on resume the
USB core runs a resume callback against a device that is no longer bound. The
failures were an artifact of the stress mode, not a defect.

Switched to `-C 1-1.1` (verify presence, never unbind), which is also what the
shipping config actually does. Two lessons:

- **`-F 5` worked.** It cost ~90 minutes instead of the 39 hours the previous
  run burned. The guard was right; the failure criterion under it was wrong.
- **Keeping the GNSS bound costs ~1.5 mA (~18 mW) asleep** — 20.5 mA with it
  bound vs 19.1 mA with `-u` unbinding it. The 222 mW floor measured earlier
  was with no GNSS attached at all.

## Open questions this run should answer

1. Does deep suspend hold over hundreds of cycles now that mwifiex is out?
2. Do 15-minute sleeps behave like the 60 s and 180 s ones?
3. Does anything drift? Watch `drift_s`.
4. Does the GNSS survive each sleep cycle? Now checked passively via
   `-C 1-1.1`; the `usb` column reads `ok`/`FAIL` rather than `skip`.
