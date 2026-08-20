# Findings

Run 20260819-2004 (target 192.168.1.213): suspend-60 entered deep sleep;
the ssh session died in TCP timeout and the phase was recorded FAILED
(exit 255) with dur 7.5 min for a 60 s suspend. Design gap, not a board
problem. Fix: pm_run.sh run-detached. Open item: todo/003 (needs-retest).
