# TODO tracker

One file per item, numbered. Statuses:

- **pending** — issue exists, not yet worked
- **in-progress** — being worked
- **needs-retest** — fix implemented, waiting on a hardware run to confirm
- **resolved** — confirmed fixed by a run; note the RUN_ID that proved it

Workflow: when a run produces results for an item, update the item's status
and Evidence section, then triage that run's log dir (see `logs/README.md`) —
`logs/pending/` while the item is open, `logs/resolved/` once confirmed.

| # | Item | Status |
|---|------|--------|
| [001](001-dut-passwordless-sudo.md) | Passwordless sudo on the DUT + re-aim campaign at 192.168.1.212 | pending |
| [002](002-lt8912-suspend-abort.md) | LT8912B HDMI bridge aborts deep suspend (ETIMEDOUT) | pending |
| [003](003-detached-suspend-orchestration.md) | ssh dies when the DUT suspends — detached phase orchestration | needs-retest |
| [004](004-suspend-script-diagnostics.md) | Script diagnostics: dmesg dump on abort, can0-as-ethernet, .swp push | needs-retest |
