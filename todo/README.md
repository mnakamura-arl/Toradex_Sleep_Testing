# TODO tracker

One file per item, numbered. Statuses:

- **pending** — issue exists, not yet worked
- **in-progress** — being worked
- **needs-retest** — fix implemented, waiting on a hardware run to confirm
- **resolved** — confirmed fixed by a run; note the RUN_ID that proved it

Workflow: when a run produces results for an item, update the item's status
and Evidence section, then triage that run's log dir (see `logs/README.md`) —
`logs/pending/` while the item is open, `logs/resolved/` once confirmed.

## Fleet (renumbered 2026-09-04)

Addresses are DHCP reservations on the Omada switch, keyed by MAC — the MAC is
the stable identifier, not the IP. Boards were renumbered on 2026-09-04 and the
monitor/DUT roles **swapped**, so anything written before that date quoting
.212 as the monitor and .213 as the DUT refers to the OLD layout.

| IP | MAC | Host | Role |
|----|-----|------|------|
| `.211` | `00:14:2d:87:38:f8` | 08861944 | **dev** — INA228 monitor + FTDI serial console |
| `.212` | `00:14:2d:87:39:46` | 08862022 | **dev** — eval/reference board |
| `.213` | `00:14:2d:87:38:f4` | 08861940 | deployment target |
| `.214` | `00:14:2d:87:39:2a` | 08861994 | deployment target |
| `.215` | `00:14:2d:87:39:26` | 08861990 | deployment target |
| `.216` | `00:14:2d:87:39:45` | — | deployment target |

Deployment targets are provisioned from the `.212` reference with
`tools/provision_node.sh --from torizon@192.168.77.212`.

Items 001-005 below quote the ORIGINAL 192.168.1.0/24 addresses, and items
006-009 the 192.168.77.x pre-swap ones. That is deliberate — they are dated
findings and rewriting them would falsify the record.

| # | Item | Status |
|---|------|--------|
| [001](001-dut-passwordless-sudo.md) | DUT sudo + box roles (were recorded swapped) | resolved |
| [002](002-lt8912-suspend-abort.md) | LT8912B HDMI bridge aborts deep suspend (ETIMEDOUT) | resolved (was mwifiex/xhci — see 006) |
| [003](003-detached-suspend-orchestration.md) | ssh dies when the DUT suspends — detached phase orchestration | resolved (verified + hardened in 20260820-0725) |
| [004](004-suspend-script-diagnostics.md) | Script diagnostics: dmesg dump on abort, can0-as-ethernet, .swp push | resolved (verified in 20260820-0725) |
| [005](005-deploy-monitor-stack.md) | Deploy the compose stack to the monitor (192.168.1.212) | resolved (2026-08-20) |
| [006](006-deep-suspend-blockers.md) | Deep suspend blockers — root cause was the wrong carrier device tree (dev board DTB on Mallow hardware) | resolved — **80/80 cycles over 20 h** (2026-09-04) |
| [007](007-ina228-bus-voltage-sense.md) | INA228 bus voltage garbage — monitor/DUT grounds were isolated; all pre-08-31 power numbers invalid | resolved (2026-08-31) |
| [008](008-mwifiex-host-sleep-wedge.md) | mwifiex host-sleep wedges after a few cycles, then blocks every suspend | resolved (2026-09-03 — Wi-Fi does not ship; blacklisted permanently) |
| [009](009-xhci-mic-suspend-abort.md) | xhci-hcd.2.auto (USB mic) aborts suspend with -110 on ~50% of cycles | workaround: mic on USB-A → 5/5 and lower power; controller defect not isolated |
| [010](010-m7-triggered-wake.md) | Wake the board from the Cortex-M7 instead of the RTC | firmware runs from TCM and picks random intervals, but stops in `deep` — see the M7 repo's todo/011 |
