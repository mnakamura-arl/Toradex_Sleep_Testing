# Verdin iMX8M Plus / Mallow 1.1 power test suite

POSIX `sh` scripts, no dependencies beyond what's normally on a Toradex image.
Optional extras that improve the output: `ethtool`, `libgpiod` (`gpioinfo`),
`nvme-cli`, `usbutils`, `pciutils`.

Copy the whole directory to the board, then:

```sh
chmod +x *.sh
```

All scripts write to `/var/log/pmtest` and keep state in `/var/lib/pmtest`.
Override with `PM_LOGDIR` / `PM_STATEDIR`.

## Suggested order

| # | Script | What it does | Destructive? |
|---|--------|--------------|--------------|
| 1 | `01-probe.sh` | Inventory of RTCs, sleep states, wakeup sources, cpuidle, PCIe/USB/net | No |
| 2 | `02-suspend-cycle.sh` | One or more verified suspend/resume cycles | Suspends |
| 3 | `04-ab-matrix.sh` | Guided A/B measurement with your meter | Suspends |
| 4 | `05-runtime-tune.sh` | Apply/revert runtime knobs | Reversible |
| 5 | `03-poweroff-wake.sh` | Can the on-module RTC wake from full off? | **Powers off** |
| 6 | `06-soak.sh` | Overnight reliability soak | Suspends repeatedly |

## Quick start

```sh
# 1. See what you're working with
./01-probe.sh

# 2. Prove a single 60 s deep suspend works
./02-suspend-cycle.sh -d 60

# 3. Same, but with the peripherals torn down (your minutes-mode candidate)
./02-suspend-cycle.sh -d 120 -n 3 -e -U

# 4. Find out what each peripheral actually costs
./04-ab-matrix.sh both

# 5. Try the runtime knobs
./05-runtime-tune.sh save
./05-runtime-tune.sh apply
#   ... measure ...
./05-runtime-tune.sh revert

# 6. The big question for hours-mode
./03-poweroff-wake.sh install     # so the result is recorded on next boot
./03-poweroff-wake.sh arm 300

# 7. Once you've picked a config, soak it overnight
./06-soak.sh -n 300 -d 120 -a 15 -e -u 1-1
```

## Notes specific to this board

**RTC numbering.** `rtc0` is the on-module Epson RX8130CE (registered by the
`rtc-ds1307` driver), `rtc1` is the SoC's SNVS RTC. The scripts resolve by
driver name rather than trusting the numbers, but check `01-probe.sh` output
before assuming. Use SNVS for suspend-to-RAM; the RX8130 is the one that
might survive a full power-off.

**`echo 0 > wakealarm` before every arm.** If the previous alarm never fired
— you woke on GPIO, WoL, or a console keypress instead — re-arming returns
`EBUSY`. Every script clears first.

**Wi-Fi.** The Wi-Fi subsystem doesn't support suspend on this module. If you
have the WB variant, unload the module first (`-w` flag on
`02-suspend-cycle.sh`).

**CTRL_SLEEP_MOCI# (SODIMM 256).** This is the signal that tells Mallow to
gate its peripheral rails. It's a GPIO hog, so it won't show up as something
you can toggle from userspace — you have to scope it. If it doesn't go low
during suspend, none of your carrier-side rails are being shut off and your
suspend number will be much worse than it should be.

**Expected numbers.** Toradex measures roughly 150 mW for the module in
suspend-to-RAM, and has stated that NXP's ~15 mW figure from AN13054 is
SoC-only and not reachable on a real module. Treat ~150 mW as the floor and
anything above it as carrier/peripheral load you can chase.

**USB audio.** USB audio class devices often refuse to autosuspend and
sometimes keep VBUS load through system suspend. If `04-ab-matrix.sh` shows
the mic costing you real power while suspended, unbinding it before sleep
(`-u BUSID`) is the reliable fix.

**NVMe.** If your SSD is PCIe rather than USB, PCIe resume is the most likely
thing to break under soak. Enable ASPM and APST, and run `06-soak.sh` for at
least a few hundred cycles before trusting it.

## Device tree

Runtime knobs only go so far. `./05-runtime-tune.sh dt` prints the list of
nodes to disable at build time (GPU, VPU, NPU, ISP, MIPI, unused SAIs, etc.)
for a headless node. Verify afterwards with:

```sh
cat /sys/kernel/debug/pm_genpd/pm_genpd_summary
```
