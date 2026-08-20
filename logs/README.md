# Log triage

New runs land here as `logs/<RUN_ID>/` (created by `tools/pm_run.sh`).
After a run has been reviewed, move its directory into one of:

- `pending/`  — the run exposed an issue that is still open (link the
  `todo/NNN-*.md` item in a FINDINGS.md inside the run dir)
- `resolved/` — the run's issue is confirmed fixed, or the run produced the
  results it was after; FINDINGS.md says what it proved

Rules of thumb:

- Every triaged run dir gets a short `FINDINGS.md`: what ran, what happened,
  which todo item it relates to.
- A run moves from `pending/` to `resolved/` when a later run confirms the
  fix — note that later RUN_ID in the FINDINGS.md.
- Triage after `collect` — the collect subcommand tars `logs/<RUN_ID>` from
  the top level, so move the dir only once the results bundle exists (or
  re-point collect at the new path by hand).

## Current state (2026-08-19)

| Run | Where | Why |
|-----|-------|-----|
| 20260819, -0009, -0031, -0037, -0041 | resolved | rehearsals that exposed the psql `INSERT 0 1` phase-id bug; fixed by the `-q` flag, verified clean in 1950+ |
| 20260819-1950 | pending | DUT (.212) missing passwordless sudo → todo/001 |
| 20260819-2004 | pending | ssh died during suspend, phase misrecorded → todo/003 (fix implemented, needs retest) |
| 20260819-2036 | pending | LT8912B suspend aborts → todo/002; also drove todo/004 diagnostics. Phase 24 = proof deep suspend works (61 s, 1 s drift) |
