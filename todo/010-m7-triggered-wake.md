# 010 — Wake the board from the Cortex-M7 instead of the RTC

**Status:** open — firmware works, the wake does not (yet).
**Started:** 2026-09-05.

## Why

Every suspend cycle so far has been woken by the SNVS RTC alarm. That is fine
for measuring the sleep floor, but it cannot answer the question the product
actually asks: *can something the M7 notices bring the A53 back?* Until the
wake comes from the M7, "the M7 heard a sound and woke the system" is
untested.

An RTC-driven soak also can only ever produce fixed intervals. Wakes driven by
the M7 are irregular by construction, which exercises the suspend path more
honestly.

## What exists now

On the M7 side (`Toradex_Microcontroler_Audio`):

- `firmware/evkmimx8mp/demo_apps/m7_random_wake/` — picks a pseudo-random
  interval (15–45 s), counts it down in WFI, rings the MU GIR0 doorbell,
  repeats. Runs entirely from TCM.
- Loaded by **U-Boot `bootaux`**, not remoteproc — the A53 cannot write TCM at
  all. That repo's todo/009 has the whole story; `deploy-firmware.sh --tcm`
  automates it.
- Progress is published in `SRC_GPR8` (`0x30390090`), readable from Linux, so
  the M7's state is observable without a console:

  ```
  rr_ii_ssss   rr = doorbells rung, ii = interval chosen, ssss = seconds left
  ```

On this side:

- `scripts/02-suspend-cycle.sh -X` — external-wake mode. The RTC is armed only
  as a failsafe and the pass criterion inverts: waking early is success,
  sleeping the full duration means no external wake arrived. See `SOAK.md`.

## Where it stands

The firmware demonstrably works while Linux is awake — countdown advances,
ring count increments, a fresh random interval is drawn each time.

In `deep` suspend it stops. Measured across one 110 s cycle: 47 s of M7
countdown elapsed across ~150 s of wall clock, ring count unchanged, and the
board woke on the RTC failsafe. The M7 loses its clocks when the SoC enters
DSM.

So **the doorbell has never actually been rung at a suspended A53**, and
whether MU can wake this board is still an open question, separate from
keeping the M7 alive.

Full account, including a `ServiceBusy` flag that hard-locks the kernel and
how to recover the board over serial when it does: the M7 repo's **todo/011**.

## Done when

`02-suspend-cycle.sh -X -m deep` reports `ext-wake@<n>s` with the M7's ring
count advanced across the cycle.
