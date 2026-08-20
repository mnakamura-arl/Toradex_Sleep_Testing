# Findings

Run 20260819-1950: probe phase failed on torizon@192.168.1.212 -
'sudo: a terminal is required to read the password'.

Resolved 2026-08-20: box roles were recorded swapped. .212 is the MONITOR
(INA228 stack, no sudo needed - docker works as torizon); the DUT is .213,
which has passwordless sudo. The campaign was briefly pointed at the wrong
box. See todo/001.
