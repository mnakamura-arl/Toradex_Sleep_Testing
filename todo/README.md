# TODO tracker

One file per item, numbered. Statuses:

- **pending** — issue exists, not yet worked
- **in-progress** — being worked
- **needs-retest** — fix implemented, waiting on a hardware run to confirm
- **resolved** — confirmed fixed by a run; note the RUN_ID that proved it

Workflow: when a run produces results for an item, update the item's status
and Evidence section, then triage that run's log dir (see `logs/README.md`) —
`logs/pending/` while the item is open, `logs/resolved/` once confirmed.

Roles (confirmed 2026-08-20): monitor/INA = 192.168.1.212, DUT = 192.168.1.213.

| # | Item | Status |
|---|------|--------|
| [001](001-dut-passwordless-sudo.md) | DUT sudo + box roles (were recorded swapped) | resolved |
| [002](002-lt8912-suspend-abort.md) | LT8912B HDMI bridge aborts deep suspend (ETIMEDOUT) | resolved (was mwifiex/xhci — see 006) |
| [003](003-detached-suspend-orchestration.md) | ssh dies when the DUT suspends — detached phase orchestration | resolved (verified + hardened in 20260820-0725) |
| [004](004-suspend-script-diagnostics.md) | Script diagnostics: dmesg dump on abort, can0-as-ethernet, .swp push | resolved (verified in 20260820-0725) |
| [005](005-deploy-monitor-stack.md) | Deploy the compose stack to the monitor (192.168.1.212) | resolved (2026-08-20) |
| [006](006-deep-suspend-blockers.md) | Deep suspend blockers: mwifiex, xhci; hard reboot with -w -U | pending |
