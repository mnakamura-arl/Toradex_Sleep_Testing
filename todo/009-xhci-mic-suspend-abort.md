# 009 — xhci-hcd.2.auto (USB mic) aborts suspend with -110, ~50% of cycles

**Status:** WORKAROUND FOUND 2026-09-03 — **move the mic to a USB Type-A
port**. On Type-A (behind the onboard hub, `xhci-hcd.1.auto`) 5/5 cycles pass
and the sleep floor is *lower*. On Type-C (`xhci-hcd.2.auto`) only 2/5 pass.
Underlying controller defect not isolated — see "What the port move proves".
Reproducible whenever the mic is on the Type-C port.
**Evidence:** run `20260903-mic` phase 51 — 5 cycles, alternating fail/pass.

This is the ETIMEDOUT failure originally chased in todo/002 and todo/006. It
was **not** fixed by the Mallow device-tree change; it was masked, because
every test after that change ran with the mic unplugged.

## Symptom

With the mic attached, roughly every other deep suspend aborts at the
`/sys/power/state` write with `Connection timed out`:

```
cycle,mode,requested_s,measured_s,drift_s,resume_ok,notes
1,deep,60,,,no,write-failed
2,deep,60,62,2,yes,no-entry-log
3,deep,60,,,no,write-failed
4,deep,60,62,2,yes,no-entry-log
5,deep,60,,,no,write-failed
```

The board never hangs or reboots — the write returns an errno and the system
stays up, so this is an abort, not a wedge.

## Root cause, from the serial console

```
xhci-hcd xhci-hcd.2.auto: WARN: xHC CMD_RUN timeout
xhci-hcd xhci-hcd.2.auto: PM: dpm_run_callback(): platform_pm_suspend+0x0/0x6c returns -110
xhci-hcd xhci-hcd.2.auto: PM: failed to suspend async: error -110
PM: suspend of devices aborted after 213.739 msecs
PM: Some devices failed to suspend, or early wake event detected
usb usb3-port1: cannot disable (err = -108)
```

`xhci-hcd.2.auto` hosts the USB audio device
(`JMTek USB PnP Audio Device`, card 0 `LMU_1`, at `usb-xhci-hcd.2.auto-1`).

**Why it alternates.** On resume from a *successful* cycle the controller
comes back degraded:

```
xhci-hcd xhci-hcd.1.auto: xHC error in resume, USBSTS 0x411, Reinit
xhci-hcd xhci-hcd.2.auto: xHC error in resume, USBSTS 0x411, Reinit
usb usb3: root hub lost power or was reset
usb 1-1.1: reset full-speed USB device number 8 using xhci-hcd
```

The next suspend then hits `CMD_RUN timeout` and aborts — and that abort
resets the controller, so the cycle after it succeeds. Hence fail/pass/fail.

## Why this one matters more than the others

The microphone is not incidental to this product — `lav-micro-u` is the
service the whole stack exists for. Unlike todo/008 (Wi-Fi, which does not
ship and could simply be blacklisted), **this device has to work**. A ~50%
suspend failure rate with the mic attached is a product defect, not a bench
artifact.

Power is unaffected when a cycle does succeed: the sleep floor with mic, GPS
and the full container stack is **~20.5–21.6 mA @ 11.77 V ≈ 248 mW**, close
to the 241 mW measured without the mic.

## What the port move proves (run `20260903-micA`)

Moving the mic from Type-C to a Type-A port:

| Config | Mic path | Reliability | Sleep floor |
|--------|----------|-------------|-------------|
| Type-C | `xhci-hcd.2.auto/usb3/3-1` (direct) | **2 of 5** | 21.04 mA / 247.6 mW |
| Type-A | `xhci-hcd.1.auto/usb1/1-1.2` (behind hub) | **5 of 5** | **19.94 mA / 234.7 mW** |

Both better reliability and ~13 mW less, the latter because with nothing on
the Type-C connector the `usb-conn-gpio` role switch drops `xhci-hcd.2.auto`
entirely - its root hubs `usb3`/`usb4` disappear and the controller is not
powered.

**Caveat: this is a workaround, not a diagnosis.** Three things changed at
once - the controller, direct-attach vs behind-a-hub, and `.2.auto` going
away completely. So "the mic works on Type-A" is established; "which of the
three mattered" is not. That distinction only matters if the product needs
the Type-C port for something else. If it does not, use Type-A and move on.

The device itself is exonerated: the same mic runs clean for 5/5 cycles on
the other controller.

### Side effect: the udev rule breaks

`/etc/udev/rules.d/85-usb-audio.rules` matched the mic by full DEVPATH:

```
DEVPATH=="/devices/platform/soc@0/32f10100.usb/38100000.usb/xhci-hcd.2.auto/usb3/3-1/3-1:1.0/sound/card?", ATTR{id}="LMU_1"
```

Moving the mic silently stops that matching, and the ALSA card falls back to
the generic id `Device` instead of `LMU_1`. Match on VID/PID instead so it is
port-independent:

```
ATTRS{idVendor}=="0c76", ATTRS{idProduct}=="153f", ATTR{id}="LMU_1"
```

(Separately, `lav-micro-u` logs `Multiple input devices found for ''` - it is
being handed an empty device name. That predates the move and is a container
config issue, not a consequence of it.)

## Untried avenues (only needed if Type-C must be usable)

1. **Disable USB wakeup on that controller** before suspend:
   `echo disabled > /sys/bus/usb/devices/usb3/power/wakeup` (and usb4).
   `usb usb3-port1: cannot disable (err = -108)` hints the port teardown is
   where it wedges.
2. **Unbind just the mic device** before suspend, rather than the whole
   controller — `06-soak.sh -u <busid>` does exactly this, though note it
   produces its own `-107` resume noise (see SOAK.md).
3. **Unbind the controller** `xhci-hcd.2.auto`. Tried on 2026-08-20 (phase
   33) and caused a reboot — but that was on the *wrong device tree*, so the
   result is void and worth repeating.
4. **USB autosuspend** — check `/sys/bus/usb/devices/*/power/control` for the
   audio device; forcing `auto` may let it idle down before system suspend.
5. **Kernel version.** Running 6.6.119. xHCI suspend/resume fixes land
   regularly; check Toradex for a newer BSP.
6. **Move the mic to the other controller** (`xhci-hcd.1.auto`) as a
   diagnostic — if it follows the mic, the device is at fault; if it stays
   with `.2.auto`, the controller/port is.

Avenue 6 is the cheapest and most informative, and needs only a cable swap.

## Done when

20+ consecutive deep cycles pass with the microphone attached and functional.
