# Findings

Rehearsal runs on 2026-08-19 (early AM). Exposed the phase-id capture bug:
psql -tA still printed the INSERT 0 1 command tag, so phase ids were
two lines and phase_close broke (see garbled labels in orchestrator.log).

Fixed by commit 96bf4d3 (-q flag in phase_open); verified clean in runs
20260819-1950 onward. No power results in these runs.
