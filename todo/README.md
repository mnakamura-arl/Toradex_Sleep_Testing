# TODO tracker

One file per item, numbered. Statuses:

- **pending** — issue exists, not yet worked
- **in-progress** — being worked
- **needs-retest** — fix implemented, waiting on a hardware run to confirm
- **resolved** — confirmed fixed by a run; note the RUN_ID that proved it

Workflow: when a run produces results for an item, update the item's status
and Evidence section, then triage that run's log dir (see `logs/README.md`) —
`logs/pending/` while the item is open, `logs/resolved/` once confirmed.

Roles: monitor/INA = **192.168.77.212**, DUT = **192.168.77.213**
(also 192.168.77.211 = M7 audio board).

Addresses changed 2026-09-03: the device network moved from 192.168.1.0/24 to
192.168.77.0/24 because the workstation's Wi-Fi joined a network using the
same 192.168.1.0/24 range, and route-metric ordering was papering over the
collision. Items 001-005 below quote the OLD addresses; that is deliberate -
they are dated findings and rewriting them would falsify the record.

| # | Item | Status |
|---|------|--------|
| [001](001-dut-passwordless-sudo.md) | DUT sudo + box roles (were recorded swapped) | resolved |
| [002](002-lt8912-suspend-abort.md) | LT8912B HDMI bridge aborts deep suspend (ETIMEDOUT) | resolved (was mwifiex/xhci — see 006) |
| [003](003-detached-suspend-orchestration.md) | ssh dies when the DUT suspends — detached phase orchestration | resolved (verified + hardened in 20260820-0725) |
| [004](004-suspend-script-diagnostics.md) | Script diagnostics: dmesg dump on abort, can0-as-ethernet, .swp push | resolved (verified in 20260820-0725) |
| [005](005-deploy-monitor-stack.md) | Deploy the compose stack to the monitor (192.168.1.212) | resolved (2026-08-20) |
| [006](006-deep-suspend-blockers.md) | Deep suspend blockers — root cause was the wrong carrier device tree (dev board DTB on Mallow hardware) | resolved (5/5 cycles, 262 mW floor, 2026-08-31) |
| [007](007-ina228-bus-voltage-sense.md) | INA228 bus voltage garbage — monitor/DUT grounds were isolated; all pre-08-31 power numbers invalid | resolved (2026-08-31) |
| [008](008-mwifiex-host-sleep-wedge.md) | mwifiex host-sleep wedges after a few cycles, then blocks every suspend | resolved (2026-09-03 — Wi-Fi does not ship; blacklisted permanently) |
